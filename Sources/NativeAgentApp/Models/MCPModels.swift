import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import MCPDispatcher

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

typealias MCPConsentRecord = MCPDispatcher.MCPConsentRecord

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

typealias MCPCallResult = MCPDispatcher.MCPCallResult
