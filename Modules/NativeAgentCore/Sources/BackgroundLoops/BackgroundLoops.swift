import Foundation
import NativeAgentCore
import PersistenceCore
import TriggerScheduler

// MARK: - Subsystem #15: BackgroundLoops
//
// SwiftNative owns the app runtime inspection/control surface.
//
// Scope: the HTTP-exposed INSPECTION/CONTROL surface of NativeAgent's
// background-loop subsystem — watchdog status + scheduler-jobs list +
// scheduler-job create. The long-running workers are owned by
// BackgroundLoopsManager / SwiftNativeLoopScheduler; scheduler jobs are
// managed through TriggerScheduler's Swift-native writer.
//
// Routes verified against live daemon 2026-05-31:
//   GET  /v1/watchdog            — daemon liveness/lifecycle, last activity, repair flag
//   GET  /v1/scheduler/jobs      — array of scheduled jobs (improve, harness_benchmark,
//                                  notify, ...); each item has id/kind/intervalSeconds/
//                                  enabled/nextRunAt/payload + camelCase extras
//   POST /v1/scheduler/jobs      — create_job(body); body is opaque to this layer

// MARK: - WatchdogStatus

public struct WatchdogStatus: Sendable, Codable, Equatable {
    public var daemon: String?
    public var uptimeSeconds: Double?
    public var daemonLifecycleStatus: String?
    public var daemonLifecycleDetail: String?
    public var launchAgentStatus: String?
    public var launchAgentDetail: String?
    public var runningImprovements: Int?
    public var runningExecutions: Int?
    public var lastActivity: JSONValue?
    public var repairAvailable: Bool?
    public var extras: JSONValue?

