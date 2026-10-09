import Foundation

public enum TurnDeadline {
    /// Run `work` with a hard wall-clock ceiling, returning nil when the ceiling
    /// wins. The distill runs as an unstructured child so the caller returns
    /// the moment the ceiling passes: a task group would still wait for a
    /// stuck provider request to observe its cancellation before the scope
    /// closed, and this path exists to keep the turn moving. The loser is
    /// cancelled so a timed-out distill stops paying for tokens the fold will
    /// not use.
    public static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async -> T? {
        try? await withThrowingDeadline(seconds: seconds, work)
    }

    public struct DeadlineExceeded: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The operation exceeded its deadline." }
    }

    /// Preserve provider/storage errors separately from deadline expiry and Stop.
    public static func withThrowingDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let child = Task { () -> Result<T, Error> in
            do { return .success(try await work()) }
            catch { return .failure(error) }
        }
        let sleeper = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let once = ContinuationOnce<Result<T, Error>>()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
                once.install(continuation)
                Task {
                    let value = await child.value
                    sleeper.cancel()
                    once.resume(value)
                }
                Task {
                    await sleeper.value
                    guard !sleeper.isCancelled else { return }
                    // User, 2026-09-06: CLAIM FIRST, THEN CANCEL — the same
                    // order the provider completion wall uses. Cancelling the
                    // child first let cooperative work observe the
                    // cancellation and win the gate with its own outcome, so a
                    // deadline expiry arrived as a CancellationError: a tool
                    // dispatch that ran out its ceiling was reported as a user
                    // Stop (ToolLoop `runSingleDispatch`) and Workshop turned
                    // the same race into `.failed` instead of a deadline.
                    once.resume(.failure(DeadlineExceeded()))
                    child.cancel()
                }
            }
        } onCancel: {
            // A Stop must return NOW, even if the provider ignores its
            // cancellation (Codex review 2026-09-05: it used to wait for
            // the child to finish).
            once.resume(.failure(CancellationError()))
            child.cancel()
            sleeper.cancel()
        }
        return try result.get()
    }

    /// Resume-once gate for the racers above. Resuming before the
    /// continuation is installed is remembered and applied on install, so a
    /// cancellation that lands first still resolves the wait.
    private final class ContinuationOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var pending: (value: T?, resolved: Bool) = (nil, false)
        func install(_ continuation: CheckedContinuation<T, Never>) {
            lock.lock()
            if pending.resolved {
                lock.unlock()
                continuation.resume(returning: pending.value!)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
        func resume(_ value: T) {
            lock.lock()
            guard !pending.resolved else { lock.unlock(); return }
            pending = (value, true)
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}
