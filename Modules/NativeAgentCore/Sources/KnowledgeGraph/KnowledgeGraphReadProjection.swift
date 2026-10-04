import Foundation
import PersistenceCore

public struct CanonicalAgentGraphProjection: Sendable {
    public let entities: [GraphEntity]
    public let edges: [AgentGraphEdge]
    public let updatedAt: String?
}

/// Checked graph projections shared by mounted views and remote snapshots.
public enum KnowledgeGraphReadProjection {
    public static func canonicalAgentGraphProjection(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath(),
        timestamp: (Date) -> String
    ) async throws -> CanonicalAgentGraphProjection {
        let reader = makeKnowledgeGraphReader(graphPath: graphPath)
        let snapshot = try await reader.completeSnapshotChecked()
        guard case .object(let envelope) = snapshot,
              case .array(let rawEntities)? = envelope["entities"],
              case .array(let rawEdges)? = envelope["edges"] else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "complete snapshot did not contain entity and edge arrays"
            )
        }

        let entities = rawEntities.compactMap { value -> GraphEntity? in
            guard case .object(let object) = value,
                  let id = graphString(object["id"]),
                  !id.isEmpty else { return nil }
            return graphEntity(id: id, object: object)
        }.sorted { $0.id < $1.id }
        let validEntityIDs = Set(entities.map(\.id))
        let edges = rawEdges.enumerated().compactMap { index, value -> AgentGraphEdge? in
            guard case .object(let object) = value,
                  let from = graphString(object["from"]),
                  let to = graphString(object["to"]),
                  !from.isEmpty,
                  !to.isEmpty,
                  validEntityIDs.contains(from),
                  validEntityIDs.contains(to) else { return nil }
            let label = graphString(object["type"]) ?? graphString(object["kind"])
            let id = graphString(object["id"])
                ?? "\(from)->\(to):\(label ?? "edge"):\(index)"
            return AgentGraphEdge(id: id, fromNode: from, toNode: to, label: label)
        }
        let updatedAt = canonicalKnowledgeGraphUpdatedAt(
            graphPath: graphPath,
            entities: entities,
            timestamp: timestamp
        )
        return CanonicalAgentGraphProjection(
            entities: entities,
            edges: edges,
            updatedAt: updatedAt
        )
    }

    public static func canonicalKnowledgeGraphSnapshotData(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath()
    ) async throws -> Data {
        let snapshot = try await makeKnowledgeGraphReader(graphPath: graphPath)
            .completeSnapshotChecked()
        return try snapshot.serializedData(pretty: false)
    }

    public static func agentGraph(
        from projection: CanonicalAgentGraphProjection,
        executionCount: Int?
    ) -> AgentGraph {
        let nodes = projection.entities.map {
            AgentGraphNode(id: $0.id, label: $0.name, kind: $0.kind, status: nil)
        }
        return AgentGraph(
            nodes: nodes,
            edges: projection.edges,
            summary: AgentGraphCounts(
                nodes: nodes.count,
                edges: projection.edges.count,
                executions: executionCount,
                capabilities: nil
            ),
            createdAt: projection.updatedAt
        )
    }

    public static func graphIndexStatus(from projection: CanonicalAgentGraphProjection) -> GraphIndexStatus {
        GraphIndexStatus(
            status: "ready",
            embeddingModel: "swift-memory-v2",
            dimensions: nil,
            nodeCount: projection.entities.count,
            entityCount: projection.entities.count,
            updatedAt: projection.updatedAt
        )
    }

    private static func canonicalKnowledgeGraphUpdatedAt(
        graphPath: URL,
        entities: [GraphEntity],
        timestamp: (Date) -> String
    ) -> String? {
        if let latestEntity = entities.compactMap(\.updatedAt).max() {
            return latestEntity
        }
        let memoryDirectory = graphPath.deletingLastPathComponent()
        let sqlitePath = memoryDirectory.appendingPathComponent("memory.sqlite")
        let authoritativePath = FileManager.default.fileExists(atPath: sqlitePath.path)
            ? sqlitePath
            : graphPath
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: authoritativePath.path
        ), let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return timestamp(modified)
    }

    public static func searchGraph(query: String, graphPath: URL) async throws -> GraphSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GraphSearchResponse(
                query: query,
                results: [],
                summary: GraphSearchCounts(resultCount: 0, nodeCount: 0, edgeCount: 0),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        let envelope = try await makeKnowledgeGraphReader(graphPath: graphPath)
            .searchChecked(q: trimmed)
        guard case .object(let object) = envelope,
              case .array(let rawResults)? = object["results"] else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "search projection did not contain a results array"
            )
        }
        let results: [GraphSearchResult] = rawResults.prefix(50).compactMap { value in
            guard case .object(let raw) = value,
                  let id = Self.graphString(raw["id"]),
                  !id.isEmpty else { return nil }
            let entity = Self.graphEntity(id: id, object: raw)
            return GraphSearchResult(
                id: entity.id,
                node: AgentGraphNode(
                    id: entity.id,
                    label: entity.name,
                    kind: entity.kind,
                    status: nil
                ),
                score: Self.graphDouble(raw["score"]) ?? 0,
                matchedTerms: [trimmed],
                matchedEntities: [entity.name],
                relatedEdges: nil,
                explanation: nil
            )
        }
        return GraphSearchResponse(
            query: query,
            results: results,
            summary: GraphSearchCounts(resultCount: results.count, nodeCount: results.count, edgeCount: 0),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private static func graphEntity(id: String, object: [String: JSONValue]) -> GraphEntity {
        GraphEntity(
            id: id,
            name: graphString(object["name"]) ?? id,
            aliases: graphStringArray(object["aliases"]).isEmpty ? nil : graphStringArray(object["aliases"]),
            kind: graphString(object["type"]) ?? graphString(object["kind"]),
            confidence: graphDouble(object["confidence"]),
            mentions: {
                let value = graphInt(object["mention_count"])
                return value == 0 ? nil : value
            }(),
            sourceNodeIds: {
                let snake = graphStringArray(object["source_node_ids"])
                if !snake.isEmpty { return snake }
                let camel = graphStringArray(object["sourceNodeIds"])
                return camel.isEmpty ? nil : camel
            }(),
            updatedAt: graphString(object["last_seen"])
        )
    }

    private static func graphString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value { return string }
        return nil
    }

    private static func graphStringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { graphString($0) }
    }

    private static func graphInt(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .int(let int): return Int(int)
        case .double(let double): return Int(exactly: double.rounded(.towardZero)) ?? 0
        case .string(let string): return Int(string) ?? 0
        default: return 0
        }
    }

    private static func graphDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let double): return double
        case .int(let int): return Double(int)
        case .string(let string): return Double(string)
        default: return nil
        }
    }
}
