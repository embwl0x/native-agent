import Foundation

// Blueprint: | `ActivitySpan.swift` | `ActivitySpan` and `ActivityCloseReason`: persisted activity intervals, redacted titles and close vocabulary |

/// Why an activity span stopped.
///
/// `ActivitySpanEngine` emits `windowChange` for a changed, successfully read
/// opt-in title or a policy change that removes a captured title. The initial
/// title settles in place. Lost required AX observation ends at the last known
/// observation with `observationUnavailable`, without inventing an app quit.
public enum ActivityCloseReason: String, Sendable, Codable, CaseIterable {
    case appChange
    case windowChange
    case idle
    case lock
    case sleep
    case quit
    case abandoned
    case observationUnavailable
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
        tzOffsetMin: Int
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

    /// UTC offset in minutes at the new span's `startedAt` (W4 timezone correctness:
    /// buckets are computed at read time in the asking timezone, so the row only
    /// has to remember the offset at its start).
    public static func tzOffsetMinutes(at date: Date) -> Int {
        TimeZone.autoupdatingCurrent.secondsFromGMT(for: date) / 60
    }
}
