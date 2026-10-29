import AppToolRuntime
import DoctorChecks
import Foundation
import NativeAgentShared
import TrustCenter
// Blueprint: | `PresentationValues.swift` | Shared health and capability presentation values, shared formatter alias and display-string truncation |

public typealias HealthCardSubsystem = DoctorChecks.HealthCardSubsystem

public typealias HealthCard = DoctorChecks.HealthCard

public struct CapabilityCounts: Codable, Hashable, Sendable {
    public var total: Int
    public var active: Int
    public var review: Int
    public var autoloaded: Int
    public var byKind: [String: Int]?
    public init(total: Int, active: Int, review: Int, autoloaded: Int, byKind: [String: Int]? = nil) {
        self.total = total
        self.active = active
        self.review = review
        self.autoloaded = autoloaded
        self.byKind = byKind
    }

}

public struct CapabilitySummaryResponse: Codable, Hashable, Sendable {
    public var records: [CapabilityRecord]
    public var summary: CapabilityCounts
    public var createdAt: String?
    public init(records: [CapabilityRecord], summary: CapabilityCounts, createdAt: String? = nil) {
        self.records = records
        self.summary = summary
        self.createdAt = createdAt
    }

}

// Shared display values keep formatting consistent across surfaces.

public typealias UserDisplayFormatters = NativeAgentShared.UserDisplayFormatters

extension String {
    /// Truncate a display string, appending `suffix` when (and only when) the
    /// string is longer than `limit` — a string of exactly `limit` chars is
    /// returned whole. Some call sites cap the *trigger* threshold and the
    /// *retained* prefix independently (e.g. "trip at >80 but keep 77"); pass
    /// `keeping` for those, otherwise the retained prefix uses `limit`.
    public func truncated(to limit: Int, keeping: Int? = nil, suffix: String = "…") -> String {
        guard count > limit else { return self }
        return String(prefix(keeping ?? limit)) + suffix
    }
}
