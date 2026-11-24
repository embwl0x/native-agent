import AppKit
import Foundation
import NativeAgentShared
import Observation
import Synchronization
// Blueprint: | `PipeFaceClient.swift` | Renderer act correlation, frame application and body-call dispatch over the inherited pipes |

@MainActor
@Observable
final class PipeFaceClient: FaceClient {
    enum State: Equatable { case connecting, connected, failed(String), closed }

    let face = FaceFeed()
    private(set) var state = State.connecting
    /// Work that needs the link runs once the body acknowledges attach, never racing it.
    private var afterConnect: [() -> Void] = []
    func whenConnected(_ work: @escaping () -> Void) {
        if case .connected = state { work() } else { afterConnect.append(work) }
    }
    @ObservationIgnored private let displayFrame = DisplayFrame()
    @ObservationIgnored private var link: FaceLink.Connection?
    @ObservationIgnored private weak var router: FaceCallRouter?
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var waiting: [UInt64: CheckedContinuation<FaceActReply, Error>] = [:]
    @ObservationIgnored private var abandoned: Set<UInt64> = []
    @ObservationIgnored private var receipts: [UInt64: FaceAct] = [:]
    @ObservationIgnored var onReceiptFailure: ((WireFailure) -> Void)?
    @ObservationIgnored private var calls: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var epoch: UUID?
    @ObservationIgnored private var appliedBarriers: Set<UUID> = []
    @ObservationIgnored private var batches: [FaceBatch] = []
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var log: FaceLinkLog?
    @ObservationIgnored private var requestNames: [UInt64: String] = [:]

    @ObservationIgnored private var requests = FaceLink.Requests()
    @ObservationIgnored private var lastCall: UInt64 = 0

    private final class PendingAct: Sendable {
        @MainActor var id: UInt64?
        private let pending = Atomic(true)

        nonisolated func claim() -> Bool {
            pending.exchange(false, ordering: .relaxed)
        }
    }

    private func enqueue(_ act: FaceAct, link: FaceLink.Connection, beginWrite: (@Sendable () -> Bool)? = nil) throws -> (id: UInt64, write: Task<Void, Error>) {
        let request = try requests.enqueue(on: link, beginWrite: beginWrite) { .act(id: $0, act) }
        let name = FaceLinkLog.act(act)
        requestNames[request.id] = name
        log?.record("queued request=\(request.id) act=\(name)")
        return request
    }

    private func receipt(_ act: FaceAct, link: FaceLink.Connection) async throws {
        let request = try enqueue(act, link: link)
        receipts[request.id] = act
        try await request.write.value
    }

    var connectionID: UUID? { epoch }

    func openLinkRecord() async throws {
        guard log == nil, !ended else { throw FaceWireError.invalidFeedOrder }
        guard let path = ProcessInfo.processInfo.environment["NATIVEAGENT_FACE_DATA_ROOT"], !path.isEmpty else {
            throw WireFailure(code: "face_data_root_missing", message: "I did not supply this window's diagnostics root.",
                              cause: nil, effects: .none)
        }
        log = try await FaceLinkLog.open(dataRoot: URL(fileURLWithPath: path, isDirectory: true), role: .face) { [weak self] error in
            await self?.recordFailed(error)
        }
    }

    private func recordFailed(_ error: any Error) {
        onReceiptFailure?(WireFailure(code: "face_log_write_failed", message: "This window could not append its link record.",
            cause: TurnSecretRedactor.redactText(error.localizedDescription), effects: .none))
    }

    func connectionFailed(_ error: any Error) async { await end(error) }

    /// A cancelled caller retains its request identity; the body may already have performed the act.
    func act(_ act: FaceAct) async throws -> FaceActReply {
        try await self.act(act, retainingReply: false)
    }

    func protectedAct(_ act: FaceAct) async throws -> FaceActReply {
        try await self.act(act, retainingReply: true)
    }

