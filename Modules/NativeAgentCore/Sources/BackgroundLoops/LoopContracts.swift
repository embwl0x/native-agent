import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LoopContracts.swift` | LoopRunner and event/deadline contracts, registrations, outcomes, backoff policy and bounded tick execution |

/// Returning from tick is not success proof; tickOutcome preserves the worker’s real outcome for state and receipts.
public enum LoopTickOutcome: Sendable, Equatable {
    case completed(result: String?)
    /// Health-neutral skips preserve the failure streak, including self-backoff;
    /// ordinary nothing-to-do skips remain health signals.
    case skipped(reason: String, healthNeutral: Bool = false)
    case failed(error: String)

    /// Joining an active tick is health-neutral and preserves the consecutive-failure streak.
    public static let coalescedSkipReason = "coalesced with active tick"
    /// An early OS wake is only a signal; it cannot advance health, counters or the durable cadence.
    public static let notDueSkipReason = "durable cadence not due"

    /// Use health-neutral skips for self-backoff so an operational failure cannot erase its own streak.
    public static func backingOff(reason: String) -> LoopTickOutcome {
        .skipped(reason: reason, healthNeutral: true)
    }

    /// Only completed work stamps lastCompletedAt; off/not-needed skip reasons must not count as healthy work.
    public static let offPrefix = "off: "
    public static let notNeededPrefix = "not needed: "

    public static func off(_ reason: String) -> LoopTickOutcome {
        .skipped(reason: offPrefix + reason)
    }

    public static func notNeeded(_ reason: String) -> LoopTickOutcome {
        .skipped(reason: notNeededPrefix + reason)
    }

    /// A shared slot held by other work is busy, not broken; the words name the holder and when to try again.
    public static let busyPrefix = "busy: "

    public static func busy(_ reason: String) -> LoopTickOutcome {
        .skipped(reason: busyPrefix + reason)
    }

    public var isCoalescedSkip: Bool {
        if case .skipped(let reason, _) = self { return reason == Self.coalescedSkipReason }
        return false
    }

    /// Coalesced and explicitly health-neutral skips provide no health evidence and must preserve the failure streak.
    public var isHealthNeutralSkip: Bool {
        if case .skipped(let reason, let healthNeutral) = self {
            return healthNeutral || reason == Self.coalescedSkipReason
        }
        return false
    }
}

/// Share the retry curve, while each scheduler or Telegram deadline gate owns its counter and deadline.
public struct LoopFailureBackoffPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var multiplier: Double
    public var jitterRange: ClosedRange<Double>

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

    /// Clamp after jitter as well as before it so maxDelay remains a hard ceiling.
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

/// Require honest tickOutcome evidence; tick only discards that result and must not be reimplemented.
/// Observe cancellation promptly: timeout bounds the caller’s wait, while uncooperative work can outlive stop.
/// What wakes an organ of the body. A rhythm is its nature (a daily backup, a weekly Doctor run, a presence heartbeat). An organ that runs on change
/// has no clock: its events, its own next meaningful deadline and launch are its only wakes, so a missed event is a defect fixed where it was lost,
/// never covered by a slow repair pass.
public enum OrganWake: Sendable, Equatable {
    case every(TimeInterval)
    case onChange

    /// The rhythm's period, or nil for an organ that runs on change (never overdue).
    public var period: TimeInterval? {
        if case .every(let period) = self { return max(0, period) }
        return nil
    }
}

public protocol LoopRunner: Sendable {
    var loopId: String { get }
    var wake: OrganWake { get }
    /// A nil timeout override uses the scheduler’s 300-second default.
    var tickTimeoutOverride: TimeInterval? { get }
    /// Require explicit outcomes; no default completion can stand in for work.
    func tickOutcome() async -> LoopTickOutcome
    /// Do not reimplement tick: its sole purpose is to discard the required tickOutcome result.
    func tick() async
    /// Stop must cancel and drain work intentionally retained beyond an admitted tick.
    func shutdown() async
}

public extension LoopRunner {
    var tickTimeoutOverride: TimeInterval? { nil }

    func tick() async {
        _ = await tickOutcome()
    }

    func shutdown() async {}
}

public enum LoopRegistration: Sendable {
    case enabled(any LoopRunner)
    case disabled(loopId: String, reason: String)
    /// Unreadable configuration is unavailable, never off or disconnected.
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

/// Events carry normal work and the organ's own deadline crosses persisted eligibility; it never manufactures intent or provider work. An organ with
/// `wake: .onChange` has nothing else; one whose nature is also a rhythm declares `.every`.
public protocol EventDeadlineLoopRunner: LoopRunner {
    /// Events carry no authority or payload; reread the canonical owner on each tick.
    func physiologyEvents() -> AsyncStream<Void>
    /// Return nil without a future crossing; reconcile already-due dates once rather than rescheduling a spin loop.
    func nextMeaningfulDeadline(after now: Date) async -> Date?
    /// Coalesce event bursts before rereading the canonical owner.
    var eventCoalescingDelay: TimeInterval { get }
}

public extension EventDeadlineLoopRunner {
    var eventCoalescingDelay: TimeInterval { 0.25 }
}

public struct TickTimeoutError: Error, Equatable {
    public init() {}
}

/// Timeout cancels the tick and bounds only its caller’s wait; physical work remains alive until it observes cancellation.
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
