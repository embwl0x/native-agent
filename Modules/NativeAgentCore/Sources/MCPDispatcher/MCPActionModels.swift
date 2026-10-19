import Foundation
import PersistenceCore

extension MCPServer: Identifiable {}

/// A tool name is unique within the one server whose list it came from.
extension MCPTool: Identifiable {
    public var id: String { name }
}

public struct MCPResource: Identifiable, Hashable, Sendable {
    public var uri: String
    public var name: String?
    public var mimeType: String?

    public var id: String { uri }
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
