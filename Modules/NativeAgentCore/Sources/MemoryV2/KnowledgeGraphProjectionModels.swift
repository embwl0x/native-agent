import Foundation
// Blueprint: | `KnowledgeGraphProjectionModels.swift` | `AgentGraphEdge`, `GraphEntity` structs |

public struct AgentGraphEdge: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var fromNode: String
    public var toNode: String
    public var label: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fromNode = "from"
        case toNode = "to"
        case label
    }
    public init(id: String, fromNode: String, toNode: String, label: String? = nil) {
        self.id = id
        self.fromNode = fromNode
        self.toNode = toNode
        self.label = label
    }
}

public struct GraphEntity: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]?
    public var kind: String?
    public var confidence: Double?
    public var mentions: Int?
    public var updatedAt: String?
    public init(id: String, name: String, aliases: [String]? = nil, kind: String? = nil, confidence: Double? = nil, mentions: Int? = nil,
        updatedAt: String? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.confidence = confidence
        self.mentions = mentions
        self.updatedAt = updatedAt
    }
}
