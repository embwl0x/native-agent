import Foundation
// Blueprint: | `MemoryModels.swift` | Shared memory rows and proposals with compatible field decoding and persisted proposal key spellings |

public struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var layer: String
    public var text: String
    public var sourceRunId: String?
    public var importance: Double
    public var confidence: Double
    public var status: String?
    public var pinned: Bool?
    public var tags: [String]?
    public var createdAt: String
    public var updatedAt: String?

    public init(
        id: String, layer: String, text: String, sourceRunId: String? = nil,
        importance: Double, confidence: Double, status: String? = nil, pinned: Bool? = nil,
        tags: [String]? = nil, createdAt: String, updatedAt: String? = nil
    ) {
        self.id = id
        self.layer = layer
        self.text = text
        self.sourceRunId = sourceRunId
        self.importance = importance
        self.confidence = confidence
        self.status = status
        self.pinned = pinned
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MemoryProposalRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var displayText: String? = nil
    public var layer: String? = nil
    public var importance: Double? = nil
    public var status: String? = nil
    public var sourceRunId: String? = nil
    public var createdAt: String? = nil
    public var supportingSessionIds: [String]
    public var recurrenceCount: Int

    public var isPending: Bool {
        let normalized = (status ?? "pending").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "pending" || normalized == "proposed"
    }

    private var firstSeen: String? = nil
    private var lastSeen: String? = nil
    private var stagedAt: String? = nil
    private var resolvedAt: String? = nil
    private var rejectionReason: String? = nil

    public init(id: String, text: String, supportingSessionIds: [String], recurrenceCount: Int,
                status: String, createdAt: String, rejectionReason: String?) {
        self.id = id; self.text = text; self.supportingSessionIds = supportingSessionIds
        self.recurrenceCount = recurrenceCount; self.status = status
        firstSeen = createdAt; lastSeen = createdAt; stagedAt = createdAt
        self.rejectionReason = rejectionReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, displayText, layer, importance, status, sourceRunId, createdAt
        case proposalId = "proposal_id"
        case factText = "fact_text"
        case displayTextSnake = "display_text"
        case targetDoc = "target_doc"
        case sourceRunIdSnake = "source_run_id"
        case createdAtSnake = "created_at"
        case supportingSessionIdsSnake = "supporting_session_ids"
        case recurrenceCountSnake = "recurrence_count"
        case firstSeen = "first_seen", lastSeen = "last_seen", stagedAt = "staged_at"
        case resolvedAt = "resolved_at", rejectionReason = "rejection_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try (try? container.decode(String.self, forKey: .id)) ?? container.decode(String.self, forKey: .proposalId)
        text = try (try? container.decode(String.self, forKey: .text)) ?? container.decode(String.self, forKey: .factText)
        displayText = (try? container.decode(String.self, forKey: .displayText))
            ?? (try? container.decode(String.self, forKey: .displayTextSnake))
        layer = (try? container.decode(String.self, forKey: .layer))
            ?? (try? container.decode(String.self, forKey: .targetDoc))
        importance = try? container.decode(Double.self, forKey: .importance)
        status = try? container.decode(String.self, forKey: .status)
        sourceRunId = (try? container.decode(String.self, forKey: .sourceRunId))
            ?? (try? container.decode(String.self, forKey: .sourceRunIdSnake))
        createdAt = (try? container.decode(String.self, forKey: .createdAt))
            ?? (try? container.decode(String.self, forKey: .createdAtSnake))
        supportingSessionIds = (try? container.decode([String].self, forKey: .supportingSessionIdsSnake)) ?? []
        firstSeen = try? container.decode(String.self, forKey: .firstSeen)
        lastSeen = try? container.decode(String.self, forKey: .lastSeen)
        stagedAt = try? container.decode(String.self, forKey: .stagedAt)
        resolvedAt = try? container.decode(String.self, forKey: .resolvedAt)
        rejectionReason = try? container.decode(String.self, forKey: .rejectionReason)
        recurrenceCount = (try? container.decode(Int.self, forKey: .recurrenceCountSnake)) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .proposalId)
        try c.encode(text, forKey: .factText)
        try c.encodeIfPresent(displayText, forKey: .displayTextSnake)
        try c.encode(supportingSessionIds, forKey: .supportingSessionIdsSnake)
        try c.encode(recurrenceCount, forKey: .recurrenceCountSnake)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(firstSeen, forKey: .firstSeen)
        try c.encodeIfPresent(lastSeen, forKey: .lastSeen)
        try c.encodeIfPresent(stagedAt, forKey: .stagedAt)
        try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try c.encodeIfPresent(rejectionReason, forKey: .rejectionReason)
    }

    public var evidenceSummary: String {
        let sessions = supportingSessionIds.count
        let observation = "Observed \(recurrenceCount)x"
        guard sessions > 0 else { return recurrenceCount == 1 ? "Observed once" : observation }
        return "\(observation) in \(sessions) session\(sessions == 1 ? "" : "s")"
    }
}
