// Blueprint: | `WorkshopTaskRecord.swift` | WorkshopTaskRecord: shared task wire row with compatible field decoding; the Mac supplies approval authority |

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

    private enum HistoricalKeys: String, CodingKey {
        case desk_handle, project_space_id, last_movement_at
        case autonomy_level, permission_profile, receipt_count
        case created_at, updated_at, completed_at, current_step_id
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let historical = try decoder.container(keyedBy: HistoricalKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deskHandle = try c.decodeIfPresent(String.self, forKey: .deskHandle) ?? historical.decodeIfPresent(String.self, forKey: .desk_handle)
        projectSpaceId = try c.decodeIfPresent(String.self, forKey: .projectSpaceId) ?? historical.decodeIfPresent(String.self, forKey: .project_space_id)
        lastMovementAt = try c.decodeIfPresent(String.self, forKey: .lastMovementAt) ?? historical.decodeIfPresent(String.self, forKey: .last_movement_at)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        objective = try c.decodeIfPresent(String.self, forKey: .objective) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? status
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        autonomyLevel = try c.decodeIfPresent(String.self, forKey: .autonomyLevel)
            ?? historical.decodeIfPresent(String.self, forKey: .autonomy_level)
        permissionProfile = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
            ?? historical.decodeIfPresent(String.self, forKey: .permission_profile)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? historical.decodeIfPresent(String.self, forKey: .created_at)
            ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? historical.decodeIfPresent(String.self, forKey: .updated_at)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
            ?? historical.decodeIfPresent(String.self, forKey: .completed_at)
        receiptCount = try c.decodeIfPresent(Int.self, forKey: .receiptCount)
            ?? historical.decodeIfPresent(Int.self, forKey: .receipt_count)
        currentStepId = try c.decodeIfPresent(String.self, forKey: .currentStepId)
            ?? historical.decodeIfPresent(String.self, forKey: .current_step_id)
        requiresApproval = try c.decodeIfPresent(Bool.self, forKey: .requiresApproval)
    }
}
