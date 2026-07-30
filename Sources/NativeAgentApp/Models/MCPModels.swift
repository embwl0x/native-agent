import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct MCPServerRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var transport: String?
    var endpoint: String?
    var command: String?
    var status: String?
    var healthStatus: String?
    var toolCount: Int?
    var resourceCount: Int?
    var riskClass: String?
    var updatedAt: String?
}

struct MCPSessionStatus: Identifiable, Codable, Hashable {
    var id: String
    var serverId: String
    var serverName: String?
    var transport: String?
    var status: String?
    var healthStatus: String?
    var toolCount: Int?
    var resourceCount: Int?
    var lastWarmedAt: String?
    var lastError: String?
    var updatedAt: String?
}

struct MCPConsentRecord: Identifiable, Codable, Hashable {
    var id: String
    var serverId: String?
    var toolName: String?
    var scope: String?
    var risk: String?
    var status: String?
    var argumentSummary: String?
    var grantedAt: String?
    var revokedAt: String?
    var updatedAt: String?
}

struct MCPToolRecord: Identifiable, Codable, Hashable {
    var name: String
    var description: String?
    var inputSchema: JSONValue?

    var id: String { name }

    // Manual Hashable: JSONValue is Equatable+Sendable but not Hashable, and
    // the tool name uniquely identifies the record on a given server.
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

struct MCPToolsResponse: Codable, Hashable {
    var serverId: String?
    var tools: [MCPToolRecord]
    var createdAt: String?
}

struct MCPResourceRecord: Identifiable, Codable, Hashable {
    var uri: String
    var name: String?
    var mimeType: String?

    var id: String { uri }
}

struct MCPResourcesResponse: Codable, Hashable {
    var serverId: String?
    var resources: [MCPResourceRecord]
    var createdAt: String?
}

struct MCPCallResult: Identifiable, Codable {
    var id: String
    var serverId: String
    var toolName: String
    var status: String
    var approvalId: String?
    var durationSeconds: Double?
    var createdAt: String?
    /// Bounded, recursively redacted projection of the actual MCP result.
    /// The full unredacted payload is never retained by this UI model.
    var result: JSONValue? = nil
    var resultPreview: String? = nil
    var resultByteCount: Int? = nil
    var redactedByteCount: Int? = nil
    var resultTruncated: Bool? = nil
    var resultDigest: String? = nil
    var receiptId: String? = nil
    /// "recorded" | "failed" | "not_required". This is deliberately
    /// separate from `status`: a tool may have completed even if evidence
    /// persistence subsequently failed.
    var evidenceStatus: String? = nil
    var evidenceError: String? = nil
}