    private func act(_ act: FaceAct, retainingReply: Bool) async throws -> FaceActReply {
        let pending = PendingAct()
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                let id: UInt64, write: Task<Void, Error>
                do {
                    try Task.checkCancellation()
                    guard !ended, let link else { throw FaceWireError.disconnected }
                    (id, write) = try enqueue(act, link: link, beginWrite: pending.claim)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                pending.id = id
                waiting[id] = continuation
                Task {
                    do { try await write.value }
                    catch { await end(error) }
                }
            }
        } onCancel: {
            let withdrawn = pending.claim()
            Task { @MainActor in
                guard let id = pending.id, self.waiting[id] != nil else { return }
                if withdrawn {
                    self.requestNames.removeValue(forKey: id)
                    self.log?.record("withdrawn request=\(id)")
                    self.waiting.removeValue(forKey: id)?.resume(throwing: WireFailure(code: "face_act_cancelled",
                        message: "Cancelled before sending the request.", cause: "Request \(id).", effects: .none))
                    return
                }
                if !retainingReply, let continuation = self.waiting.removeValue(forKey: id) {
                    self.abandoned.insert(id)
                    continuation.resume(throwing: WireFailure(code: "face_act_cancelled", message: "Stopped waiting for my reply.",
                        cause: "Request \(id); its effects are unknown. Reconcile before repeating it.", effects: .unknown))
                }
                guard !self.ended, let link = self.link else { return }
                do { try await self.receipt(.cancelRequest(id), link: link) }
                catch { await self.end(error) }
            }
        }
    }

    func requireApplied(_ request: PageRenderRequest) throws {
        guard request.epoch == epoch, appliedBarriers.contains(request.barrier) else { throw FaceWireError.invalidFeedOrder }
    }

    /// The incoming reader never waits for an act reply or a body call; either may need this reader to make progress.
    func run(link: FaceLink.Connection, router: FaceCallRouter) async {
        guard self.link == nil, state == .connecting else { return }
        self.link = link
        self.router = router
        var incoming = link.incoming.makeAsyncIterator()
        do {
            try await receipt(.attach(protocolVersion: FaceEnvelope.protocolVersion), link: link)
            while let envelope = try await incoming.next() {
                if await link.reachedEOF { continue }
                switch envelope {
                case .feed(let batch):
                    log?.record(FaceLinkLog.feed(batch))
                    batches.append(batch)
                    if frameTask == nil { frameTask = Task { await draw(link: link) } }
                case .actReply(let id, let reply):
                    let name = requestNames.removeValue(forKey: id) ?? "unknown"
                    log?.record("reply request=\(id) act=\(name) result=\(FaceLinkLog.reply(reply))")
                    if let continuation = waiting.removeValue(forKey: id) { continuation.resume(returning: reply) }
                    else if abandoned.remove(id) != nil { continue }
                    else if let receipt = receipts.removeValue(forKey: id) {
                        switch reply {
                        case .acknowledged:
                            if case .attach = receipt {
                                state = .connected
                                let work = afterConnect
                                afterConnect = []
                                work.forEach { $0() }
                            }
                        case .failed(let failure), .refused(let failure):
                            if case .attach = receipt { state = .failed(failure.localizedDescription) }
                            else { onReceiptFailure?(failure) }
                        default: throw FaceWireError.invalidFeedOrder
                        }
                    } else { throw FaceWireError.invalidFeedOrder }
                case .call(let id, .cancelCall(let target)):
                    log?.record("call request=\(id) name=cancelCall target=\(target)")
                    guard id > lastCall else { throw FaceWireError.invalidFeedOrder }
                    lastCall = id
                    calls[target]?.cancel()
                    try await link.send(.reply(id: id, .acknowledged))
                    log?.record("replied request=\(id) result=acknowledged")
                case .call(let id, let call):
                    log?.record("call request=\(id) name=\(FaceLinkLog.name(call))")
                    guard id > lastCall else { throw FaceWireError.invalidFeedOrder }
                    lastCall = id
                    calls[id] = Task {
                        guard !ended, !(await link.reachedEOF) else { calls.removeValue(forKey: id); return }
                        let reply = await router.reply(to: call)
                        guard !ended, !(await link.reachedEOF) else { calls.removeValue(forKey: id); return }
                        do {
                            try await link.send(.reply(id: id, reply))
                            log?.record("replied request=\(id) result=\(FaceLinkLog.reply(reply))")
                            if case .closeRenderer = call {
                                await end(FaceWireError.disconnected, bodyGone: true)
                            }
                        } catch {
                            // A call the body cancelled owes no reply; its cancellation is that call's end, never the connection's.
                            if !Task.isCancelled { await end(error) }
                        }
                        calls.removeValue(forKey: id)
                    }
                case .act, .reply: throw FaceWireError.invalidFeedOrder
                }
            }
            await end(FaceWireError.disconnected, bodyGone: true)
        } catch {
            let eof = await link.reachedEOF
            let bodyGone = eof || Self.bodyIsGone(error)
            if bodyGone {
                do { while let _ = try await incoming.next() {} }
                catch { await end(error, bodyGone: true); return }
            }
            await end(error, bodyGone: bodyGone)
        }
    }

    private func draw(link: FaceLink.Connection) async {
        defer { frameTask = nil }
        do {
            while !batches.isEmpty {
                await displayFrame.next()
                guard !ended, !(await link.reachedEOF) else { return }
                try Task.checkCancellation()
                let frame = batches
                batches.removeAll()
                for batch in frame {
                    try face.applyRemote(batch)
                    guard let epoch = batch.epoch else { throw FaceWireError.invalidFeedOrder }
                    if batch.replacesAll { self.epoch = epoch; appliedBarriers.removeAll() }
                    appliedBarriers.formUnion(batch.barriers)
                }
                guard let last = frame.last, let epoch = last.epoch else { throw FaceWireError.invalidFeedOrder }
                try await receipt(.frameApplied(epoch: epoch, sequence: last.sequence,
                                                barriers: frame.flatMap(\.barriers)), link: link)
            }
        } catch { await end(error) }
    }

    private func end(_ error: any Error, bodyGone: Bool = false) async {
        guard !ended else { return }
        ended = true
        let eof: Bool
        if let link { eof = await link.reachedEOF } else { eof = false }
        let bodyGone = bodyGone || eof || Self.bodyIsGone(error)
        var detail = error.localizedDescription
        if let log {
            do {
                let event = eof ? "EOF" : (bodyGone ? "closed " : "error ") + TurnSecretRedactor.redactText(detail)
                try await log.close(finalLine: event)
            } catch { detail += "\nLink record: " + error.localizedDescription }
        }
        log = nil
        requestNames.removeAll()
        frameTask?.cancel()
        batches.removeAll()
        face.disconnect()
        epoch = nil
        appliedBarriers.removeAll()
        let pending = waiting
        waiting.removeAll()
        abandoned.removeAll()
        receipts.removeAll()
        for (id, continuation) in pending {
            continuation.resume(throwing: WireFailure(code: "face_reply_lost", message: "Lost connection while doing that. It may or may not have gone through.",
                cause: "Request \(id): \(error.localizedDescription). Its effects are unknown.", effects: .unknown))
        }
        for task in calls.values { task.cancel() }
        calls.removeAll()
        router?.disconnect()
        router = nil
        if let link { await link.close() }
        link = nil
        state = bodyGone ? .closed : .failed(detail)
        if bodyGone { FaceAppDelegate.endWithBody() }
    }

    private static func bodyIsGone(_ error: any Error) -> Bool {
        if case FaceWireError.io(let code) = error, code == POSIXErrorCode.EPIPE.rawValue { return true }
        var cause: NSError? = error as NSError
        while let current = cause {
            if current.domain == NSPOSIXErrorDomain, current.code == Int(POSIXErrorCode.EPIPE.rawValue) { return true }
            cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    @concurrent nonisolated static func openInheritedPipes() async throws -> FaceLink.Connection {
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        let link = try await FaceLink.Connection.open(input: input, output: output)
        do { try input.close(); try output.close(); return link }
        catch { await link.close(); throw error }
    }
}
