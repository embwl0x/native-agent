import Foundation

public struct AgentGraphNode: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var kind: String?
    public var status: String?
    public init(id: String, label: String? = nil, kind: String? = nil, status: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.status = status
    }
}

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

public struct AgentGraphCounts: Codable, Hashable, Sendable {
    public var nodes: Int
    public var edges: Int
    public var executions: Int?
    public var capabilities: Int?

    enum CodingKeys: String, CodingKey {
        case nodes, edges, capabilities
        case executions = "missions" // compatibility wire ID (persisted graphs/index.json)
    }
    public init(nodes: Int, edges: Int, executions: Int? = nil, capabilities: Int? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.executions = executions
        self.capabilities = capabilities
    }
}

public struct AgentGraph: Codable, Hashable, Sendable {
    public var nodes: [AgentGraphNode]
    public var edges: [AgentGraphEdge]
    public var summary: AgentGraphCounts
    public var createdAt: String?
    public init(nodes: [AgentGraphNode], edges: [AgentGraphEdge], summary: AgentGraphCounts, createdAt: String? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct GraphSearchResult: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var node: AgentGraphNode
    public var score: Double
    public var matchedTerms: [String]?
    public var matchedEntities: [String]?
    public var relatedEdges: [AgentGraphEdge]?
    public var explanation: String?
    public init(id: String, node: AgentGraphNode, score: Double, matchedTerms: [String]? = nil, matchedEntities: [String]? = nil, relatedEdges: [AgentGraphEdge]? = nil, explanation: String? = nil) {
        self.id = id
        self.node = node
        self.score = score
        self.matchedTerms = matchedTerms
        self.matchedEntities = matchedEntities
        self.relatedEdges = relatedEdges
        self.explanation = explanation
    }
}

public struct GraphSearchCounts: Codable, Hashable, Sendable {
    public var resultCount: Int
    public var nodeCount: Int?
    public var edgeCount: Int?
    public init(resultCount: Int, nodeCount: Int? = nil, edgeCount: Int? = nil) {
        self.resultCount = resultCount
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
    }
}

public struct GraphSearchResponse: Codable, Hashable, Sendable {
    public var query: String
    public var results: [GraphSearchResult]
    public var summary: GraphSearchCounts?
    public var createdAt: String?
    public init(query: String, results: [GraphSearchResult], summary: GraphSearchCounts? = nil, createdAt: String? = nil) {
        self.query = query
        self.results = results
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct GraphEntity: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]?
    public var kind: String?
    public var confidence: Double?
    public var mentions: Int?
    public var sourceNodeIds: [String]?
    public var updatedAt: String?
    public init(id: String, name: String, aliases: [String]? = nil, kind: String? = nil, confidence: Double? = nil, mentions: Int? = nil, sourceNodeIds: [String]? = nil, updatedAt: String? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.confidence = confidence
        self.mentions = mentions
        self.sourceNodeIds = sourceNodeIds
        self.updatedAt = updatedAt
    }
}

public struct GraphIndexStatus: Codable, Hashable, Sendable {
    public var status: String
    public var embeddingModel: String?
    public var dimensions: Int?
    public var nodeCount: Int?
    public var entityCount: Int?
    public var updatedAt: String?
    public init(status: String, embeddingModel: String? = nil, dimensions: Int? = nil, nodeCount: Int? = nil, entityCount: Int? = nil, updatedAt: String? = nil) {
        self.status = status
        self.embeddingModel = embeddingModel
        self.dimensions = dimensions
        self.nodeCount = nodeCount
        self.entityCount = entityCount
        self.updatedAt = updatedAt
    }
}
