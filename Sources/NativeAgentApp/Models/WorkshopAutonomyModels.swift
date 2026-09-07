import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct WorkshopExecutionRecord: Identifiable, Codable, Hashable {
    var id: String
    var deskHandle: String?
    var projectSpaceId: String?
    var title: String
    var objective: String
    var status: String
    var phase: String
    var priority: String?
    var autonomyLevel: String?
    var permissionProfile: String?
    var summary: String?
    var createdAt: String
    var updatedAt: String?
    var completedAt: String?
    var receiptCount: Int?

    // PATCH-2026-05-07: execution-decode-tolerance The daemon has two execution
    // stores: the new queue (snake_case `created_at` / `updated_at`, no
    // `phase` field) and the legacy store (camelCase). Both flow through
    // GET /v1/missions. This custom decoder accepts either casing and
    // gives queue executions a sensible default phase, so the dashboard
    // doesn't silently go empty after a queue submission.
    enum CodingKeys: String, CodingKey {
        case id, title, objective, status, phase, priority, deskHandle, projectSpaceId
        case autonomyLevel, permissionProfile, summary
        case createdAt, updatedAt, completedAt, receiptCount
        // snake_case fallbacks
        case created_at, updated_at, completed_at, desk_handle, project_space_id
        case autonomy_level, permission_profile, receipt_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(String.self, forKey: .id)
        self.deskHandle = try c.decodeIfPresent(String.self, forKey: .deskHandle)
                        ?? c.decodeIfPresent(String.self, forKey: .desk_handle)
        self.projectSpaceId = try c.decodeIfPresent(String.self, forKey: .projectSpaceId)
                           ?? c.decodeIfPresent(String.self, forKey: .project_space_id)
        self.title     = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.objective = try c.decodeIfPresent(String.self, forKey: .objective) ?? ""
        self.status    = try c.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        // Queue Workshop executions have no phase; default to status-derived value.
        if let p = try c.decodeIfPresent(String.self, forKey: .phase) {
            self.phase = p
        } else {
            self.phase = self.status   // queue items repeat status as phase
        }
        self.priority           = try c.decodeIfPresent(String.self, forKey: .priority)
        self.autonomyLevel      = try c.decodeIfPresent(String.self, forKey: .autonomyLevel)
                                ?? c.decodeIfPresent(String.self, forKey: .autonomy_level)
        self.permissionProfile  = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
                                ?? c.decodeIfPresent(String.self, forKey: .permission_profile)
        self.summary            = try c.decodeIfPresent(String.self, forKey: .summary)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
                       ?? c.decodeIfPresent(String.self, forKey: .created_at)
                       ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
                       ?? c.decodeIfPresent(String.self, forKey: .updated_at)
        self.completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
                         ?? c.decodeIfPresent(String.self, forKey: .completed_at)
        self.receiptCount = try c.decodeIfPresent(Int.self, forKey: .receiptCount)
                          ?? c.decodeIfPresent(Int.self, forKey: .receipt_count)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(deskHandle, forKey: .deskHandle)
        try c.encodeIfPresent(projectSpaceId, forKey: .projectSpaceId)
        try c.encode(title, forKey: .title)
        try c.encode(objective, forKey: .objective)
        try c.encode(status, forKey: .status)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(autonomyLevel, forKey: .autonomyLevel)
        try c.encodeIfPresent(permissionProfile, forKey: .permissionProfile)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(receiptCount, forKey: .receiptCount)
    }
}

extension WorkshopExecutionRecord {
    /// Direct construction. `init(from decoder:)` above suppresses the
    /// memberwise init, which forced UI bridges to round-trip through
    /// JSONSerialization + JSONDecoder just to build a record in memory —
    /// a path whose only totality guarantee was a `try!` on an interpolated
    /// JSON string. `phase` defaults to `status`, matching the decoder's
    /// rule for queue Workshop executions that carry no phase of their own.
    init(
        id: String,
        deskHandle: String? = nil,
        projectSpaceId: String? = nil,
        title: String = "",
        objective: String = "",
        status: String = "queued",
        phase: String? = nil,
        priority: String? = nil,
        autonomyLevel: String? = nil,
        permissionProfile: String? = nil,
        summary: String? = nil,
        createdAt: String = "",
        updatedAt: String? = nil,
        completedAt: String? = nil,
        receiptCount: Int? = nil
    ) {
        self.id = id
        self.deskHandle = deskHandle
        self.projectSpaceId = projectSpaceId
        self.title = title
        self.objective = objective
        self.status = status
        self.phase = phase ?? status
        self.priority = priority
        self.autonomyLevel = autonomyLevel
        self.permissionProfile = permissionProfile
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.receiptCount = receiptCount
    }
}

struct CoordinationCommandEntry: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var subtitle: String?
    var category: String?
    var systemImage: String?
    var route: String?
    var endpoint: String?
    var keywords: [String]?
    var status: String?
    var count: Int?
}
