import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import os
// Blueprint: | `BodyFaceConnection.swift` | Body pipe endpoint: attach, feed receipts, act dispatch and correlated window calls |

actor BodyFaceConnection {
    private let link: FaceLink.Connection
    private let source: FaceFeedSource
    private let handler: any FaceActHandler
    private let log: FaceLinkLog
    private let disconnected: @Sendable (UUID?, String, Bool) async -> Void
    private let connected: @Sendable (UUID) async throws -> Void
    /// Runs synchronously as the first act of close, before any drain: what must stop reading this connection forgets it here.
    private let ending: @Sendable (UUID?) -> Void
    private var sink: FaceFeedSink?
    private var attached = false
    private var attachmentFailure: (any Error)?
    private var feedTask: Task<Void, Never>?
    private var acts: [UInt64: Task<Void, Never>] = [:]
    private var observations: Set<UUID> = []
    private var lastAct: UInt64 = 0
    private var requests = FaceLink.Requests()
    private var waiting: [UInt64: CheckedContinuation<FaceReply, Error>] = [:]
    private var abandoned: Set<UInt64> = []
    private var attachment: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var failure: (any Error)?
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(link: FaceLink.Connection, source: FaceFeedSource, handler: any FaceActHandler, log: FaceLinkLog,
         connected: @escaping @Sendable (UUID) async throws -> Void,
         ending: @escaping @Sendable (UUID?) -> Void,
         disconnected: @escaping @Sendable (UUID?, String, Bool) async -> Void) {
        self.link = link; self.source = source; self.handler = handler
        self.log = log
        self.connected = connected; self.ending = ending; self.disconnected = disconnected
    }

    func run() async {
        do {
            for try await envelope in link.incoming {
                try Task.checkCancellation()
                if await link.reachedEOF { continue }
                guard failure == nil else { break }
                switch envelope {
                case .act(let id, let act):
                    guard id > lastAct else { throw FaceWireError.invalidFeedOrder }
                    lastAct = id
                    await receive(act, id: id)
                case .reply(let id, let reply):
                    if let continuation = waiting.removeValue(forKey: id) { continuation.resume(returning: reply) }
                    else if abandoned.remove(id) == nil { throw FaceWireError.invalidFeedOrder }
                case .feed, .call, .actReply: throw FaceWireError.invalidFeedOrder
                }
            }
            await close(FaceWireError.disconnected)
        } catch { await close(error) }
    }

    private func receive(_ act: FaceAct, id: UInt64) async {
        do {
            switch act {
            case .attach(let version):
                guard sink == nil, version == FaceEnvelope.protocolVersion else {
                    throw WireFailure(code: "face_attachment_rejected", message: "This window could not attach to me.",
                        cause: "Version \(version), expected \(FaceEnvelope.protocolVersion); sink=\(String(describing: sink?.epoch))", effects: .none)
                }
                let sink = await source.attachSink()
                if let failure { await source.detachSink(sink.epoch, cause: failure); throw failure }
                self.sink = sink
                try await connected(sink.epoch)
                let result = try await handler.handle(act)
                if let failure { throw failure }
                switch result {
                case .acknowledged: break
                case .failed(let failure), .refused(let failure): throw failure
                default:
                    throw WireFailure(code: "face_attachment_rejected", message: "I did not acknowledge this window's attachment.",
                                      cause: FaceLinkLog.reply(result), effects: .unknown)
                }
                attached = true
                await reply(.acknowledged, to: id, act: act)
                guard failure == nil else { return }
                feedTask = Task { await forward(sink) }
                let ready = attachment
                attachment.removeAll()
                for continuation in ready.values { continuation.resume() }
            case .frameApplied(let epoch, let sequence, let barriers):
                try requireAttachment()
                guard epoch == sink?.epoch else {
                    throw WireFailure(code: "frame_receipt_epoch", message: "The applied frame names another connection.",
                        cause: "Received \(epoch); attached \(String(describing: sink?.epoch))", effects: .none)
                }
                try await source.applied(epoch: epoch, sequence: sequence, barriers: barriers)
                await reply(.acknowledged, to: id, act: act)
            case .cancelRequest(let request):
                try requireAttachment()
                acts[request]?.cancel()
                await reply(.acknowledged, to: id, act: act)
            default:
                try requireAttachment()
                if case .reportProtectedWindows(let report) = act, report.connection != sink?.epoch {
                    throw FaceWireError.invalidFeedOrder
                }
                if case .reportInspector(let report) = act, report.connection != sink?.epoch {
                    throw FaceWireError.invalidFeedOrder
                }
                if case .observe(let observation, _) = act { observations.insert(observation) }
                acts[id] = Task { await dispatch(act, id: id) }
            }
        } catch {
            if case .attach = act, !attached {
                attachmentFailure = error
                let waiting = attachment
                attachment.removeAll()
                for continuation in waiting.values { continuation.resume(throwing: error) }
            }
            await reply(.failed(Self.actFailure(error)), to: id, act: act)
        }
    }

    private func requireAttachment() throws {
        if let failure { throw failure }
        if let attachmentFailure { throw attachmentFailure }
        guard attached else {
            throw WireFailure(code: "face_not_attached", message: "The window must attach before sending this act.", cause: nil, effects: .none)
        }
    }

    func waitForAttachment() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let failure { throw failure }
            if let attachmentFailure { throw attachmentFailure }
            if attached { return }
            try await withCheckedThrowingContinuation { attachment[id] = $0 }
        } onCancel: { Task { await self.cancelAttachment(id) } }
    }

    func call(_ call: FaceCall, connection: UUID? = nil) async throws -> FaceReply {
        try await waitForAttachment()
        if let connection, sink?.epoch != connection { throw FaceWireError.disconnected }
        try Task.checkCancellation()
        if let failure { throw failure }
        let (id, write) = try requests.enqueue(on: link) { .call(id: $0, call) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                Task {
                    do { try await write.value }
                    catch { await close(error) }
                }
            }
        } onCancel: { Task { await self.cancelCall(id) } }
    }

    private func forward(_ sink: FaceFeedSink) async {
        do {
            for try await batch in sink.batches { try await link.send(.feed(batch)) }
            await close(FaceWireError.disconnected)
        } catch { await close(error) }
    }

    private func dispatch(_ act: FaceAct, id: UInt64) async {
        let reply: FaceActReply
        do {
            let result = try await handler.handle(act)
            if case .unobserve(let observation) = act, case .acknowledged = result { observations.remove(observation) }
            reply = result
        }
        catch { reply = .failed(Self.actFailure(error)) }
        await settle { await self.reply(reply, to: id, act: act) }
    }

    private static func actFailure(_ error: any Error) -> WireFailure {
        if let cause = error as? WireFailure { return cause }
        return WireFailure(code: error is CancellationError ? "face_act_cancelled" : "face_act_failed",
            message: error is CancellationError ? "The act was cancelled; its effects require reconciliation." : "I could not complete the act.",
            cause: NativeAppSecretRedactor.redactText(FaceLinkLog.failure(error)), effects: .unknown)
    }

    private func reply(_ reply: FaceActReply, to id: UInt64, act: FaceAct) async {
        switch reply {
        case .failed, .refused:
            record("reply request=\(id) act=\(FaceLinkLog.act(act)) result=\(FaceLinkLog.reply(reply))")
        case .committed(let result):
            if result.publicationFailure != nil {
                record("reply request=\(id) act=\(FaceLinkLog.act(act)) result=\(FaceLinkLog.reply(reply))")
            }
        case .card(let result) where result.failure != nil:
            record("reply request=\(id) act=\(FaceLinkLog.act(act)) result=\(FaceLinkLog.reply(reply))")
        default: break
        }
        acts.removeValue(forKey: id)
        guard failure == nil else { return }
        do { try await link.send(.actReply(id: id, reply)) }
        catch { await close(error) }
    }

    private func record(_ event: String) {
        log.record(NativeAppSecretRedactor.redactText(event))
    }

    private func cancelAttachment(_ id: UUID) {
        attachment.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelCall(_ id: UInt64) async {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        abandoned.insert(id)
        continuation.resume(throwing: CancellationError())
        do {
            let (cancellation, write) = try requests.enqueue(on: link) { .call(id: $0, .cancelCall(id)) }
            abandoned.insert(cancellation)
            try await write.value
        }
        catch { await close(error) }
    }

    func close(_ cause: any Error = FaceWireError.disconnected) async {
        guard failure == nil else { return }
        failure = cause
        let connection = sink?.epoch
        ending(connection)
        record("disconnect epoch=\(String(describing: connection)) cause=\(FaceLinkLog.failure(cause))")
        feedTask?.cancel()
        feedTask = nil
        if let sink { await source.detachSink(sink.epoch, cause: cause) }
        sink = nil
        for task in acts.values { task.cancel() }
        let dispatches = Array(acts.values)
        acts.removeAll()
        let pending = waiting, attaching = attachment
        waiting.removeAll(); attachment.removeAll(); abandoned.removeAll()
        for continuation in pending.values { continuation.resume(throwing: cause) }
        for continuation in attaching.values { continuation.resume(throwing: cause) }
        await link.close()
        for task in dispatches { await task.value }
        let registered = observations
        observations.removeAll()
        var releases: [String] = []
        for observation in registered {
            do { _ = try await handler.handle(.unobserve(id: observation)) }
            catch { releases.append("Observation release: \(error.localizedDescription)") }
        }
        await disconnected(connection, ([cause.localizedDescription] + releases).joined(separator: "\n"), attached)
        if !releases.isEmpty { record("release_failed " + releases.joined(separator: "\n")) }
        do { try await log.close() }
        catch { ModuleLog.app("[face] link record close failed: %@", error.localizedDescription, level: .error) }
        closed = true
        let settled = closeWaiters
        closeWaiters.removeAll()
        for waiter in settled { waiter.resume() }
    }

    /// A reader can end before a feed-owned close finishes releasing the connection.
    func joinClose() async {
        guard !closed else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
}
