import Foundation
// Blueprint: | `DoctorHealthCard.swift` | `HealthCardSubsystem` struct |

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

    public init(_ reading: CheckResult) {
        self.init(id: reading.id, label: reading.title, status: reading.status,
                  detail: reading.repairFace, fixAction: reading.repairCall ?? reading.repairTap)
    }

}

public struct HealthCard: Codable, Hashable, Sendable {
    public var overall: String  // "ok" | "warn" | "error"
    public var subsystems: [HealthCardSubsystem]
    public var createdAt: String?  // Older cached cards may omit the timestamp.
    public init(overall: String, subsystems: [HealthCardSubsystem], createdAt: String? = nil) {
        self.overall = overall
        self.subsystems = subsystems
        self.createdAt = createdAt
    }

}
