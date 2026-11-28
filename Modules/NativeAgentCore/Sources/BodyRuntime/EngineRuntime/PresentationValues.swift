import Foundation
import NativeAgentShared
import DeskCore
// Blueprint: | `PresentationValues.swift` | Shared health and capability presentation values and display-string truncation |

public struct CapabilityCounts: Codable, Hashable, Sendable {
    public var total: Int
    public var active: Int
    public init(total: Int, active: Int) {
        self.total = total
        self.active = active
    }

}

public struct CapabilitySummaryResponse: Codable, Hashable, Sendable {
    public var records: [CapabilityRecord]
    public var summary: CapabilityCounts
    public init(records: [CapabilityRecord], summary: CapabilityCounts) {
        self.records = records
        self.summary = summary
    }

}

extension String {
    /// Truncate only beyond `limit`.
    public func truncated(to limit: Int, suffix: String = "…") -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + suffix
    }
}
