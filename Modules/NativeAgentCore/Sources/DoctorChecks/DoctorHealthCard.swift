import Foundation

public struct HealthCardSubsystem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var status: String  // "ok" | "warn" | "error"
    public var detail: String
    public var fixAction: String?
    public init(id: String, label: String, status: String, detail: String, fixAction: String? = nil) {
        self.id = id
        self.label = label
        self.status = status
        self.detail = detail
        self.fixAction = fixAction
    }

}

public struct HealthCard: Codable, Hashable, Sendable {
    public var overall: String  // "ok" | "warn" | "error"
    public var subsystems: [HealthCardSubsystem]
    public var createdAt: String?  // Fix 9: optional — older daemon responses may omit this
    public init(overall: String, subsystems: [HealthCardSubsystem], createdAt: String? = nil) {
        self.overall = overall
        self.subsystems = subsystems
        self.createdAt = createdAt
    }

}
