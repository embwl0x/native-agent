import Foundation
// Blueprint: | `TurnDeadline.swift` | `TurnDeadline` class; shared active-work deadline pauses while awaiting a person |

public final class TurnDeadline: @unchecked Sendable {
    @TaskLocal private static var current: [TurnDeadline] = []
    @TaskLocal public static var humanWait: (@Sendable (Bool) -> Void)?
    private let lock = NSLock()
    private var remaining: Duration
    private var started: ContinuousClock.Instant?
    private var sleeper: Task<Void, Never>?
    private var expiry: (@Sendable () -> Void)?
    private var waits = 0

    private init(seconds: TimeInterval) { remaining = .seconds(seconds) }

    /// A person's answer has no clock. Nested calls pause every enclosing deadline.
    public nonisolated(nonsending) static func withHumanWait<T>(_ work: () async throws -> T) async rethrows -> T {
        let deadlines = current
        for deadline in deadlines { deadline.pause() }
        humanWait?(true)
        defer { humanWait?(false); for deadline in deadlines { deadline.resume() } }
        return try await work()
    }

    private func pause() {
        lock.withLock {
            waits += 1
            if let started { remaining -= started.duration(to: .now) }
            started = nil
            sleeper?.cancel()
            sleeper = nil
        }
    }

    private func resume() {
        lock.withLock { waits -= 1; arm() }
    }

    private func arm() {
        guard waits == 0, let expiry else { return }
        let start = ContinuousClock.now
        started = start
        let remaining = remaining
        sleeper = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            let won = self?.lock.withLock {
                guard self?.started == start else { return false }
                self?.started = nil
                self?.expiry = nil
                return true
            } == true
            if won { expiry() }
        }
    }

    private func stop() {
        lock.withLock { expiry = nil; started = nil; sleeper?.cancel(); sleeper = nil }
    }

    /// Run `work` with an active-work ceiling, returning nil when the ceiling
    /// wins. Work runs as an unstructured child so the caller returns
    /// the moment the ceiling passes: a task group would still wait for a
    /// stuck operation to observe its cancellation before the scope closes.
    /// The loser is cancelled and its late result is discarded.
    /// This bounds the response, not execution. Callers must keep exclusion
    /// and resources inside `work` until its actual exit, even after timeout.
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
        let deadline = TurnDeadline(seconds: seconds)
        let deadlines = current + [deadline]
        let child = Task { () -> Result<T, Error> in
            do { return .success(try await Self.$current.withValue(deadlines) { try await work() }) }
            catch { return .failure(error) }
        }
        let once = ContinuationOnce<Result<T, Error>>()
        deadline.lock.withLock {
            deadline.expiry = {
                once.resume(.failure(DeadlineExceeded()))
                child.cancel()
            }
            deadline.arm()
        }
        defer { deadline.stop() }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
                once.install(continuation)
                Task {
                    let value = await child.value
                    deadline.stop()
                    once.resume(value)
                }
            }
        } onCancel: {
            // A Stop must return NOW, even if the provider ignores its
            // cancellation (Codex review 2026-09-05: it used to wait for
            // the child to finish).
            once.resume(.failure(CancellationError()))
            child.cancel()
            deadline.stop()
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
