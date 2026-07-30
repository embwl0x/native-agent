import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct ResearchLabRun: Identifiable, Codable, Hashable {
    var id: String
    var objective: String
    var status: String
    var query: String?
    var sources: [ResearchResult]
    var brief: String?
    var connector: String?
    var error: String?
    var createdAt: String?
}

struct RuntimeTrace: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var title: String
    var status: String?
    var createdAt: String?
}

struct AgentGraphNode: Identifiable, Codable, Hashable {
    var id: String
    var label: String?
    var kind: String?
    var status: String?
}

struct AgentGraphEdge: Identifiable, Codable, Hashable {
    var id: String
    var fromNode: String
    var toNode: String
    var label: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fromNode = "from"
        case toNode = "to"
        case label
    }
}

struct AgentGraphCounts: Codable, Hashable {
    var nodes: Int
    var edges: Int
    var executions: Int?
    var capabilities: Int?

    enum CodingKeys: String, CodingKey {
        case nodes, edges, capabilities
        case executions = "missions" // compatibility wire ID (persisted graphs/index.json)
    }
}

struct AgentGraph: Codable, Hashable {
    var nodes: [AgentGraphNode]
    var edges: [AgentGraphEdge]
    var summary: AgentGraphCounts
    var createdAt: String?
}

struct GraphSearchResult: Identifiable, Codable, Hashable {
    var id: String
    var node: AgentGraphNode
    var score: Double
    var matchedTerms: [String]?
    var matchedEntities: [String]?
    var relatedEdges: [AgentGraphEdge]?
    var explanation: String?
}

struct GraphSearchCounts: Codable, Hashable {
    var resultCount: Int
    var nodeCount: Int?
    var edgeCount: Int?
}

struct GraphSearchResponse: Codable, Hashable {
    var query: String
    var results: [GraphSearchResult]
    var summary: GraphSearchCounts?
    var createdAt: String?
}

struct GraphEntity: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var aliases: [String]?
    var kind: String?
    var confidence: Double?
    var mentions: Int?
    var sourceNodeIds: [String]?
    var updatedAt: String?
}

struct GraphIndexStatus: Codable, Hashable {
    var status: String
    var embeddingModel: String?
    var dimensions: Int?
    var nodeCount: Int?
    var entityCount: Int?
    var updatedAt: String?
}
