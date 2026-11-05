import Foundation
import NativeAgentShared
import os

// Blueprint: | `LifecyclePrimitives.swift` | `ScopedWaiter`, `OnceByKey`, `BoundedWait`: parking, keyed once and bounded waits |

// MARK: - ScopedWaiter

/// The one way a task parks; continuation bodies never touch isolated state. Shared with the phone; Core callers retain the same ScopedWaiter identity.
public typealias ScopedWaiter = NativeAgentShared.ScopedWaiter

// MARK: - OnceByKey

/// Runs an async operation at most once per key per process, with every later caller awaiting the SAME run to completion. Unlike a bare `[Key: Task]` memo
/// table, the in-flight `Task` (and everything its closure captured — typically a whole store/executor instance) is dropped once the run finishes; only a
/// completion marker is kept.
public actor OnceByKey<Key: Hashable & Sendable> {
    private enum State {
        case running(Task<Void, Error>)
        case done
    }

    private var states: [Key: State] = [:]
    public init() {}

    /// Failed operations leave the key pending, and every waiting caller sees the failure before it can cross its admission barrier.
    public func runChecked(_ key: Key, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        switch states[key] {
        case .done:
            return
        case .running(let task):
            try await task.value
        case nil:
            let task = Task { [weak self] in
                do {
                    try await operation()
                    await self?.markDone(key)
                } catch {
                    await self?.clearFailed(key)
                    throw error
                }
            }
            // Safe against a fast operation: `markDone` needs this actor, and this call holds it until the `await` below, so the assignment can never clobber
            // the marker.
            states[key] = .running(task)
            try await task.value
        }
    }

    /// The run itself releases its captures before its waiting callers resume.
    private func markDone(_ key: Key) {
        guard case .running = states[key] else { return }
        states[key] = .done
    }

    private func clearFailed(_ key: Key) {
        guard case .running = states[key] else { return }
        states[key] = nil
    }

}

// MARK: - BoundedWait

/// Thrown when a `BoundedWait` deadline expires. Typed on purpose: a caller that wants to tolerate a timeout must name it, and a `catch` that erases it is
/// visible in review.
public struct BoundedWaitTimeout: Error, LocalizedError, Sendable, Equatable {
    public let reason: String
    public let seconds: TimeInterval

    public init(reason: String, seconds: TimeInterval) {
        self.reason = reason
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "Timed out after \(seconds.rounded())s waiting for \(reason)."
    }
}

/// Every unbounded await gets a deadline by construction. No unbounded wait may be held under a file lock.
public enum BoundedWait {
    public static let logger = Logger(subsystem: "com.nativeagent.core", category: "bounded-wait")

    /// Cap deadlines to avoid holding a shared file lock for hours and to keep hostile interval values from overflowing nanosecond conversion.
    public static let maxDeadlineSeconds: TimeInterval = 900

    /// Expiry logs and throws BoundedWaitTimeout without joining noncooperative work. Cancel and abandon its unstructured task; it may retain captures until
    /// actual completion and its late result is discarded. Use only where late unobserved effects are acceptable. Caller cancellation likewise ends the wait
    /// without joining the operation.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        reason: String,
        deadlines: OperationDeadlines,
        operation: @escaping @Sendable (OperationDeadlines) async throws -> T
    ) async throws -> T {
        guard seconds > 0, seconds.isFinite else {
            throw BoundedWaitTimeout(reason: reason, seconds: max(0, seconds))
        }
        let deadline = clampedDeadline(seconds, reason: reason)
        do {
            let value = try await TurnDeadline.withThrowingDeadline(seconds: deadline, clock: .wallClock, deadlines: deadlines, operation)
            try Task.checkCancellation()
            return value
        } catch is TurnDeadline.DeadlineExceeded {
            try Task.checkCancellation()
            logger.error(
                "bounded wait expired after \(deadline, privacy: .public)s: \(reason, privacy: .public)"
            )
            throw BoundedWaitTimeout(reason: reason, seconds: deadline)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    /// Clamp every deadline path so an oversized bound cannot hold a shared lock for hours.
    static func clampedDeadline(_ seconds: TimeInterval, reason: String) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard seconds > maxDeadlineSeconds else { return seconds }
        logger.error(
            """
            bounded wait deadline \(seconds, privacy: .public)s exceeds the \
            \(maxDeadlineSeconds, privacy: .public)s maximum; clamped: \(reason, privacy: .public)
            """
        )
        return maxDeadlineSeconds
    }

    /// Invalid or oversized environment overrides use the configured default and report the rejection; accepting hours would turn a bounded file-lock wait into
    /// a system-wide stall.
    public static func seconds(fromEnv key: String, fallback: TimeInterval) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let parsed = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              parsed > 0, parsed.isFinite
        else { return fallback }
        guard parsed <= maxDeadlineSeconds else {
            logger.error(
                """
                \(key, privacy: .public)=\(parsed, privacy: .public)s exceeds the \
                \(maxDeadlineSeconds, privacy: .public)s maximum; rejected, using \
                \(fallback, privacy: .public)s
                """
            )
            return fallback
        }
        return parsed
    }
}