    public init(
        daemon: String? = nil,
        uptimeSeconds: Double? = nil,
        daemonLifecycleStatus: String? = nil,
        daemonLifecycleDetail: String? = nil,
        launchAgentStatus: String? = nil,
        launchAgentDetail: String? = nil,
        runningImprovements: Int? = nil,
        runningExecutions: Int? = nil,
        lastActivity: JSONValue? = nil,
        repairAvailable: Bool? = nil,
        extras: JSONValue? = nil
    ) {
        self.daemon = daemon
        self.uptimeSeconds = uptimeSeconds
        self.daemonLifecycleStatus = daemonLifecycleStatus
        self.daemonLifecycleDetail = daemonLifecycleDetail
        self.launchAgentStatus = launchAgentStatus
        self.launchAgentDetail = launchAgentDetail
        self.runningImprovements = runningImprovements
        self.runningExecutions = runningExecutions
        self.lastActivity = lastActivity
        self.repairAvailable = repairAvailable
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "daemon",
        "uptimeSeconds",
        "daemonLifecycleStatus", "daemonLifecycleDetail",
        "launchAgentStatus", "launchAgentDetail",
        "runningImprovements", "runningMissions",
        "lastActivity",
        "repairAvailable",
        "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        func dbl(_ k: String) -> Double? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil
        }
        func int(_ k: String) -> Int? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil
        }
        func bool(_ k: String) -> Bool? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil
        }
        func jv(_ k: String) -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(JSONValue.self, forKey: key)) ?? nil
        }

        self.daemon = str("daemon")
        self.uptimeSeconds = dbl("uptimeSeconds")
        self.daemonLifecycleStatus = str("daemonLifecycleStatus")
        self.daemonLifecycleDetail = str("daemonLifecycleDetail")
        self.launchAgentStatus = str("launchAgentStatus")
        self.launchAgentDetail = str("launchAgentDetail")
        self.runningImprovements = int("runningImprovements")
        self.runningExecutions = int("runningMissions")
        self.lastActivity = jv("lastActivity")
        self.repairAvailable = bool("repairAvailable")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = jv("extras"), case .object(let obj) = explicit {
            for (k, v) in obj { unknown[k] = v }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(daemon, forKey: AnyKey("daemon"))
        try c.encodeIfPresent(uptimeSeconds, forKey: AnyKey("uptimeSeconds"))
        try c.encodeIfPresent(daemonLifecycleStatus, forKey: AnyKey("daemonLifecycleStatus"))
        try c.encodeIfPresent(daemonLifecycleDetail, forKey: AnyKey("daemonLifecycleDetail"))
        try c.encodeIfPresent(launchAgentStatus, forKey: AnyKey("launchAgentStatus"))
        try c.encodeIfPresent(launchAgentDetail, forKey: AnyKey("launchAgentDetail"))
        try c.encodeIfPresent(runningImprovements, forKey: AnyKey("runningImprovements"))
        try c.encodeIfPresent(runningExecutions, forKey: AnyKey("runningMissions"))
        try c.encodeIfPresent(lastActivity, forKey: AnyKey("lastActivity"))
        try c.encodeIfPresent(repairAvailable, forKey: AnyKey("repairAvailable"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - SchedulerJob

public struct SchedulerJob: Sendable, Codable, Equatable {
    public var id: String
    public var kind: String?
    public var name: String?
    public var intervalSeconds: Double?
    public var enabled: Bool?
    public var payload: JSONValue?
    public var nextRunAt: String?
    public var lastRunAt: String?
    public var createdAt: String?
    public var createdBy: String?
    public var cancelledAt: String?
    public var oneShot: Bool?
    public var extras: JSONValue?

    public init(
        id: String,
        kind: String? = nil,
        name: String? = nil,
        intervalSeconds: Double? = nil,
        enabled: Bool? = nil,
        payload: JSONValue? = nil,
        nextRunAt: String? = nil,
        lastRunAt: String? = nil,
        createdAt: String? = nil,
        createdBy: String? = nil,
        cancelledAt: String? = nil,
        oneShot: Bool? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.intervalSeconds = intervalSeconds
        self.enabled = enabled
        self.payload = payload
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.cancelledAt = cancelledAt
        self.oneShot = oneShot
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "id", "kind", "name",
        "intervalSeconds",
        "enabled",
        "payload",
        "nextRunAt", "lastRunAt", "createdAt",
        "createdBy",
        "cancelledAt",
        "oneShot",
        "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        func dbl(_ k: String) -> Double? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil
        }
        func bool(_ k: String) -> Bool? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil
        }
        func jv(_ k: String) -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(JSONValue.self, forKey: key)) ?? nil
        }

        self.id = str("id") ?? ""
        self.kind = str("kind")
        self.name = str("name")
        self.intervalSeconds = dbl("intervalSeconds")
        self.enabled = bool("enabled")
        self.payload = jv("payload")
        self.nextRunAt = str("nextRunAt")
        self.lastRunAt = str("lastRunAt")
        self.createdAt = str("createdAt")
        self.createdBy = str("createdBy")
        self.cancelledAt = str("cancelledAt")
        self.oneShot = bool("oneShot")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = jv("extras"), case .object(let obj) = explicit {
            for (k, v) in obj { unknown[k] = v }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encodeIfPresent(kind, forKey: AnyKey("kind"))
        try c.encodeIfPresent(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(intervalSeconds, forKey: AnyKey("intervalSeconds"))
        try c.encodeIfPresent(enabled, forKey: AnyKey("enabled"))
        try c.encodeIfPresent(payload, forKey: AnyKey("payload"))
        try c.encodeIfPresent(nextRunAt, forKey: AnyKey("nextRunAt"))
        try c.encodeIfPresent(lastRunAt, forKey: AnyKey("lastRunAt"))
        try c.encodeIfPresent(createdAt, forKey: AnyKey("createdAt"))
        try c.encodeIfPresent(createdBy, forKey: AnyKey("createdBy"))
        try c.encodeIfPresent(cancelledAt, forKey: AnyKey("cancelledAt"))
        try c.encodeIfPresent(oneShot, forKey: AnyKey("oneShot"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - SchedulerJobCreateResult

public struct SchedulerJobCreateResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }
    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

public enum BackgroundLoopsError: Error, LocalizedError {
    case invalidRequest
    case notFound
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "backgroundLoops: invalid request"
        case .notFound: return "backgroundLoops: not found"
        case .invalidResponse(let s): return "backgroundLoops: native implementation returned unexpected status \(s)"
        case .unavailable: return "backgroundLoops: unavailable"
        case .underlying(let m): return "backgroundLoops: \(m)"
        }
    }
}

// MARK: - Protocol

public protocol BackgroundLoopsProtocol: Sendable {
    func getWatchdog() async throws -> WatchdogStatus
    func listSchedulerJobs() async throws -> [SchedulerJob]
    func createSchedulerJob(_ body: JSONValue) async throws -> SchedulerJobCreateResult
}

// MARK: - SwiftNative impl

/// SwiftNative background-loop surface. Default construction is fully native:
/// watchdog state comes from BackgroundLoopsManager, and scheduler jobs flow
/// through TriggerScheduler's Swift-native job writer.
public actor SwiftNativeBackgroundLoops: BackgroundLoopsProtocol {
    private let jobWriter: any SchedulerJobWriter
    private let manager: BackgroundLoopsManager
    private let startedAt: Date
    private let now: @Sendable () -> Date

    public init(
        jobWriter: (any SchedulerJobWriter)? = nil,
        manager: BackgroundLoopsManager = BackgroundLoopsManager.shared,
        startedAt: Date = Date(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.jobWriter = jobWriter ?? makeSchedulerJobWriter()
        self.manager = manager
        self.startedAt = startedAt
        self.now = now
    }

    public func getWatchdog() async throws -> WatchdogStatus {
        let running = await manager.isRunning()
        let statuses = await manager.status()
        let newest = statuses.compactMap(\.lastRun).max()
        let lastActivity: JSONValue? = newest.map { lastRun in
            .object([
                "id": .string("background-loops-watchdog-\(Int64(lastRun.timeIntervalSince1970))"),
                "kind": .string("background_loops"),
                "title": .string("Swift background loop tick"),
                "detail": .string("Latest registered loop tick."),
                "status": .string(running ? "ok" : "stopped"),
                "executionId": .null,
                "createdAt": .string(Self.isoTimestamp(lastRun)),
            ])
        }
        let loopStatus: JSONValue = .array(statuses.map { status in
            .object([
                "name": .string(status.name),
                "lastRunAt": status.lastRun.map { .string(Self.isoTimestamp($0)) } ?? .null,
                "nextRunAt": status.nextRun.map { .string(Self.isoTimestamp($0)) } ?? .null,
                "runCount": .int(Int64(status.runCount)),
                "lastError": status.lastError.map { .string($0) } ?? .null,
            ])
        })
        return WatchdogStatus(
            daemon: "swift",
            uptimeSeconds: max(0, now().timeIntervalSince(startedAt)),
            daemonLifecycleStatus: running ? "ok" : "stopped",
            daemonLifecycleDetail: running
                ? "Swift background loops are running in NativeAgent.app."
                : "Swift background loops are not running.",
            launchAgentStatus: "not_applicable",
            launchAgentDetail: "NativeAgent.app owns background loops; legacy daemon launch agents are retired.",
            runningImprovements: 0,
            runningExecutions: 0,
            lastActivity: lastActivity,
            repairAvailable: false,
            extras: .object([
                "backend": .string("swift"),
                "loopCount": .int(Int64(statuses.count)),
                "running": .bool(running),
                "loops": loopStatus,
            ])
        )
    }

    public func listSchedulerJobs() async throws -> [SchedulerJob] {
        let jobs = try await jobWriter.listJobs()
        return try jobs.map { try Self.decode($0, as: SchedulerJob.self) }
    }

    public func createSchedulerJob(_ body: JSONValue) async throws -> SchedulerJobCreateResult {
        let response = try await jobWriter.createJob(body: body)
        return SchedulerJobCreateResult(rawResponse: response)
    }

    private nonisolated static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }
}

// MARK: - Factory

public func makeBackgroundLoops() -> any BackgroundLoopsProtocol {
    return SwiftNativeBackgroundLoops()
}

// MARK: - Phase B: Swift periodic-tick framework
//
// LoopRunner / LoopState / SwiftNativeLoopScheduler are the Swift framework
// for in-process periodic background work.

/// Typed result of one background-loop attempt. Returning from `tick()` is not
/// itself proof of success: loops that handle their own errors override
/// `tickOutcome()` so the scheduler can preserve honest state and receipts.
public enum LoopTickOutcome: Sendable, Equatable {
    case completed(result: String?)
    /// `healthNeutral: true` declares "this skip is NOT evidence the loop is
    /// healthy". The canonical case is a loop that skips BECAUSE it is inside
    /// its own failure-backoff window (TelegramPollLoop). Before this flag
    /// existed the scheduler cleared the consecutive-failure streak on every
    /// non-coalesced skip, so a self-backing-off loop on a 2s cadence reset
    /// its own streak between every real failure and the failure-streak push
    /// could NEVER fire — a revoked token or offline Mac stayed silent
    /// forever. Defaults to `false` so an ordinary "nothing to do" skip
    /// remains a genuine health signal.
    case skipped(reason: String, healthNeutral: Bool = false)
    case failed(error: String)

    /// The manager's single-flight gate returns this reason when a tick
    /// request joins an already-active execution instead of running. Shared
    /// constant so the scheduler's failure-streak accounting can recognize it:
    /// a coalesced skip is "someone else is executing", NOT evidence of
    /// health, and must not reset the consecutive-failure streak (gpt-5.5
    /// BLOCKING, A4.8 round).
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
/// tick FAILS. Same shape as `TelegramExponentialBackoff` (which stays as the
/// Telegram poll loop's own intra-tick gate); this one lives at the scheduler
/// so every loop gets failure backoff, not just the one that hand-rolled it.
///
/// Without it a 2s-interval loop re-hit a dead endpoint every 2 seconds
/// forever (Slack socket mode against a revoked token).
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

/// A single periodic worker the scheduler drives. Neither entry point may
/// throw. `tickOutcome()` is the PRIMARY method every loop implements: the
/// scheduler records the returned `LoopTickOutcome` as the loop's durable state
/// and failure receipt. A loop that catches operational failure MUST return the
/// honest outcome (`.failed`/`.skipped`) from `tickOutcome()` rather than
/// converting failure into a successful tick. `tick()` is a defaulted
/// fire-and-forget wrapper (see the extension) that discards the outcome — no
/// loop should hand-roll it, and error-catching work must NOT live only in a
/// custom `tick()` where its outcome would be lost.
///
/// CANCELLATION CONTRACT: `tickOutcome()` MUST honor `Task.isCancelled` /
/// `Task.checkCancellation()` and return promptly when cancellation is
/// observed. Swift cancellation is cooperative — a tick body that ignores
/// it will keep running after `stop()` and the wrapping scheduler Task will
/// leak even though it is marked cancelled. For callers that need a hard
/// upper bound on a single tick, use `tickWithTimeout(_:timeout:)`.
public protocol LoopRunner: Sendable {
    var loopId: String { get }
    var interval: TimeInterval { get }
    /// Per-loop override for the scheduler's uniform tick timeout (300s
    /// default). nil → use the scheduler's value. Loops whose tick
    /// legitimately runs long — a full Telegram chat turn with tool
    /// subprocesses, a weekly LLM consolidation pass — MUST override, or
    /// the 300s budget cancels them mid-LLM-call with no user-visible
    /// trace (audit 2026-06-09). Requirement (not extension-only) so the
    /// override dispatches dynamically through `any LoopRunner`.
    var tickTimeoutOverride: TimeInterval? { get }
    /// Per-loop override for the scheduler's failure-backoff curve. nil → the
    /// scheduler's default policy. A requirement (not extension-only) so the
    /// override dispatches dynamically through `any LoopRunner`, exactly like
    /// `tickTimeoutOverride`.
    var failureBackoffPolicy: LoopFailureBackoffPolicy? { get }
    /// The honest per-tick outcome. Required — there is no default, so every
    /// loop implements it and the scheduler always records a real outcome
    /// rather than a swallowed `.completed`.
    func tickOutcome() async -> LoopTickOutcome
    /// Fire-and-forget entry point. Defaulted to call `tickOutcome()` and
    /// discard the result (see extension); a loop should not implement it.
    func tick() async
    /// Cancels and drains work that the loop intentionally owns beyond one
    /// admitted tick. Most loops own no such work and use the default no-op.
    func shutdown() async
}

public extension LoopRunner {
    var tickTimeoutOverride: TimeInterval? { nil }
    var failureBackoffPolicy: LoopFailureBackoffPolicy? { nil }

    func tick() async {
        _ = await tickOutcome()
    }

    func shutdown() async {}
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

/// Thrown by `tickWithTimeout` when a tick exceeds its allotted budget.
public struct TickTimeoutError: Error, Equatable {
    public init() {}
}

/// Race a single `tick()` against a timeout. Throws `TickTimeoutError` if
/// the deadline elapses before the tick returns. The tick branch is
/// intentionally unstructured: the caller gets its upper bound even if a
/// buggy loop ignores Swift's cooperative cancellation. The timed-out tick is
/// cancelled, but it may keep running until its body observes cancellation or
/// returns on its own.
public func tickWithTimeoutOutcome(
    _ loop: any LoopRunner,
    timeout: TimeInterval
) async throws -> LoopTickOutcome {
    let race = TickRace()
    let tickTask = Task {
        let outcome = await loop.tickOutcome()
        await race.resolve(.finished(outcome))
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: timeoutNanoseconds(timeout))
            await race.resolve(.timedOut)
        } catch {
            // Cancelled because the tick finished first.
        }
    }

    let result = await withTaskCancellationHandler {
        await race.wait()
    } onCancel: {
        tickTask.cancel()
        timeoutTask.cancel()
        Task { await race.resolve(.cancelled) }
    }

    switch result {
    case .finished(let outcome):
        timeoutTask.cancel()
        return outcome
    case .timedOut:
        tickTask.cancel()
        throw TickTimeoutError()
    case .cancelled:
        tickTask.cancel()
        timeoutTask.cancel()
        throw CancellationError()
    }
}

/// Compatibility wrapper for callers that only need deadline enforcement.
public func tickWithTimeout(_ loop: any LoopRunner, timeout: TimeInterval) async throws {
    _ = try await tickWithTimeoutOutcome(loop, timeout: timeout)
}

private enum TickRaceResult: Sendable {
    case finished(LoopTickOutcome)
    case timedOut
    case cancelled
}

private actor TickRace {
    private var result: TickRaceResult?
    private var waiters: [CheckedContinuation<TickRaceResult, Never>] = []

    func wait() async -> TickRaceResult {
        if let result { return result }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func resolve(_ next: TickRaceResult) {
        guard result == nil else { return }
        result = next
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: next)
        }
    }
}

private func timeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    let clamped = max(0, min(seconds, TimeInterval(UInt64.max) / 1_000_000_000))
    return UInt64(clamped * 1_000_000_000)
}

