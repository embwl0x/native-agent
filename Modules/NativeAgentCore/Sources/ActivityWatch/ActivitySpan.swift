import Foundation

/// Why an activity span stopped.
///
/// v0 keeps the full v1 vocabulary (docs/build_plans/ambient-activity-watcher.md
/// W3) even though `windowChange` is unreachable while titles are not captured —
/// the enum is the persisted wire vocabulary and churning it later is worse than
/// carrying one dormant case.
public enum ActivityCloseReason: String, Sendable, Codable, CaseIterable {
    case appChange
    case windowChange
    case idle
    case lock
    case sleep
    case quit
    case abandoned
}

/// One contiguous stretch of time the machine's frontmost app + window title
/// did not change.
///
/// METADATA ONLY. There is exactly one text field carrying anything the human
/// wrote — `titleRedacted` — and it can only ever hold the output of
/// `ActivityTitleRedaction.redact`. No `AXValue` is stored here for any element
/// role, ever; that rule is categorical, not role-conditional.
public struct ActivitySpan: Sendable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Double
    public let endedAt: Double?
    public let lastSeenAt: Double
    public let bundleId: String
    public let appName: String
    /// W5: the frontmost window's title AFTER redaction, or nil when titles are
    /// not captured for this app (the default). The name carries the invariant
    /// on purpose — a field called `title` would eventually be assigned a raw
    /// one by someone reading only the call site.
    public let titleRedacted: String?
    public let eventCount: Int
    public let closeReason: ActivityCloseReason?
    public let tzOffsetMin: Int

    public init(
        id: String = UUID().uuidString,
        startedAt: Double,
        endedAt: Double? = nil,
        lastSeenAt: Double,
        bundleId: String,
        appName: String,
        titleRedacted: String? = nil,
        eventCount: Int = 0,
        closeReason: ActivityCloseReason? = nil,
        tzOffsetMin: Int = ActivitySpan.currentTZOffsetMinutes()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastSeenAt = lastSeenAt
        self.bundleId = bundleId
        self.appName = appName
        self.titleRedacted = titleRedacted
        self.eventCount = eventCount
        self.closeReason = closeReason
        self.tzOffsetMin = tzOffsetMin
    }

    public var isOpen: Bool { endedAt == nil }

    /// Wall duration. An open span is measured to its last heartbeat, never to
    /// "now" — an open row must not grow while nothing is being observed.
    public var duration: Double { max(0, (endedAt ?? lastSeenAt) - startedAt) }

    /// UTC offset in minutes in force *at write time* (W4 timezone correctness:
    /// buckets are computed at read time in the asking timezone, so the row only
    /// has to remember the offset it was written under).
    public static func currentTZOffsetMinutes(_ date: Date = Date()) -> Int {
        TimeZone.current.secondsFromGMT(for: date) / 60
    }
}

/// Aggregate answer for a window. `eventsPerHour` is v0's entire reason to
/// exist — open item #2 in the build plan is an *estimated* event rate, and this
/// number is what retires it.
public struct ActivityStats: Sendable, Equatable {
    public let from: Double
    public let to: Double
    public let totalSpans: Int
    public let totalEvents: Int
    public let distinctApps: Int
    /// Summed OBSERVED span time inside the window, clamped to it (0 when
    /// empty). Deliberately NOT first-start-to-last-end: lock, sleep and idle
    /// gaps between spans are excluded, so `eventsPerHour` reads as "AX
    /// callbacks per hour of ACTIVE use".
    public let wallClockSeconds: Double
    public let eventsPerHour: Double

    public init(
        from: Double,
        to: Double,
        totalSpans: Int,
        totalEvents: Int,
        distinctApps: Int,
        wallClockSeconds: Double
    ) {
        self.from = from
        self.to = to
        self.totalSpans = totalSpans
        self.totalEvents = totalEvents
        self.distinctApps = distinctApps
        self.wallClockSeconds = wallClockSeconds
        self.eventsPerHour = wallClockSeconds > 0
            ? Double(totalEvents) / (wallClockSeconds / 3600.0)
            : 0
    }
}
