import Foundation
import NativeAgentCore
import Synchronization
// Blueprint: | `ProviderReplyWork.swift` | stop joins transport exit and drain |

/// One reply owns its cancellable caller wait and its independent producer settlement.
final class ProviderReplyWork: Sendable {

    private struct Producer: Sendable {
        let stop: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private struct State {
        var stopped = false
        var producers: [Producer] = []
        var waiter: CheckedContinuation<String, Error>?
    }
    private let state = Mutex(State())

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// Stop releases the caller; collection keeps its output until every producer settles.
    func reply(collecting collect: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stopped = state.withLock {
                    guard !$0.stopped else { return true }
                    $0.waiter = continuation
                    return false
                }
                guard !stopped else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let collector = Task {
                    do { return Result<String, Error>.success(try await collect()) }
                    catch { return Result<String, Error>.failure(error) }
                }
                Task {
                    let result = await settle { await collector.value }
                    let waiter = self.state.withLock {
                        let waiter = $0.waiter
                        $0.waiter = nil
                        return waiter
                    }
                    waiter?.resume(with: result)
                }
            }
        } onCancel: { self.stop(releasingWaiter: true) }
    }

    /// HTTP stops its request task. Process-backed producers and forwarding tasks stay alive until exit and drain.
    func own<Value: Sendable>(_ task: Task<Value, Never>, stop: (@Sendable () -> Void)? = nil) {
        let producer = Producer(stop: stop ?? { task.cancel() }, join: { _ = await task.value })
        let stopNow = state.withLock {
            $0.producers.append(producer)
            return $0.stopped
        }
        if stopNow { producer.stop() }
    }

    /// A collection failure stops producers while keeping its original error for the caller.
    func stop() {
        stop(releasingWaiter: false)
    }

    private func stop(releasingWaiter: Bool) {
        let (owned, waiter) = state.withLock {
            let owned = $0.stopped ? [] : $0.producers
            $0.stopped = true
            let waiter = releasingWaiter ? $0.waiter : nil
            if releasingWaiter { $0.waiter = nil }
            return (owned, waiter)
        }
        waiter?.resume(throwing: CancellationError())
        for producer in owned { producer.stop() }
    }

    /// A joined producer can have installed another while it was ending. Walk every registration, including those made during an earlier join.
    func join() async {
        var joined = 0
        while true {
            let (batch, count) = state.withLock { (Array($0.producers.dropFirst(joined)), $0.producers.count) }
            guard !batch.isEmpty else { return }
            for producer in batch { await producer.join() }
            joined = count
        }
    }
}

private enum ReplyWorkPart: LLMCallPart { static let unset: ProviderReplyWork? = nil }
extension LLMCall {
    var replyWork: ProviderReplyWork? {
        get { self[ReplyWorkPart.self] }
        set { self[ReplyWorkPart.self] = newValue }
    }
}
