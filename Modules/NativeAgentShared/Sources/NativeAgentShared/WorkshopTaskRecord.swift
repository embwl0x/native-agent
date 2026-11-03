// Blueprint: | `WorkshopTaskRecord.swift` | WorkshopTaskRecord: checked canonical task wire row; the Mac supplies approval authority |

import Foundation

public struct WorkshopTaskRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var deskHandle: String?
    public var projectSpaceId: String?
    public var lastMovementAt: String?
    public var title: String
    public var objective: String
    public var status: String
    public var phase: String
    public var priority: String?
    public var autonomyLevel: String?
    public var permissionProfile: String?
    public var summary: String?
    public var createdAt: String
    public var updatedAt: String?
    public var completedAt: String?
    public var receiptCount: Int?
    public var currentStepId: String?
    public var requiresApproval: Bool?

    enum CodingKeys: String, CodingKey {
        case deskHandle, projectSpaceId, lastMovementAt
        case id, title, objective, status, phase, priority
        case autonomyLevel, permissionProfile, summary
        case createdAt, updatedAt, completedAt, receiptCount, currentStepId, requiresApproval
    }

    public init(
        id: String,
        title: String,
        objective: String,
        status: String,
        phase: String,
        priority: String? = nil,
        autonomyLevel: String? = nil,
        permissionProfile: String? = nil,
        summary: String? = nil,
        createdAt: String,
        updatedAt: String? = nil,
        completedAt: String? = nil,
        receiptCount: Int? = nil,
        currentStepId: String? = nil,
        deskHandle: String? = nil, projectSpaceId: String? = nil, lastMovementAt: String? = nil,
        requiresApproval: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.status = status
        self.phase = phase
        self.priority = priority
        self.autonomyLevel = autonomyLevel
        self.permissionProfile = permissionProfile
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.receiptCount = receiptCount
        self.currentStepId = currentStepId
        self.deskHandle = deskHandle; self.projectSpaceId = projectSpaceId
        self.lastMovementAt = lastMovementAt; self.requiresApproval = requiresApproval
    }

}