/// Snapshot of a registered loop's run state. All fields are last-write-wins
/// from the scheduler's per-tick update; consumers should treat as
/// point-in-time observations.
public struct LoopState: Sendable, Equatable {
    public var loopId: String
    public var lastTickAt: Date?
    public var nextTickAt: Date?
    public var lastResult: String?
    public var lastError: String?
    public var tickCount: Int

    public init(
        loopId: String,
        lastTickAt: Date? = nil,
        nextTickAt: Date? = nil,
        lastResult: String? = nil,
        lastError: String? = nil,
        tickCount: Int = 0
    ) {
        self.loopId = loopId
        self.lastTickAt = lastTickAt
        self.nextTickAt = nextTickAt
        self.lastResult = lastResult
        self.lastError = lastError
        self.tickCount = tickCount
    }
}

/// In-process scheduler that runs one Task per registered loop. start()
/// is idempotent at the per-loop level — calling start() twice will not
/// double-spawn a tick task for any single loop. stop() cancels every
/// outstanding task and clears them; loops remain registered and a fresh
/// start() will reactivate them.
public actor SwiftNativeLoopScheduler {
    /// A per-registration record. `registrationId` is the generation token
    /// used to detect "tick finished AFTER its loop was unregistered" — see
    /// `runOneTick`.
    private struct Registration {
        let loop: any LoopRunner
        let registrationId: UUID
    }
    private var loops: [String: Registration] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var states: [String: LoopState] = [:]
    private let clock: @Sendable () -> Date
    private let tickTimeout: TimeInterval
    private let failureReceiptsPath: URL?
    private let persistence = SwiftNativePersistenceCore()
    private var running: Bool = false

    // Failure backoff (audit 2026-08-02, HIGH): before this, the next tick was
    // scheduled `interval` out on the SUCCESS and the FAILURE path alike, so a
    // 2s loop kept hammering a dead endpoint every 2s for as long as the
    // outage lasted. The curve reuses the loop's existing consecutive-failure
    // streak (already reset on the first real success), so backoff and the
    // failure-streak push agree on what "still failing" means.
    private let defaultFailureBackoff: LoopFailureBackoffPolicy
    private let jitter: @Sendable (ClosedRange<Double>) -> Double
    /// Floor for any computed next-tick delay. Start-relative scheduling can
    /// produce a negative delay when a tick outruns its own interval (a 25s
    /// Telegram long poll on a 2s cadence); this keeps that from becoming a
    /// busy spin without stretching the cadence the way tick-END scheduling
    /// did.
    private let minimumTickSpacing: TimeInterval

    // LOOPS-4: the tick task used to sleep a FULL interval before its first
    // tick and the scheduler kept run history only in memory. A weekly loop
    // therefore never ran on a machine restarted more often than weekly — each
    // launch restarted the 7-day sleep from zero. Per-loop last-run is now
    // durable, and the FIRST sleep after launch is the REMAINDER of the period
    // (or a short startup stagger when the period already elapsed).
    private let loopStatePath: URL?
    private let startupStagger: TimeInterval
    private var persistedLastRun: [String: Date] = [:]
    private var persistedStateLoaded = false
    private var persistedStateLoad: Task<[String: Date], Never>?
    // A1/FIX-3 — durable-flush coalescing. See `recordDurableRun`.
    private let durableFlushWindow: TimeInterval
    private let durableFlushImmediateInterval: TimeInterval
    private var pendingDurableFlush: Task<Void, Never>?
    private var durableFlushCount = 0
    /// Slot counter used to fan overdue startup ticks out instead of firing
    /// every starved loop in the same instant. Reset on each `start()`.
    private var overdueStartupSlots = 0

    // A4.2: loop failures are receipt-strong but push-silent (the github_tracking
    // 633-receipts-unseen incident). Fire ONE push when a loop ENTERS a failure
    // streak — never per-failure (the streak check below suppresses the
    // steady-fail case; the cooldown bounds a flapping loop). App-injected so
    // Core gains no MacSyncEngine/APNS dependency; nil in tests / headless.
    // A4.8: push on the SECOND consecutive failure, not the first — a single
    // transient blip (upstream 502, brief network drop) that recovers on the
    // next tick must not page (the 03:17 double-page incident: one network
    // blip failed telegram_poll + github_tracking once each, two pushes).
    // Receipts still land on every failure regardless.
    private var failureTransitionPush: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    private var lastFailurePushAt: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var failureStreakStartedAt: [String: Date] = [:]
    private let failurePushCooldown: TimeInterval = 6 * 60 * 60
    private let failurePushConsecutiveThreshold = 2
    // A4.8 round 2 (User paged at 14:43 by a 6-second network blip): a
    // consecutive-failure COUNT is a duration proxy that breaks on
    // short-interval loops — slack retries every 2s, so "2 consecutive"
    // spanned 4 seconds. The streak must also SPAN this long before it can
    // knock. github (300s cadence) is unaffected: its 2-failure streak
    // already spans 5 minutes.
    private let failurePushMinStreakDuration: TimeInterval = 120

    /// `loopStatePath` holds the durable per-loop last-run map. When nil it is
    /// derived as a sibling of `failureReceiptsPath` — durable run state lives
    /// beside the durable failure receipts, so the process-wide scheduler
    /// (which already injects a receipts path) gets persistence automatically
    /// while a bare in-test scheduler stays entirely in memory.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        tickTimeout: TimeInterval = 300,
        failureReceiptsPath: URL? = nil,
        loopStatePath: URL? = nil,
        startupStagger: TimeInterval = 5,
        failureBackoff: LoopFailureBackoffPolicy = .default,
        minimumTickSpacing: TimeInterval = 0.25,
        durableFlushWindow: TimeInterval = 5,
        durableFlushImmediateInterval: TimeInterval = 60,
        jitter: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.durableFlushWindow = max(0, durableFlushWindow)
        self.durableFlushImmediateInterval = max(0, durableFlushImmediateInterval)
        self.clock = clock
        self.tickTimeout = tickTimeout
        self.failureReceiptsPath = failureReceiptsPath
        self.loopStatePath = loopStatePath ?? failureReceiptsPath?
            .deletingLastPathComponent()
            .appendingPathComponent("background_loop_state.json")
        self.startupStagger = max(0, startupStagger)
        self.defaultFailureBackoff = failureBackoff
        self.minimumTickSpacing = max(0, minimumTickSpacing)
        self.jitter = jitter
    }

    /// First-sleep rule after (re)start. Pure so it can be pinned directly.
    ///
    /// - no persisted last-run → sleep the full period (the loop's clock
    ///   starts now; the seed written at spawn makes the NEXT launch honor it)
    /// - period already elapsed → tick after `stagger` (bounded by the period)
    /// - otherwise → sleep only the remainder, clamped to the period so a
    ///   backwards clock jump cannot stretch the wait past one interval
    public static func firstTickDelay(
        interval: TimeInterval,
        lastRun: Date?,
        now: Date,
        stagger: TimeInterval
    ) -> TimeInterval {
        let period = max(0, interval)
        guard let lastRun else { return period }
        let remaining = period - now.timeIntervalSince(lastRun)
        guard remaining > 0 else { return min(max(0, stagger), period) }
        return min(remaining, period)
    }

    /// Inject the app-side failure-transition push. Called once at startup after
    /// the app assembles the notification lane. Setting nil (default) keeps the
    /// scheduler push-silent — receipts still land regardless.
    public func setFailureTransitionPush(
        _ push: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    ) {
        self.failureTransitionPush = push
    }

    public func register(_ loop: any LoopRunner) async {
        let id = loop.loopId
        // Load durable last-run BEFORE any spawn so the first sleep can be the
        // remainder of the period rather than a fresh full interval.
        await loadPersistedStateIfNeeded()
        // First time we have ever seen this loop: start its durable clock now.
        // Written synchronously (not fire-and-forget) so a process that exits
        // shortly after launch still leaves the stamp behind — otherwise a
        // weekly loop's clock resets on every restart, which is the starvation
        // bug itself.
        if persistedLastRun[id] == nil {
            await recordDurableRun(loopId: id, at: clock())
        }
        // If this loopId is already registered, cancel the old task before
        // installing the new registration. The old task's generation token
        // is stale; without cancelling it, spawnTaskIfNeeded() would refuse
        // to spawn a new task (tasks[id] != nil) and the new loop would
        // never run.
        if let previous = loops[id] {
            tasks.removeValue(forKey: id)?.cancel()
            await previous.loop.shutdown()
        }
        let reg = Registration(loop: loop, registrationId: UUID())
        loops[id] = reg
        if states[id] == nil {
            states[id] = LoopState(loopId: id)
        }
        if running {
            spawnTaskIfNeeded(for: reg)
        }
    }

    public func unregister(loopId: String) async {
        if let t = tasks.removeValue(forKey: loopId) {
            t.cancel()
        }
        let removed = loops.removeValue(forKey: loopId)
        await removed?.loop.shutdown()
        states.removeValue(forKey: loopId)
        // gpt-5.5 BLOCKING (A4.8 round 2): the transient streak state must
        // die with the registration — a replacement loop inheriting a stale
        // count + old streak stamp would page on its FIRST failure.
        // `lastFailurePushAt` deliberately survives: that's cooldown state,
        // and a reload must not reset the knock clock.
        consecutiveFailures.removeValue(forKey: loopId)
        failureStreakStartedAt.removeValue(forKey: loopId)
    }

    public func start() async {
        await loadPersistedStateIfNeeded()
        running = true
        overdueStartupSlots = 0
        for (_, reg) in loops {
            spawnTaskIfNeeded(for: reg)
        }
    }

    public func stop() async {
        running = false
        for (_, t) in tasks {
            t.cancel()
        }
        tasks.removeAll()
        for registration in loops.values {
            await registration.loop.shutdown()
        }
        // An orderly stop must not drop a coalesced durable stamp (A1/FIX-3).
        await flushPendingDurableState()
    }

    public func loopState(loopId: String) async -> LoopState? {
        states[loopId]
    }

    public func allLoopStates() async -> [LoopState] {
        Array(states.values).sorted { $0.loopId < $1.loopId }
    }

    /// Read-only eligibility projection for an opportunistic OS wake.
    ///
    /// The periodic scheduler and this projection consult the same durable
    /// per-loop last-run map. The caller must still enter the manager's shared
    /// execution gate after a `true` result: eligibility is deliberately not a
    /// second claim owner, and concurrent periodic/OS wakes are coalesced by
    /// that existing gate.
    public func isDue(loopId: String, at requestedNow: Date? = nil) async -> Bool? {
        await loadPersistedStateIfNeeded()
        guard let registration = loops[loopId] else { return nil }
        guard let lastRun = persistedLastRun[loopId] else { return true }
        let now = requestedNow ?? clock()
        return now.timeIntervalSince(lastRun) >= max(0, registration.loop.interval)
    }

    // MARK: internals

    private func spawnTaskIfNeeded(for reg: Registration) {
        let id = reg.loop.loopId
        if tasks[id] != nil { return }
        let interval = reg.loop.interval
        let capturedLoop = reg.loop
        let capturedRegId = reg.registrationId
        let now = clock()

        // A loop whose persisted period already elapsed gets a stagger slot so
        // N starved loops do not all fire in the same instant on launch.
        let persisted = persistedLastRun[id]
        let elapsed = persisted.map { now.timeIntervalSince($0) >= max(0, interval) } ?? false
        let stagger: TimeInterval
        if elapsed {
            overdueStartupSlots += 1
            stagger = startupStagger * Double(overdueStartupSlots)
        } else {
            stagger = startupStagger
        }
        let firstDelay = Self.firstTickDelay(
            interval: interval,
            lastRun: persisted,
            now: now,
            stagger: stagger
        )
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            var delay = firstDelay
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds(delay))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                let tickStartedAt = await self.currentClock()
                await self.runOneTick(loop: capturedLoop, registrationId: capturedRegId)
                // Cooperative cancellation check immediately after tick
                // returns — a tick that suspended a long time may have been
                // raced by stop(); exit the loop before sleeping again.
                if Task.isCancelled { return }
                // The next delay is computed on the actor because it depends on
                // the loop's live failure streak AND on when THIS tick started
                // (see nextDelay: `interval` measured from tick end is what
                // turned a 6h loop with a 25-minute tick into a 6h25m loop,
                // permanently, across restarts).
                delay = await self.nextDelay(for: capturedLoop, tickStartedAt: tickStartedAt)
            }
        }
        tasks[id] = task
        // Seed nextTickAt so consumers see a forward-looking time even
        // before the first tick lands. It must reflect the ACTUAL first
        // delay, or Doctor's overdue check would disagree with the scheduler.
        var st = states[id] ?? LoopState(loopId: id)
        st.nextTickAt = now.addingTimeInterval(firstDelay)
        states[id] = st
    }

    /// Actor-hopped read of the injected clock so the spawned tick task can
    /// stamp a tick's START without capturing the closure itself.
    private func currentClock() -> Date { clock() }

    /// Delay before the NEXT tick of `loop`.
    ///
    /// Two rules, both fixes for shipped drift/hammering bugs:
    ///
    /// * FAILING (`consecutiveFailures > 0`): back off exponentially with
    ///   jitter from the tick's END, floored at the loop's own interval and
    ///   capped by the policy. Reset happens implicitly — the streak is
    ///   cleared on the first real success/health-bearing skip, so the very
    ///   next delay returns to the normal cadence.
    /// * HEALTHY: the next tick is scheduled `interval` after the tick's
    ///   START, not after it returned. Tick-end scheduling made every loop's
    ///   effective period `interval + tickDuration` and that drift persisted
    ///   across restarts through the durable last-run stamp.
    ///
    /// Both branches are floored at `minimumTickSpacing` so a tick that
    /// outruns its own interval cannot become a busy spin.
    private func nextDelay(for loop: any LoopRunner, tickStartedAt: Date) -> TimeInterval {
        let id = loop.loopId
        let interval = max(0, loop.interval)
        let now = clock()
        let streak = consecutiveFailures[id] ?? 0
        let delay: TimeInterval
        if streak > 0 {
            let policy = loop.failureBackoffPolicy ?? defaultFailureBackoff
            let backoff = policy.delay(forConsecutiveFailures: streak, jitter: jitter)
            delay = max(minimumTickSpacing, max(interval, backoff))
        } else {
            let elapsed = max(0, now.timeIntervalSince(tickStartedAt))
            delay = max(minimumTickSpacing, interval - elapsed)
        }
        // Keep the advertised next-tick time honest: Doctor's overdue check
        // reads this, and after backoff/drift correction `now + interval` is
        // simply wrong.
        if var st = states[id] {
            st.nextTickAt = now.addingTimeInterval(delay)
            states[id] = st
        }
        return delay
    }

    /// Test seam: the delay the periodic task would sleep next.
    internal func _testNextDelay(loopId: String, tickStartedAt: Date) -> TimeInterval? {
        guard let reg = loops[loopId] else { return nil }
        return nextDelay(for: reg.loop, tickStartedAt: tickStartedAt)
    }

    // MARK: durable per-loop run state (LOOPS-4)

    /// Reads the durable map at most once. `register` and `start` both suspend
    /// here, so the in-flight read is memoized as a Task and later callers AWAIT
    /// it — a plain `loaded = true` flag would let a second concurrent
    /// `register` spawn against a still-empty map and sleep a full interval.
    private func loadPersistedStateIfNeeded() async {
        if persistedStateLoaded { return }
        let load: Task<[String: Date], Never>
        if let inFlight = persistedStateLoad {
            load = inFlight
        } else {
            let path = loopStatePath
            load = Task { await Self.readLoopState(path) }
            persistedStateLoad = load
        }
        let loaded = await load.value
        guard !persistedStateLoaded else { return }
        persistedStateLoaded = true
        persistedStateLoad = nil
        // Never clobber a stamp recorded while the read was in flight — that
        // one is newer than anything on disk.
        for (id, date) in loaded where persistedLastRun[id] == nil {
            persistedLastRun[id] = date
        }
    }

    /// L4-15: ids of loops that were deliberately DE-REGISTERED (assembly
    /// comments explain why for each) and must not haunt the durable state
    /// file forever. Entries normally outlive `unregister` on purpose (a
    /// hot-reload must not reset a weekly clock), so retirement needs this
    /// explicit tombstone: dropped at load, therefore absent from the next
    /// flush. If a listed loop is ever re-registered, REMOVE its id here or
    /// its due clock restarts from scratch on the next launch.
    /// NOT listed: `mission_executor` — that is a live wire id (kept through
    /// the de-mission rename fence), still registered by
    /// BackgroundLoopsAssembly+WorkshopExecution.
    static let retiredLoopIds: Set<String> = ["golden_eval", "stale_artifact_sweep"]

    /// A missing/corrupt file simply yields no persisted history, which
    /// degrades to the pre-LOOPS-4 behavior rather than blocking startup.
    private static func readLoopState(_ path: URL?) async -> [String: Date] {
        guard let path else { return [:] }
        let value = await SwiftNativePersistenceCore().readJSON(path, defaultValue: .object([:]))
        guard case .object(let root) = value,
              case .object(let loops)? = root["loops"]
        else { return [:] }
        let iso = ISO8601DateFormatter()
        var result: [String: Date] = [:]
        for (id, raw) in loops {
            guard !retiredLoopIds.contains(id) else { continue }
            guard case .string(let stamp) = raw, let date = iso.date(from: stamp) else { continue }
            result[id] = date
        }
        return result
    }

    /// Serializes the whole (small — one entry per loop id ever registered)
    /// map. Entries deliberately OUTLIVE `unregister`: a hot-reload via
    /// `restartLoop` must not reset a weekly loop's due clock back to zero.
    private func flushLoopState() async {
        guard let loopStatePath else { return }
        durableFlushCount += 1
        let iso = ISO8601DateFormatter()
        var loops: [String: JSONValue] = [:]
        for (id, date) in persistedLastRun {
            loops[id] = .string(iso.string(from: date))
        }
        do {
            try await persistence.writeJSON(
                .object(["version": .string("1"), "loops": .object(loops)]),
                to: loopStatePath
            )
        } catch {
            FileHandle.standardError.write(Data(
                "BackgroundLoops: failed to persist loop run state: \(error)\n".utf8
            ))
        }
    }

    /// A1/FIX-3: `flushLoopState` serializes ALL registered loops and does an
    /// atomic write+rename, and it used to run on EVERY durable record. The
    /// 2s telegram_poll loop alone therefore rewrote the whole file ~3,400
    /// times a day so that its own sub-minute due clock — which no restart
    /// path can meaningfully use — stayed byte-current.
    ///
    /// What the durable clock is FOR (LOOPS-4, and `firstTickDelay` above) is
    /// starvation detection across restarts: a loop whose period is long
    /// enough that a machine can be restarted more often than it ticks. That
    /// property is preserved exactly by flushing SYNCHRONOUSLY for every loop
    /// at or above `durableFlushImmediateInterval`, which is where all of it
    /// lives. It is also preserved for a loop we cannot classify (not
    /// registered — e.g. the first-ever `register` seed, or `recordFailure`
    /// for an unknown id): unknown always flushes immediately.
    ///
    /// Below that threshold the flush is coalesced onto a short trailing
    /// window, so a burst of short-interval records costs ONE write instead of
    /// N. The in-memory map is still updated on every record, so `nextDelay`,
    /// Doctor, and `_testPersistedLastRun` see the stamp immediately — only
    /// the disk write is coalesced. The worst-case loss is the last <window>
    /// seconds of a sub-minute loop's stamp on a hard kill, which shortens
    /// that loop's first sleep after relaunch by at most `window` and cannot
    /// hide a starvation (a sub-minute loop is due again within a minute).
    /// `stop()` drains any pending window, so an orderly quit loses nothing.
    private func recordDurableRun(loopId: String, at date: Date) async {
        persistedLastRun[loopId] = date
        let interval = loops[loopId]?.loop.interval
        guard let interval, interval < durableFlushImmediateInterval, durableFlushWindow > 0 else {
            await flushLoopState()
            return
        }
        scheduleCoalescedFlush()
    }

    /// Opens a trailing write window if one is not already open. Leading-edge
    /// records are absorbed by the window that is already in flight — that IS
    /// the coalescing.
    private func scheduleCoalescedFlush() {
        if pendingDurableFlush != nil { return }
        let window = durableFlushWindow
        pendingDurableFlush = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds(window))
            } catch {
                // Cancelled by stop(), which flushes synchronously itself.
                return
            }
            await self?.drainCoalescedFlush()
        }
    }

    /// Clears the window BEFORE writing, never after: a record that lands
    /// while the write is in flight must be able to open a fresh window, or
    /// its stamp would sit in memory with nothing scheduled to persist it.
    private func drainCoalescedFlush() async {
        pendingDurableFlush = nil
        await flushLoopState()
    }

    /// Drains a pending coalesced write. Called from `stop()`.
    private func flushPendingDurableState() async {
        guard let pending = pendingDurableFlush else { return }
        pending.cancel()
        pendingDurableFlush = nil
        await flushLoopState()
    }

    private func runOneTick(loop: any LoopRunner, registrationId: UUID) async {
        let id = loop.loopId
        let effectiveTimeout = loop.tickTimeoutOverride ?? tickTimeout
        do {
            let outcome = try await tickWithTimeoutOutcome(loop, timeout: effectiveTimeout)
            if Task.isCancelled { return }
            guard loops[id]?.registrationId == registrationId else { return }
            await record(outcome: outcome, loop: loop)
            return
        } catch is CancellationError {
            return
        } catch is TickTimeoutError {
            if Task.isCancelled { return }
            guard loops[id]?.registrationId == registrationId else { return }
            let now = clock()
            var st = states[id] ?? LoopState(loopId: id)
            st.lastTickAt = now
            st.nextTickAt = now.addingTimeInterval(loop.interval)
            st.lastError = "timeout after \(formatTimeout(effectiveTimeout))"
            st.lastResult = "failed"
            st.tickCount += 1
            states[id] = st
            // A TIMED-OUT tick did not complete its body, so — exactly like the
            // coalesced skip below — it must NOT advance the durable due clock.
            // It previously did, which meant a weekly loop that always times
            // out booked a fresh durable stamp every attempt and therefore
            // never read as overdue: the starvation was invisible to Doctor and
            // to the startup catch-up path (audit 2026-08-02).
            let err = st.lastError ?? "timeout"
            await appendFailureReceipt(loopId: id, error: err)
            await maybePushFailureStreak(loopId: id, error: err, now: now)
            return
        } catch {
            if Task.isCancelled { return }
            guard loops[id]?.registrationId == registrationId else { return }
            let now = clock()
            var st = states[id] ?? LoopState(loopId: id)
            st.lastTickAt = now
            st.nextTickAt = now.addingTimeInterval(loop.interval)
            st.lastError = String(describing: error)
            st.lastResult = "failed"
            st.tickCount += 1
            states[id] = st
            await recordDurableRun(loopId: id, at: now)
            let err = st.lastError ?? "unknown error"
            await appendFailureReceipt(loopId: id, error: err)
            await maybePushFailureStreak(loopId: id, error: err, now: now)
            return
        }
    }

    private func record(outcome: LoopTickOutcome, loop: any LoopRunner) async {
        let id = loop.loopId
        let now = clock()
        var st = states[id] ?? LoopState(loopId: id)
        st.lastTickAt = now
        st.nextTickAt = now.addingTimeInterval(loop.interval)
        st.tickCount += 1
        switch outcome {
        case .completed(let result):
            st.lastResult = result ?? "completed"
            st.lastError = nil
        case .skipped(let reason, _):
            st.lastResult = "skipped: \(reason)"
            // A HEALTH-NEUTRAL skip proves nothing about the loop's health, so
            // it must not erase the standing failure. Clearing `lastError` on a
            // `.backingOff` skip left `consecutiveFailures` nonzero while the
            // error slot read nil, and Doctor's no-error path then reported the
            // loop Healthy in the middle of its own failure-backoff window
            // (gpt-5.5 NEEDS_FIX, audit 2026-08-02). Only a skip that IS
            // evidence of health ("nothing due") clears it.
            if !outcome.isHealthNeutralSkip { st.lastError = nil }
        case .failed(let error):
            st.lastResult = "failed"
            st.lastError = error
        }
        states[id] = st
        // A health-neutral skip did not actually execute the loop body, so it
        // must not advance the durable due clock — otherwise overlapping wake
        // traffic (coalesce) or a loop sitting in its own backoff window
        // (.backingOff) would keep pushing a starved loop's next due time
        // forward and the starvation would be invisible to restart catch-up.
        if !outcome.isHealthNeutralSkip {
            await recordDurableRun(loopId: id, at: now)
        }
        switch outcome {
        case .failed(let error):
            await appendFailureReceipt(loopId: id, error: error)
            await maybePushFailureStreak(loopId: id, error: error, now: now)
        case .skipped where outcome.isHealthNeutralSkip:
            // Two shapes land here, neither of which is evidence of health:
            //   * the coalesced skip — a periodic tick that joined an active
            //     execution which may be failing right now (gpt-5.5 BLOCKING:
            //     resetting here could hold a genuinely failing loop below the
            //     push threshold under overlapping wake traffic);
            //   * a loop-declared health-neutral skip — "I am backing off
            //     BECAUSE I am failing" (TelegramPollLoop). Resetting on this
            //     one meant the streak was cleared between every real failure
            //     at the 0.25-2s tick cadence, so maybePushFailureStreak could
            //     never reach its threshold and a revoked token / offline Mac
            //     stayed silent forever (audit 2026-08-02, HIGH).
            break
        case .completed, .skipped:
            consecutiveFailures[id] = 0
            failureStreakStartedAt[id] = nil
        }
    }

    /// W1(b) upgrade campaign (L4-02): a closed lid is not a broken agent.
    /// 556 of 2,064 failure receipts over 32 days were literally "the
    /// internet is offline" — they polluted the durable receipt file, counted
    /// toward Doctor's persistent-failure threshold, and manufactured the
    /// ok→fail transitions that re-paged User about his own wifi. Definitely-
    /// offline errors mint no receipt, count no streak, fire no push.
    /// Deliberately EXCLUDES plain timeouts (-1001 / "timed out"): the
    /// github_tracking 120s-timeout defect (L4-03) surfaces as timeouts, and
    /// classifying those as offline would bury a real bug.
    static func isOfflineError(_ error: String) -> Bool {
        let e = error.lowercased()
        if e.contains("internet connection appears to be offline") { return true }
        if e.contains("network connection was lost") { return true }
        if e.contains("socket is not connected") { return true }
        if e.contains("telegram long poll: unavailable") { return true }
        if e.contains("nsurlerrordomain") {
            for code in ["-1009", "-1005", "-1003"]
            where e.contains("code=\(code)") || e.contains("code \(code)") {
                return true
            }
        }
        if e.contains("nsposixerrordomain"),
           e.contains("code=57") || e.contains("code=60")
            || e.contains("code 57") || e.contains("code 60") {
            return true
        }
        return false
    }

    /// L4-13: an error whose `localizedDescription` is empty ("The operation
    /// couldn't be completed" with no reason, or a custom Error with an empty
    /// message) produced receipts whose `error` field was blank — a failure row
    /// that says nothing. Loops should build strings via
    /// `Self.describeLoopError(_:)`; this guard is the backstop for any string
    /// that arrives empty anyway.
    static func describeLoopError(_ error: any Error) -> String {
        let described = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty { return described }
        let ns = error as NSError
        return "\(type(of: error)) (\(ns.domain) code \(ns.code))"
    }

    private func appendFailureReceipt(loopId: String, error: String) async {
        guard let failureReceiptsPath else { return }
        guard !Self.isOfflineError(error) else { return }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedError = trimmed.isEmpty
            ? "unspecified failure (empty error description)"
            : String(trimmed.prefix(2_000))
        let receipt: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("background_loop.failure"),
            "loopId": .string(loopId),
            "status": .string("failed"),
            "error": .string(boundedError),
            "createdAt": .string(ISO8601DateFormatter().string(from: clock())),
        ])
        do {
            try await appendJSONLCapped(
                receipt,
                to: failureReceiptsPath,
                using: persistence,
                maxLines: JSONLLineCaps.backgroundLoopFailures,
                logLabel: "BackgroundLoops.failures"
            )
        } catch {
            FileHandle.standardError.write(Data(
                "BackgroundLoops: failed to persist \(loopId) failure receipt: \(error)\n".utf8
            ))
        }
    }

    /// A4.2/A4.8: count this failure into the loop's consecutive-failure
    /// streak and fire the app-injected push once the streak has reached the
    /// threshold (2) AND the per-loop 6h cooldown has elapsed. A single
    /// transient blip that recovers on the next tick never pushes at all;
    /// past the threshold the cooldown is what paces the knocking, so a
    /// steady-failing loop pushes at most once per 6h for as long as it
    /// keeps failing (gpt-5.5 BLOCKING: gating on streak == threshold let a
    /// cooldown-suppressed streak stay push-silent for the rest of the
    /// outage). The counter resets on real success/non-coalesced skip.
    /// Receipts are unaffected — they always land.
    private func maybePushFailureStreak(
        loopId: String, error: String, now: Date
    ) async {
        // W1(b): offline blips neither count toward the streak nor push —
        // and they don't RESET it either, so a real outage bracketed by
        // wifi flaps keeps its accumulated evidence.
        guard !Self.isOfflineError(error) else { return }
        let streak = (consecutiveFailures[loopId] ?? 0) + 1
        consecutiveFailures[loopId] = streak
        if streak == 1 { failureStreakStartedAt[loopId] = now }
        guard let push = failureTransitionPush else { return }
        // Below threshold: could still be a self-healing blip.
        guard streak >= failurePushConsecutiveThreshold else { return }
        // Too brief: a short-interval loop can rack up "consecutive"
        // failures within one network hiccup (the 2026-07-24 14:43 page:
        // two slack failures 2s apart, recovered 4s later). Only a streak
        // that has PERSISTED for the minimum duration is a real outage.
        let streakStart = failureStreakStartedAt[loopId] ?? now
        guard now.timeIntervalSince(streakStart) >= failurePushMinStreakDuration else { return }
        // Cooldown gate: a recovered-then-failed flap can't knock more than once
        // per 6h per loop. The in-memory map is backed by a durable push stamp
        // in the failure-receipts feed so a relaunch can't reset the clock.
        var lastPush = lastFailurePushAt[loopId]
        if lastPush == nil {
            lastPush = await durableLastPushAt(loopId: loopId)
            if let lastPush { lastFailurePushAt[loopId] = lastPush }
        }
        if let lastPush, now.timeIntervalSince(lastPush) < failurePushCooldown {
            return
        }
        lastFailurePushAt[loopId] = now
        await recordPushStamp(loopId: loopId, at: now)
        await push(loopId, error)
    }

    /// Durable cooldown floor: the newest `failure_push` stamp for this loop in
    /// the capped failure-receipts feed. Consulted only when the in-memory map
    /// has no entry (fresh process); nil when no stamp or no feed.
    private func durableLastPushAt(loopId: String) async -> Date? {
        guard let failureReceiptsPath else { return nil }
        let persistence = SwiftNativePersistenceCore()
        let rows = (try? await persistence.readJSONL(failureReceiptsPath)) ?? []
        let iso = ISO8601DateFormatter()
        for row in rows.reversed() {
            guard case .object(let o) = row,
                  case .string("failure_push")? = o["kind"],
                  case .string(let id)? = o["loopId"], id == loopId,
                  case .string(let stamp)? = o["pushedAt"] else { continue }
            return iso.date(from: stamp)
        }
        return nil
    }

    private func recordPushStamp(loopId: String, at now: Date) async {
        guard let failureReceiptsPath else { return }
        let persistence = SwiftNativePersistenceCore()
        let row: JSONValue = .object([
            "kind": .string("failure_push"),
            "loopId": .string(loopId),
            "pushedAt": .string(ISO8601DateFormatter().string(from: now)),
        ])
        try? await appendJSONLCapped(
            row, to: failureReceiptsPath, using: persistence,
            maxLines: JSONLLineCaps.backgroundLoopFailures,
            logLabel: "BackgroundLoops.pushStamp"
        )
    }

    private nonisolated func formatTimeout(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return "\(seconds)s"
    }

    /// Test hook: return the underlying Task for a registered loop so a
    /// test can assert `isCancelled` AFTER `stop()` has removed it from
    /// the dict. Cancellation state lives on the Task itself and survives
    /// the dict eviction.
    internal func _testTaskHandle(loopId: String) -> Task<Void, Never>? {
        tasks[loopId]
    }

    /// Test hook: synchronously run one tick for the current registration.
    /// This exercises the same generation and state-update path as the
    /// background task without depending on wall-clock scheduler wakeups.
    internal func _testRunOneTick(loopId: String) async {
        guard let reg = loops[loopId] else { return }
        await runOneTick(loop: reg.loop, registrationId: reg.registrationId)
    }

    /// Test hook: record a tick failure into the loop's state. tick() itself
    /// is non-throwing by protocol contract, but DoctorAutoRunLoop and future
    /// loops may want to surface failures they catch internally. They do that
    /// by calling this from their tick body (via a SchedulerHandle pattern in
    /// a future iteration) — for Phase B we expose it on the actor so tests
    /// can verify the lastError slot wires correctly.
    ///
    /// `advanceDurableRun: false` records the failure WITHOUT booking a fresh
    /// durable last-run stamp. The out-of-band timeout path passes false so it
    /// agrees with the periodic path (`runOneTick`'s TickTimeoutError catch): a
    /// tick that never finished its body is not a run, and a weekly loop that
    /// always times out must keep reading as overdue across restarts instead of
    /// re-arming a week-long sleep every attempt (gpt-5.5 BLOCKING, 2026-08-02).
    public func recordFailure(
        loopId: String, error: String, advanceDurableRun: Bool = true
    ) async {
        var st = states[loopId] ?? LoopState(loopId: loopId)
        let now = clock()
        st.lastError = error
        st.lastTickAt = now
        st.tickCount += 1
        st.lastResult = "failed"
        states[loopId] = st
        if advanceDurableRun {
            await recordDurableRun(loopId: loopId, at: now)
        }
        await appendFailureReceipt(loopId: loopId, error: error)
        await maybePushFailureStreak(loopId: loopId, error: error, now: now)
    }

    public func recordResult(loopId: String, result: String) async {
        var st = states[loopId] ?? LoopState(loopId: loopId)
        let now = clock()
        st.lastResult = result
        st.lastError = nil
        // A manual/event-driven run is a real tick for LIVE health too, not
        // just the durable clock: without these stamps Doctor keeps reading
        // the old overdue nextTickAt until the periodic task happens to fire
        // (gpt-5.5 review MEDIUM). If the periodic task is scheduled sooner
        // than now+interval it will fire and re-stamp — a forward claim here
        // can only make Doctor less alarmist, never hide a missed tick.
        st.lastTickAt = now
        if let reg = loops[loopId] {
            st.nextTickAt = now.addingTimeInterval(reg.loop.interval)
        }
        states[loopId] = st
        // An out-of-band execution (manager.runTickOnce) is still a real run:
        // it must advance the durable due clock or a manual/event-driven tick
        // would leave the loop looking permanently overdue across restarts.
        await recordDurableRun(loopId: loopId, at: now)
        consecutiveFailures[loopId] = 0
        failureStreakStartedAt[loopId] = nil
    }

    /// Test seam: the loop's live consecutive-failure streak.
    internal func _testConsecutiveFailures(loopId: String) -> Int {
        consecutiveFailures[loopId] ?? 0
    }

    /// Test seam: the durable last-run stamp the scheduler would restart from.
    internal func _testPersistedLastRun(loopId: String) -> Date? {
        persistedLastRun[loopId]
    }

    /// Test seam: how many whole-file serialize + atomic-rename writes of the
    /// durable loop-state map have actually happened (A1/FIX-3).
    internal func _testDurableFlushCount() -> Int { durableFlushCount }

    /// Test seam: true while a coalesced durable write is still scheduled.
    internal func _testHasPendingDurableFlush() -> Bool { pendingDurableFlush != nil }
}

