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

// Share display formatting across surfaces.

public typealias UserDisplayFormatters = NativeAgentShared.UserDisplayFormatters

extension String {
    /// Truncate only beyond `limit`; `keeping` lets callers reserve suffix space without changing the trigger threshold.
    public func truncated(to limit: Int, keeping: Int? = nil, suffix: String = "…") -> String {
        guard count > limit else { return self }
        return String(prefix(keeping ?? limit)) + suffix
    }
}
