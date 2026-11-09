import Foundation
// Blueprint: | `ProductionHardeningSummary.swift` | `ProductionHardeningSummary` struct |

public struct ProductionHardeningSummary: Codable, Hashable, Sendable {
    public var status: String
    public var release: ReleaseChecklist?
    public var doctorStatus: String?
    public var createdAt: String?
    /// Missing is neutral; unreadable reports must remain visible as unavailable rather than synthetic health.
    public var detail: String? = nil
    public init(status: String, release: ReleaseChecklist? = nil, doctorStatus: String? = nil, createdAt: String? = nil, detail: String? = nil) {
        self.status = status
        self.release = release
        self.doctorStatus = doctorStatus
        self.createdAt = createdAt
        self.detail = detail
    }
}
