import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LoopContracts.swift` | LoopRunner and event/deadline contracts, registrations, outcomes, backoff policy and bounded tick execution |

/// Typed result of one background-loop attempt. Returning from `tick()` is not
/// itself proof of success: loops that handle their own errors override
/// `tickOutcome()` so the scheduler can preserve honest state and receipts.
public enum LoopTickOutcome: Sendable, Equatable {
    case completed(result: String?)
    /// Health-neutral skips preserve the failure streak, including self-backoff;
    /// ordinary nothing-to-do skips remain health signals.
    case skipped(reason: String, healthNeutral: Bool = false)
    case failed(error: String)

    /// Joining an active tick is health-neutral and preserves the consecutive-failure streak.
    public static let coalescedSkipReason = "coalesced with active tick"
    /// An opportunistic wake arrived before the canonical durable cadence was
    /// eligible. The wake is only a signal; it does not advance loop health,
    /// counters, or the durable last-run clock.
    public static let notDueSkipReason = "durable cadence not due"

    /// Constructor for "I am skipping because I am failing". Prefer this over
    /// a bare `.skipped(reason:)` in any loop that gates itself behind its own
    /// backoff/cooldown after an operational failure.
    public static func backingOff(reason: String) -> LoopTickOutcome {
        .skipped(reason: reason, healthNeutral: true)
    }

    /// A tick has one of four words: worked (`.completed`, the only outcome
    /// that stamps `lastCompletedAt`), nothing to do (a plain skip), off (its
    /// config switches it off) and not needed (another authority already does
    /// its job). Off and not needed are skips whose reason carries the word,
    /// so Doctor never counts them as healthy work.
    public static let offPrefix = "off: "
    public static let notNeededPrefix = "not needed: "

    public static func off(_ reason: String) -> LoopTickOutcome {
        .skipped(reason: offPrefix + reason)
    }

    public static func notNeeded(_ reason: String) -> LoopTickOutcome {
        .skipped(reason: notNeededPrefix + reason)
    }

    /// True only for the manager's single-flight coalesce skip.
    public var isCoalescedSkip: Bool {
        if case .skipped(let reason, _) = self { return reason == Self.coalescedSkipReason }
        return false
    }

    /// True when this outcome proves nothing about the loop's health and must
    /// therefore leave the consecutive-failure streak untouched. Covers both
    /// the coalesced skip and any loop-declared health-neutral skip.
    public var isHealthNeutralSkip: Bool {
        if case .skipped(let reason, let healthNeutral) = self {
            return healthNeutral || reason == Self.coalescedSkipReason
        }
        return false
    }
}

/// Exponential-with-jitter retry curve applied by the scheduler when a loop's
/// tick fails, and by Telegram's intra-tick deadline gate. Each caller owns
/// its failure counter and deadline; this policy owns the curve.
public struct LoopFailureBackoffPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var multiplier: Double
    public var jitterRange: ClosedRange<Double>

    /// Defaults: 5s → 300s cap, doubling, ±20% jitter, reset on first success.
    public init(
        baseDelay: TimeInterval = 5,
        maxDelay: TimeInterval = 300,
        multiplier: Double = 2,
        jitterRange: ClosedRange<Double> = 0.8...1.2
    ) {
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.multiplier = max(1, multiplier)
        self.jitterRange = jitterRange
    }

    public static let `default` = LoopFailureBackoffPolicy()

    /// `base * multiplier^(n-1)`, capped at `maxDelay`, jittered, then
    /// re-clamped so the documented cap is a hard ceiling.
    public func delay(
        forConsecutiveFailures failures: Int,
        jitter: (ClosedRange<Double>) -> Double
    ) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 64))
        let raw = min(maxDelay, baseDelay * pow(multiplier, exponent))
        return min(maxDelay, max(0, raw * jitter(jitterRange)))
    }
}

/// A nonthrowing worker whose required `tickOutcome()` reports honest failure
/// or skip evidence for durable state and receipts. Work belongs there;
/// `tick()` only discards its result and must not be reimplemented.
/// Cancellation must be observed promptly or work survives `stop()`;
/// `tickWithTimeoutOutcome(_:timeout:)` bounds the caller's wait.
public protocol LoopRunner: Sendable {
    var loopId: String { get }
    var interval: TimeInterval { get }
    /// Dynamically dispatched timeout override; nil uses the scheduler's default (300s).
    var tickTimeoutOverride: TimeInterval? { get }
    /// Required honest outcome; no default completion.
    func tickOutcome() async -> LoopTickOutcome
    /// Default entry point discards `tickOutcome()`; do not reimplement it.
    func tick() async
    /// Cancels and drains work that the loop intentionally owns beyond one
    /// admitted tick. Most loops own no such work and use the default no-op.
    func shutdown() async
}

public extension LoopRunner {
    var tickTimeoutOverride: TimeInterval? { nil }

    func tick() async {
        _ = await tickOutcome()
    }

    func shutdown() async {}
}

/// A configured worker or a visible lane with no work to schedule.
public enum LoopRegistration: Sendable {
    case enabled(any LoopRunner)
    case disabled(loopId: String, reason: String)
    /// Its configuration could not be read: a fault that says its cause, never
    /// off (an unreadable credential is not "not connected").
    case unreadable(loopId: String, error: String)

    public var loopId: String {
        switch self {
        case .enabled(let runner): runner.loopId
        case .disabled(let loopId, _), .unreadable(let loopId, _): loopId
        }
    }

    public var runner: (any LoopRunner)? {
        if case .enabled(let runner) = self { return runner }
        return nil
    }
}

/// An event-first background worker with one optional exact persisted deadline.
///
/// `interval` remains the deliberately slow integrity sweep used to recover a
/// process-local event lost across a crash or an out-of-process write the
/// primary signal path could not observe. Normal work is driven by
/// `physiologyEvents()` and `nextMeaningfulDeadline(after:)`; neither path may
/// manufacture user intent or provider work merely because time passed.
public protocol EventDeadlineLoopRunner: LoopRunner {
    /// Multicast/domain event stream. Events carry no authority or payload;
    /// the tick rereads the canonical owner.
    func physiologyEvents() -> AsyncStream<Void>
    /// Earliest future instant at which a persisted state transition becomes
    /// eligible. Return nil when no crossing exists. A date at/before `now`
    /// is reconciled by the manager's startup/event pass and is not rescheduled
    /// as a spin loop.
    func nextMeaningfulDeadline(after now: Date) async -> Date?
    /// Trailing-edge burst coalescing before the canonical reread.
    var eventCoalescingDelay: TimeInterval { get }
}

public extension EventDeadlineLoopRunner {
    var eventCoalescingDelay: TimeInterval { 0.25 }
}

/// Thrown by `tickWithTimeoutOutcome` when a tick exceeds its allotted budget.
public struct TickTimeoutError: Error, Equatable {
    public init() {}
}

/// Race one tick against its deadline, throwing `TickTimeoutError` on expiry.
/// The unstructured tick is cancelled on timeout; it can outlive the caller's
/// bounded wait until it observes cancellation or returns.
public func tickWithTimeoutOutcome(
    _ operation: @escaping @Sendable () async -> LoopTickOutcome,
    timeout: TimeInterval
) async throws -> LoopTickOutcome {
    let result = await raceAgainstTimeout(nanoseconds: timeoutNanoseconds(timeout)) {
        await operation()
    }

    switch result {
    case .value(let outcome):
        return outcome
    case .failure(let error):
        return .failed(error: error)
    case .timedOut:
        throw TickTimeoutError()
    case .cancelled:
        throw CancellationError()
    }
}

internal func timeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    let nanoseconds = seconds * 1_000_000_000
    guard nanoseconds > 0 else { return 0 }
    // Double(UInt64.max) rounds UP to 2^64, which cannot be converted.
    guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
    return UInt64(nanoseconds)
}