// MARK: - DoctorAutoRunLoop

import DoctorChecks

/// First real Swift loop: periodically calls DoctorChecksProtocol.runAll
/// (with repair=false, checkLLM=false — heavy probes stay opt-in) and
/// serializes the result to `<dataRoot>/doctor/latest.json` atomically via
/// SwiftNativePersistenceCore.writeJSON.
///
/// tick() remains non-throwing, but doctor or storage failure is a typed failed
/// outcome. A transient error may recover next tick; hiding it as success would
/// make the health owner lie about the body it is meant to inspect.
public struct DoctorAutoRunLoop: LoopRunner {
    public let loopId: String = "doctor_auto_run"
    public let interval: TimeInterval
    private let doctorChecks: any DoctorChecksProtocol
    private let storage: @Sendable () async throws -> URL

    /// `storage` returns the directory that will hold `latest.json`. Default
    /// resolves to `<defaultDataRoot()>/doctor`. The closure is async/throws
    /// so callers can plug in env-derived roots or mkdir-on-demand logic
    /// without forcing the work onto every callsite.
    public init(
        interval: TimeInterval = 600,
        doctorChecks: any DoctorChecksProtocol,
        storage: @escaping @Sendable () async throws -> URL = { defaultDoctorStorageDir() }
    ) {
        self.interval = interval
        self.doctorChecks = doctorChecks
        self.storage = storage
    }

