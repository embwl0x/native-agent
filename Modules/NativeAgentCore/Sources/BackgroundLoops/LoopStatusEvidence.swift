import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LoopStatusEvidence.swift` | WatchdogStatus wire encoding, scheduler LoopState, LoopStatus and event-listener health evidence |

/// Watchdog wire keys remain stable for persisted and surface-facing compatibility.
public struct WatchdogStatus: Sendable, Encodable, Equatable {
    public var uptimeSeconds: Double
    public var runtimeLifecycleStatus: String
    public var runtimeLifecycleDetail: String
    public var runningImprovements: Int
    public var runningExecutions: Int
    public var lastActivity: JSONValue?
    public var repairAvailable: Bool
    public var extras: JSONValue?

    public init(
        uptimeSeconds: Double,
        runtimeLifecycleStatus: String,
        runtimeLifecycleDetail: String,
        runningImprovements: Int,
        runningExecutions: Int,
        lastActivity: JSONValue? = nil,
        repairAvailable: Bool,
        extras: JSONValue? = nil
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.runtimeLifecycleStatus = runtimeLifecycleStatus
        self.runtimeLifecycleDetail = runtimeLifecycleDetail
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

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode("swift", forKey: JSONKey("daemon"))
        try c.encode(uptimeSeconds, forKey: JSONKey("uptimeSeconds"))
        try c.encode(runtimeLifecycleStatus, forKey: JSONKey("daemonLifecycleStatus"))
        try c.encode(runtimeLifecycleDetail, forKey: JSONKey("daemonLifecycleDetail"))
        try c.encode("not_applicable", forKey: JSONKey("launchAgentStatus"))
        try c.encode("NativeAgent.app owns background loops; legacy daemon launch agents are retired.", forKey: JSONKey("launchAgentDetail"))
        try c.encode(runningImprovements, forKey: JSONKey("runningImprovements"))
        try c.encode(runningExecutions, forKey: JSONKey("runningMissions"))
        try c.encodeIfPresent(lastActivity, forKey: JSONKey("lastActivity"))
        try c.encode(repairAvailable, forKey: JSONKey("repairAvailable"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

/// Snapshot of settled outcomes and projected timing.
public struct LoopState: Sendable, Equatable {
    public var loopId: String
    public var lastTickAt: Date?
    /// Periodic projection, also advanced by event/out-of-band accounting; not the retained sleeper.
    public var nextTickAt: Date?
    public var lastResult: String?
    public var lastError: String?
    public var tickCount: Int

    /// Durable last real completion; failures and skips advance only lastTickAt.
    public var lastCompletedAt: Date?

    /// Durable first registration, the dormancy floor until real work completes.
    public var firstSeenAt: Date?

    public init(
        loopId: String,
        lastTickAt: Date? = nil,
        nextTickAt: Date? = nil,
        lastResult: String? = nil,
        lastError: String? = nil,
        tickCount: Int = 0,
        lastCompletedAt: Date? = nil,
        firstSeenAt: Date? = nil
    ) {
        self.loopId = loopId
        self.lastTickAt = lastTickAt
        self.nextTickAt = nextTickAt
        self.lastResult = lastResult
        self.lastError = lastError
        self.tickCount = tickCount
        self.lastCompletedAt = lastCompletedAt
        self.firstSeenAt = firstSeenAt
    }
}

/// Listener health distinguishes loops without listeners from stopped streams.
public struct LoopEventListenerHealth: Sendable, Equatable {
    /// A listener task is currently consuming the stream.
    public var active: Bool
    /// When the stream last ended on its own (nil = it never has).
    public var lastEndedAt: Date?
    /// How many times this loop's listener has been restarted since
    /// registration. Monotonic; a healthy loop stays at 0.
    public var restartCount: Int
    /// Ends since the last event actually arrived. Reset by a delivered event,
    /// which is the only proof the replacement listener is really working — a
    /// stream that ends immediately on every restart keeps climbing.
    public var consecutiveEnds: Int
    /// Human-readable last termination, carried into Doctor.
    public var lastError: String?

    public init(
        active: Bool = true,
        lastEndedAt: Date? = nil,
        restartCount: Int = 0,
        consecutiveEnds: Int = 0,
        lastError: String? = nil
    ) {
        self.active = active
        self.lastEndedAt = lastEndedAt
        self.restartCount = restartCount
        self.consecutiveEnds = consecutiveEnds
        self.lastError = lastError
    }
}

public struct LoopStatus: Sendable, Equatable {
    public let name: String
    public let interval: TimeInterval
    public let lastRun: Date?
    public let nextRun: Date?
    public let runCount: Int
    public let lastError: String?
    public let running: Bool
    public let disabledReason: String?
    /// A loop body is executing right now. This differs from `running`, which
    /// only means the manager owns an active scheduler registration.
    public let executing: Bool
    public let executionStartedAt: Date?
    /// Watchdog budget for the active tick.
    public let executionTimeout: TimeInterval
    /// nil for loops that are not event-driven at all.
    public let eventListener: LoopEventListenerHealth?

    /// Most recent outcome text, including the reason a loop skipped work.
    public let lastResult: String?

    /// Durable last real completion; failures and skips advance only lastRun.
    public let lastSuccessfulWorkAt: Date?
    /// When this loop was first registered on this machine (durable). Dormancy
    /// is measured from max(firstSeen, lastSuccessfulWork).
    public let firstSeenAt: Date?

    public init(
        name: String,
        interval: TimeInterval = 300,
        lastRun: Date?,
        nextRun: Date?,
        runCount: Int,
        lastError: String?,
        running: Bool = false,
        disabledReason: String? = nil,
        executing: Bool = false,
        executionStartedAt: Date? = nil,
        executionTimeout: TimeInterval = 300,
        eventListener: LoopEventListenerHealth? = nil,
        lastResult: String? = nil,
        lastSuccessfulWorkAt: Date? = nil,
        firstSeenAt: Date? = nil
    ) {
        self.name = name
        self.interval = interval
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.runCount = runCount
        self.lastError = lastError
        self.running = running
        self.disabledReason = disabledReason
        self.executing = executing
        self.executionStartedAt = executionStartedAt
        self.executionTimeout = executionTimeout
        self.eventListener = eventListener
        self.lastResult = lastResult
        self.lastSuccessfulWorkAt = lastSuccessfulWorkAt
        self.firstSeenAt = firstSeenAt
    }
}
