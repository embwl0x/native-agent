import Foundation
import NativeAgentShared
import os

// Blueprint: | `LifecyclePrimitives.swift` | Core's `ScopedWaiter` aliases the shared one task parking primitive; `OnceByKey` and `BoundedWait` own keyed single execution and bounded waits |

// MARK: - ScopedWaiter

/// The one way a task parks; continuation bodies never touch isolated state.
/// Shared with the phone; Core callers retain the same ScopedWaiter identity.
public typealias ScopedWaiter = NativeAgentShared.ScopedWaiter

// MARK: - OnceByKey

/// Runs an async operation at most once per key per process, with every later
/// caller awaiting the SAME run to completion.
///
/// Unlike a bare `[Key: Task]` memo table, the in-flight `Task` (and everything
/// its closure captured — typically a whole store/executor instance) is dropped
/// once the run finishes; only a completion marker is kept.
public actor OnceByKey<Key: Hashable & Sendable> {
    private enum State {
        case running(Task<Void, Error>)
        case done
    }

    private var states: [Key: State] = [:]
    public init() {}

    /// Failed operations leave the key pending, and every waiting caller sees
    /// the failure before it can cross its admission barrier.
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
            // Safe against a fast operation: `markDone` needs this actor, and
            // this call holds it until the `await` below, so the assignment
            // can never clobber the marker.
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

/// Thrown when a `BoundedWait` deadline expires. Typed on purpose: a caller
/// that wants to tolerate a timeout must name it, and a `catch` that erases it
/// is visible in review.
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

/// Every unbounded await gets a deadline by construction.
///
/// No unbounded wait may be held under a file lock.
public enum BoundedWait {
    public static let logger = Logger(subsystem: "com.nativeagent.core", category: "bounded-wait")

    /// Longest deadline this type will honor. A "deadline" of hours is not a
    /// deadline — under the companion no-unbounded-wait-under-a-file-lock rule
    /// it wedges every other process on the same flock for that long. It also
    /// keeps the `TimeInterval -> UInt64` nanosecond conversion far away from
    /// the overflow that would TRAP the process on a hostile env value.
    public static let maxDeadlineSeconds: TimeInterval = 900

    /// Runs `operation` with a deadline that holds even when `operation` does
    /// NOT cooperate with cancellation. On expiry a LOGGED `BoundedWaitTimeout`
    /// naming `reason` is thrown and this call returns immediately.
    ///
    /// WHAT LEAKS ON EXPIRY: the operation runs in an unstructured `Task` that
    /// is CANCELLED and then ABANDONED. Cooperative work stops promptly.
    /// Non-cooperative work keeps running to completion in the background,
    /// holding its captures until then, and its result/error is discarded.
    /// That is the deliberate trade: a bounded caller plus a possibly-lingering
    /// background task, instead of an unbounded caller. Do not put work with
    /// externally visible side effects behind this deadline unless a late,
    /// unobserved completion is acceptable.
    ///
    /// Cancellation of the calling task settles the wait with
    /// `CancellationError` and cancels `operation` without awaiting it.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        reason: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0, seconds.isFinite else {
            throw BoundedWaitTimeout(reason: reason, seconds: max(0, seconds))
        }
        let deadline = clampedDeadline(seconds, reason: reason)
        do {
            let value = try await TurnDeadline.withThrowingDeadline(seconds: deadline, clock: .wallClock, operation)
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

    /// Clamps a requested deadline into `(0, maxDeadlineSeconds]`, logging the
    /// clamp. Called by every deadline path so nothing can smuggle an
    /// hours-long "bound" past the companion rule.
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

    /// Reads a positive TimeInterval override from the environment, falling
    /// back to `fallback`. Keeps deadline constants testable without a global.
    ///
    /// An override above `maxDeadlineSeconds` is REJECTED (falls back) and
    /// logged, not honored: stretching a 300s guard to hours re-creates the
    /// system-wide flock wedge the guard exists to prevent, and honoring it
    /// silently would make the wedge look like normal slowness.
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
