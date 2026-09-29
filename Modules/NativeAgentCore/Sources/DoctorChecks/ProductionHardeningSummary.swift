import Foundation

public struct ProductionHardeningSummary: Codable, Hashable {
    public var status: String
    public var release: ReleaseChecklist?
    public var doctorStatus: String?
    public var createdAt: String?
    /// Missing is distinct from a report that could not be read. The latter
    /// remains visible to the hardening panel instead of becoming a neutral
    /// synthetic state.
    public var detail: String? = nil
    public init(status: String, release: ReleaseChecklist? = nil, doctorStatus: String? = nil, createdAt: String? = nil, detail: String? = nil) {
        self.status = status
        self.release = release
        self.doctorStatus = doctorStatus
        self.createdAt = createdAt
        self.detail = detail
    }
}
