import Foundation

// Blueprint: | `ActivitySpan.swift` | `ActivitySpan` and `ActivityCloseReason`: persisted activity intervals, redacted titles and close vocabulary |

/// Lost required observation closes at the last known instant, without inventing an app quit or later duration.
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

/// Only `titleRedacted` may carry user-authored text, and only from `ActivityTitleRedaction.redact`.
/// Never store AXValue for any element role.
public struct ActivitySpan: Sendable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Double
    public let endedAt: Double?
    public let lastSeenAt: Double
    public let bundleId: String
    public let appName: String
    /// The field name makes source redaction explicit so callers cannot assign a raw title by mistake.
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

    /// Measure open spans to their last heartbeat; unobserved time must not grow the row.
    public var duration: Double { max(0, (endedAt ?? lastSeenAt) - startedAt) }

    /// The start offset is provenance; query-time buckets use the asking timezone.
    public static func tzOffsetMinutes(at date: Date) -> Int {
        TimeZone.autoupdatingCurrent.secondsFromGMT(for: date) / 60
    }
}
