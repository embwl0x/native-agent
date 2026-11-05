import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LoopStatusEvidence.swift` | WatchdogStatus wire encoding, scheduler LoopState, LoopStatus and event-listener health evidence |

public struct WatchdogStatus: Sendable, Encodable, Equatable {
    public var uptimeSeconds: Double
    public var runtimeLifecycleStatus: String
    public var runtimeLifecycleDetail: String
    public var runningImprovements: Int
    public var lastActivity: JSONValue?
    public var repairAvailable: Bool
    public var extras: JSONValue?

    public init(
        uptimeSeconds: Double,
        runtimeLifecycleStatus: String,
        runtimeLifecycleDetail: String,
        runningImprovements: Int,
        lastActivity: JSONValue? = nil,
        repairAvailable: Bool,
        extras: JSONValue? = nil
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.runtimeLifecycleStatus = runtimeLifecycleStatus
        self.runtimeLifecycleDetail = runtimeLifecycleDetail
        self.runningImprovements = runningImprovements
        self.lastActivity = lastActivity
        self.repairAvailable = repairAvailable
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "uptimeSeconds",
        "runtimeLifecycleStatus", "runtimeLifecycleDetail",
        "runningImprovements",
        "lastActivity",
        "repairAvailable",
        "extras",
    ]

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode(uptimeSeconds, forKey: JSONKey("uptimeSeconds"))
        try c.encode(runtimeLifecycleStatus, forKey: JSONKey("runtimeLifecycleStatus"))
        try c.encode(runtimeLifecycleDetail, forKey: JSONKey("runtimeLifecycleDetail"))
        try c.encode(runningImprovements, forKey: JSONKey("runningImprovements"))
        try c.encodeIfPresent(lastActivity, forKey: JSONKey("lastActivity"))
        try c.encode(repairAvailable, forKey: JSONKey("repairAvailable"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

public struct LoopState: Sendable, Equatable {
    public var loopId: String
    public var lastTickAt: Date?
    /// Rhythms project their next tick; change-woken organs have no periodic tick.
    public var nextTickAt: Date?
    public var lastResult: String?
    public var lastError: String?
    public var tickCount: Int

    /// Failures and skips advance attempts, never the durable real-completion stamp.
    public var lastCompletedAt: Date?

    /// Use first registration as the dormancy floor until real work completes.
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
    public var active: Bool
    /// Nil means no unexpected stream end has been observed.
    public var lastEndedAt: Date?
    /// Keep restart count monotonic across the registration so repeated listener failures remain visible.
    public var restartCount: Int
    /// Reset consecutive ends only on delivered input, the sole proof that a replacement listener works.
    public var consecutiveEnds: Int
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
    /// Nil means the registration is disabled or unreadable, never a guessed rhythm.
    public let wake: OrganWake?
    public let lastRun: Date?
    public let nextRun: Date?
    public let runCount: Int
    public let lastError: String?
    public let running: Bool
    public let disabledReason: String?
    /// Running registration does not prove body execution; expose the actual execution gate separately.
    public let executing: Bool
    public let executionStartedAt: Date?
    public let executionTimeout: TimeInterval
    /// Nil distinguishes non-event-driven loops from broken listeners.
    public let eventListener: LoopEventListenerHealth?

    public let lastResult: String?

    /// Failures and skips cannot advance the durable real-completion stamp.
    public let lastSuccessfulWorkAt: Date?
    /// Measure dormancy from the later durable first registration or real completion, never skipped work.
    public let firstSeenAt: Date?

    public init(
        name: String,
        wake: OrganWake?,
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
        self.wake = wake
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
