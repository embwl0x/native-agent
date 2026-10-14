import Foundation

public enum TurnDeadline {
    /// Run `work` with a hard wall-clock ceiling, returning nil when the ceiling
    /// wins. Work runs as an unstructured child so the caller returns
    /// the moment the ceiling passes: a task group would still wait for a
    /// stuck operation to observe its cancellation before the scope closes.
    /// The loser is cancelled and its late result is discarded.
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
                    // Claim expiry before cancelling work so a cooperative
                    // child cannot turn deadline expiry into a user Stop.
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
