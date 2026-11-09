import AppKit
import Foundation
import NativeAgentShared
import Observation
// Blueprint: | `PipeFaceClient.swift` | Renderer act correlation, frame application and body-call dispatch over the inherited pipes |

@MainActor
@Observable
final class PipeFaceClient: FaceClient {
    enum State: Equatable { case connecting, connected, failed(String), closed }

    let face = FaceFeed()
    private(set) var state = State.connecting
    @ObservationIgnored private let displayFrame = DisplayFrame()
    @ObservationIgnored private var link: FaceLink.Connection?
    @ObservationIgnored private weak var router: FaceCallRouter?
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<FaceActReply, Error>] = [:]
    @ObservationIgnored private var abandoned: Set<UUID> = []
    @ObservationIgnored private var receipts: [UUID: FaceAct] = [:]
    @ObservationIgnored var onReceiptFailure: ((WireFailure) -> Void)?
    @ObservationIgnored private var calls: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var epoch: UUID?
    @ObservationIgnored private var appliedBarriers: Set<UUID> = []
    @ObservationIgnored private var batches: [FaceBatch] = []
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var log: FaceLinkLog?
    @ObservationIgnored private var requestNames: [UUID: String] = [:]

    private func send(_ act: FaceAct, id: UUID, link: FaceLink.Connection) async throws {
        let name = FaceLinkLog.act(act)
        requestNames[id] = name
        try await link.send(.act(id: id, act))
        await record("sent request=\(id) act=\(name)")
    }

    private func record(_ event: String) async {
        do { try await log?.record(event) }
        catch {
            ModuleLog.app("[face] link record failed: %@", error.localizedDescription, level: .error)
            onReceiptFailure?(WireFailure(code: "face_log_write_failed", message: "This window could not append its link record.",
                cause: TurnSecretRedactor.redactText(error.localizedDescription), effects: .none))
        }
    }

    var connectionID: UUID? { epoch }

    func openLinkRecord() async throws {
        guard log == nil, !ended else { throw FaceWireError.invalidFeedOrder }
        guard let path = ProcessInfo.processInfo.environment["NATIVEAGENT_FACE_DATA_ROOT"], !path.isEmpty else {
            throw WireFailure(code: "face_data_root_missing", message: "I did not supply this window's diagnostics root.",
                              cause: nil, effects: .none)
        }
        log = try await FaceLinkLog.open(dataRoot: URL(fileURLWithPath: path, isDirectory: true), role: .face)
    }

    func connectionFailed(_ error: any Error) async { await end(error) }

    /// A cancelled caller retains its request identity; the body may already have performed the act.
    func act(_ act: FaceAct) async throws -> FaceActReply {
        try await self.act(act, id: UUID(), retainingReply: false)
    }

    /// Page cancellation asks the body to stop and keeps its waiter for the body's actual terminal reply.
    func pageAct(_ request: PageActRequest, id: UUID) async throws -> FaceActReply {
        try await act(.pageAct(request), id: id, retainingReply: true)
    }

    func protectedAct(_ act: FaceAct) async throws -> FaceActReply {
        try await self.act(act, id: UUID(), retainingReply: true)
    }

    private func act(_ act: FaceAct, id: UUID, retainingReply: Bool) async throws -> FaceActReply {
        try Task.checkCancellation()
        guard !ended, let link else { throw FaceWireError.disconnected }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                Task {
                    guard !ended, waiting[id] != nil else { abandoned.remove(id); return }
                    do { try await send(act, id: id, link: link) }
                    catch { await end(error) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.waiting[id] != nil else { return }
                if !retainingReply, let continuation = self.waiting.removeValue(forKey: id) {
                    self.abandoned.insert(id)
                    continuation.resume(throwing: WireFailure(code: "face_act_cancelled", message: "Stopped waiting for my reply.",
                        cause: "Request \(id.uuidString); its effects are unknown. Reconcile before repeating it.", effects: .unknown))
                }
                guard !self.ended, let link = self.link else { return }
                let cancellation = UUID()
                self.receipts[cancellation] = .cancelRequest(id)
                do { try await self.send(.cancelRequest(id), id: cancellation, link: link) }
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
            let attach = UUID()
            receipts[attach] = .attach(protocolVersion: FaceEnvelope.protocolVersion)
            try await send(.attach(protocolVersion: FaceEnvelope.protocolVersion), id: attach, link: link)
            while let envelope = try await incoming.next() {
                if await link.reachedEOF { continue }
                switch envelope {
                case .feed(let batch):
                    await record(FaceLinkLog.feed(batch))
                    batches.append(batch)
                    if frameTask == nil { frameTask = Task { await draw(link: link) } }
                case .actReply(let id, let reply):
                    let name = requestNames.removeValue(forKey: id) ?? "unknown"
                    await record("reply request=\(id) act=\(name) result=\(FaceLinkLog.reply(reply))")
                    if let continuation = waiting.removeValue(forKey: id) { continuation.resume(returning: reply) }
                    else if abandoned.remove(id) != nil { continue }
                    else if let receipt = receipts.removeValue(forKey: id) {
                        switch reply {
                        case .acknowledged: if case .attach = receipt { state = .connected }
                        case .failed(let failure), .refused(let failure):
                            if case .attach = receipt { state = .failed(failure.localizedDescription) }
                            else { onReceiptFailure?(failure) }
                        default: throw FaceWireError.invalidFeedOrder
                        }
                    } else { throw FaceWireError.invalidFeedOrder }
                case .call(let id, .cancelCall(let target)):
                    await record("call request=\(id) name=cancelCall target=\(target)")
                    calls[target]?.cancel()
                    try await link.send(.reply(id: id, .acknowledged))
                    await record("replied request=\(id) result=acknowledged")
                case .call(let id, let call):
                    await record("call request=\(id) name=\(FaceLinkLog.name(call))")
                    guard calls[id] == nil else { throw FaceWireError.invalidFeedOrder }
                    calls[id] = Task {
                        guard !ended, !(await link.reachedEOF) else { calls.removeValue(forKey: id); return }
                        let reply = await router.reply(to: call)
                        guard !ended, !(await link.reachedEOF) else { calls.removeValue(forKey: id); return }
                        do {
                            try await link.send(.reply(id: id, reply))
                            await record("replied request=\(id) result=\(FaceLinkLog.reply(reply))")
                            if case .closeRenderer = call {
                                await end(FaceWireError.disconnected, bodyGone: true)
                            }
                        } catch { await end(error) }
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
                for batch in frame {
                    guard !ended, let epoch = batch.epoch else { return }
                    let id = UUID()
                    receipts[id] = .frameApplied(epoch: epoch, sequence: batch.sequence, barriers: batch.barriers)
                    try await send(.frameApplied(epoch: epoch, sequence: batch.sequence, barriers: batch.barriers), id: id, link: link)
                }
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
                try await log.record(event)
                try await log.close()
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
            continuation.resume(throwing: WireFailure(code: "face_reply_lost", message: "My connection closed.",
                cause: "Request \(id.uuidString): \(error.localizedDescription). Its effects are unknown.", effects: .unknown))
        }
        for task in calls.values { task.cancel() }
        calls.removeAll()
        router?.disconnect()
        router = nil
        if let link { await link.close() }
        link = nil
        state = bodyGone ? .closed : .failed(detail)
        if bodyGone { NSApplication.shared.terminate(nil) }
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
