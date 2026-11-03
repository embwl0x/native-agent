import Foundation
// Blueprint: | `MemoryModels.swift` | Shared canonical memory values preserve optional absence and tags; checked proposals carry one createdAt without synthetic historical timestamps |

public struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var layer: String?
    public var text: String
    public var sourceRunId: String?
    public var importance: Double?
    public var confidence: Double?
    public var status: String?
    public var pinned: Bool?
    public var tags: [String]?
    public var createdAt: String
    public var updatedAt: String?

    public init(
        id: String, layer: String?, text: String, sourceRunId: String? = nil,
        importance: Double?, confidence: Double?, status: String? = nil, pinned: Bool? = nil,
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
    public var recurrenceCount: Int?
    public var evidenceError: String?

    public var isPending: Bool {
        let normalized = (status ?? "pending").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "pending" || normalized == "proposed"
    }

    private var rejectionReason: String? = nil

    public init(id: String, text: String, supportingSessionIds: [String], recurrenceCount: Int?,
                status: String, createdAt: String, rejectionReason: String?, evidenceError: String? = nil) {
        self.id = id; self.text = text; self.supportingSessionIds = supportingSessionIds
        self.recurrenceCount = recurrenceCount; self.status = status
        self.evidenceError = evidenceError
        self.createdAt = createdAt
        self.rejectionReason = rejectionReason
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case proposalId = "proposal_id"
        case factText = "fact_text"
        case supportingSessionIdsSnake = "supporting_session_ids"
        case recurrenceCountSnake = "recurrence_count"
        case evidenceError = "evidence_error"
        case createdAt, rejectionReason = "rejection_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .proposalId)
        text = try container.decode(String.self, forKey: .factText)
        status = try container.decode(String.self, forKey: .status)
        supportingSessionIds = try container.decode([String].self, forKey: .supportingSessionIdsSnake)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        rejectionReason = try container.decodeIfPresent(String.self, forKey: .rejectionReason)
        recurrenceCount = try container.decodeIfPresent(Int.self, forKey: .recurrenceCountSnake)
        evidenceError = try container.decodeIfPresent(String.self, forKey: .evidenceError)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .proposalId)
        try c.encode(text, forKey: .factText)
        try c.encode(supportingSessionIds, forKey: .supportingSessionIdsSnake)
        try c.encode(recurrenceCount, forKey: .recurrenceCountSnake)
        try c.encodeIfPresent(evidenceError, forKey: .evidenceError)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(rejectionReason, forKey: .rejectionReason)
    }

    public var evidenceSummary: String {
        Self.evidenceDescription(sessionCount: supportingSessionIds.count, recurrenceCount: recurrenceCount, error: evidenceError)
    }

    public static func evidenceDescription(sessionCount: Int, recurrenceCount: Int?, error: String?) -> String {
        if let error { return "Recorded evidence is malformed: \(error)" }
        guard let recurrenceCount else { return "Observation count not recorded" }
        guard recurrenceCount > 0 else { return "Recorded observation count is invalid" }
        let observation = recurrenceCount == 1 ? "Observed once" : "Observed \(recurrenceCount)x"
        guard sessionCount > 0 else { return observation + "; session evidence unavailable" }
        return "\(observation) in \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }
}