    public func tickOutcome() async -> LoopTickOutcome {
        do {
            let results = try await doctorChecks.runAll(repair: false, checkLLM: false)
            let dir = try await storage()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("latest.json")
            let payload = try encodePayload(results: results)
            try await SwiftNativePersistenceCore().writeJSON(payload, to: target)
            return .completed(result: "doctor snapshot persisted")
        } catch {
            FileHandle.standardError.write(Data("DoctorAutoRunLoop: tick failed: \(error)\n".utf8))
            return .failed(error: String(describing: error))
        }
    }

    private func encodePayload(results: [CheckResult]) throws -> JSONValue {
        // Mirror the daemon's `{"checks": [...]}` wire shape so consumers
        // reading `latest.json` can use the same parser as the live HTTP
        // route. Use JSONEncoder → JSONValue.parse round-trip so encoding
        // matches CheckResult's Codable representation byte-for-byte.
        // `runAt` is added so the Mac health card can decide whether the
        // cached doctor run is fresh enough to reuse vs. re-run live.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(results)
        let checksValue = try JSONValue.parse(data)
        let runAt = ISO8601DateFormatter().string(from: Date())
        return .object(["checks": checksValue, "runAt": .string(runAt)])
    }
}

/// Default storage directory for DoctorAutoRunLoop's latest.json output.
/// Exposed at file scope so tests can compute the expected path.
public func defaultDoctorStorageDir() -> URL {
    defaultDataRoot().appendingPathComponent("doctor", isDirectory: true)
}
