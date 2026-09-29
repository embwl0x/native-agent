import Foundation
import PersistenceCore

public struct MCPConsentRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var serverId: String?
    public var toolName: String?
    public var scope: String?
    public var risk: String?
    public var status: String?
    public var argumentSummary: String?
    public var grantedAt: String?
    public var revokedAt: String?
    public var updatedAt: String?
    public init(id: String, serverId: String?, toolName: String?, scope: String?, risk: String?, status: String?, argumentSummary: String?, grantedAt: String?, revokedAt: String?, updatedAt: String?) {
        self.id = id
        self.serverId = serverId
        self.toolName = toolName
        self.scope = scope
        self.risk = risk
        self.status = status
        self.argumentSummary = argumentSummary
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
        self.updatedAt = updatedAt
    }
}

public struct MCPCallResult: Identifiable, Codable, Sendable {
    public var id: String
    public var serverId: String
    public var toolName: String
    public var status: String
    public var approvalId: String?
    public var durationSeconds: Double?
    public var createdAt: String?
    /// Bounded, recursively redacted projection of the actual MCP result.
    /// The full unredacted payload is never retained by this UI model.
    public var result: JSONValue? = nil
    public var resultPreview: String? = nil
    public var resultByteCount: Int? = nil
    public var redactedByteCount: Int? = nil
    public var resultTruncated: Bool? = nil
    public var resultDigest: String? = nil
    public var receiptId: String? = nil
    /// "recorded" | "failed" | "not_required". This is deliberately
    /// separate from `status`: a tool may have completed even if evidence
    /// persistence subsequently failed.
    public var evidenceStatus: String? = nil
    public var evidenceError: String? = nil

    public init(
        id: String, serverId: String, toolName: String, status: String,
        approvalId: String? = nil, durationSeconds: Double? = nil, createdAt: String? = nil,
        result: JSONValue? = nil, resultPreview: String? = nil,
        resultByteCount: Int? = nil, redactedByteCount: Int? = nil,
        resultTruncated: Bool? = nil, resultDigest: String? = nil,
        receiptId: String? = nil, evidenceStatus: String? = nil, evidenceError: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.toolName = toolName
        self.status = status
        self.approvalId = approvalId
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.result = result
        self.resultPreview = resultPreview
        self.resultByteCount = resultByteCount
        self.redactedByteCount = redactedByteCount
        self.resultTruncated = resultTruncated
        self.resultDigest = resultDigest
        self.receiptId = receiptId
        self.evidenceStatus = evidenceStatus
        self.evidenceError = evidenceError
    }
}
