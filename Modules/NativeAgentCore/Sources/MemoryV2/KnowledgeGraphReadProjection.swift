import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `KnowledgeGraphReadProjection.swift` | Checked complete graph projection, typed canvas entities/edges with complete last-seen timestamp parsing, and derived neighborhoods from the same snapshot; `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData` |

extension KnowledgeGraphEntity {
    /// Only a complete recorded timestamp establishes recency. Do not salvage
    /// a date prefix or substitute creation time for missing last-seen evidence.
    public var lastSeenDate: Date? {
        lastSeen.flatMap(Self.parseLastSeen)
    }

    public static func parseLastSeen(_ timestamp: String) -> Date? {
        guard timestamp.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                             options: .regularExpression) != nil else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(timestamp)
    }
}

public struct CanonicalAgentGraphReadout: Sendable {
    public let entities: [GraphEntity]
    public let edges: [AgentGraphEdge]
    public let canvasEntities: [KnowledgeGraphEntity]
    public let canvasEdges: [KnowledgeGraphEdge]
    public let updatedAt: String?

    public func neighborhood(entityID: String) -> KnowledgeGraphNeighborhood? {
        guard let entity = canvasEntities.first(where: { $0.id == entityID }) else { return nil }
        let edges = canvasEdges.filter { $0.from == entityID || $0.to == entityID }
        let ids = Set(edges.flatMap { [$0.from, $0.to] })
        return KnowledgeGraphNeighborhood(
            entity: entity, edges: edges,
            neighbors: Dictionary(uniqueKeysWithValues: canvasEntities.filter { ids.contains($0.id) }.map { ($0.id, $0) })
        )
    }
}

/// Checked graph projections shared by mounted views and remote snapshots.
public enum AgentGraphReads {
    public static func canonicalAgentGraphProjection(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath(),
        surface: String? = nil,
        personaID: String? = nil,
        timestamp: (Date) -> String
    ) async throws -> CanonicalAgentGraphReadout {
        let reader = makeKnowledgeGraphReader(graphPath: graphPath)
        let snapshot = try await reader.completeSnapshotChecked(surface: surface, personaID: personaID)
        guard case .object(let envelope) = snapshot,
              case .array(let rawEntities)? = envelope["entities"],
              case .array(let rawEdges)? = envelope["edges"] else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "complete snapshot did not contain entity and edge arrays"
            )
        }

        let entities = rawEntities.compactMap { value -> GraphEntity? in
            guard case .object(let object) = value,
                  let id = object["id"]?.stringValue,
                  !id.isEmpty else { return nil }
            return graphEntity(id: id, object: object)
        }.sorted { $0.id < $1.id }
        let validEntityIDs = Set(entities.map(\.id))
        let edges = rawEdges.enumerated().compactMap { index, value -> AgentGraphEdge? in
            guard case .object(let object) = value,
                  let from = object["from"]?.stringValue,
                  let to = object["to"]?.stringValue,
                  !from.isEmpty,
                  !to.isEmpty,
                  validEntityIDs.contains(from),
                  validEntityIDs.contains(to) else { return nil }
            let label = object["type"]?.stringValue
            let id = object["id"]?.stringValue
                ?? "\(from)->\(to):\(label ?? "edge"):\(index)"
            return AgentGraphEdge(id: id, fromNode: from, toNode: to, label: label)
        }
        let updatedAt = canonicalKnowledgeGraphUpdatedAt(
            graphPath: graphPath,
            entities: entities,
            timestamp: timestamp
        )
        return CanonicalAgentGraphReadout(
            entities: entities,
            edges: edges,
            canvasEntities: try rawEntities.map(KnowledgeGraphEntity.init(checked:)),
            canvasEdges: try rawEdges.map(KnowledgeGraphEdge.init(checked:)),
            updatedAt: updatedAt
        )
    }

    public static func canonicalKnowledgeGraphSnapshotData(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath(),
        surface: String,
        personaID: String? = nil
    ) async throws -> Data {
        let snapshot = try await makeKnowledgeGraphReader(graphPath: graphPath)
            .completeSnapshotChecked(surface: surface, personaID: personaID)
        return try snapshot.serializedData(pretty: false)
    }

    public static func graphIndexStatus(from projection: CanonicalAgentGraphReadout) -> GraphIndexStatus {
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
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: sqlitePath.path
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
                  let id = raw["id"]?.stringValue,
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
                score: raw["score"]?.numberValue(coercingStrings: true, finiteOnly: false) ?? 0,
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
            name: object["name"]?.stringValue ?? id,
            aliases: graphStringArray(object["aliases"]).isEmpty ? nil : graphStringArray(object["aliases"]),
            kind: object["type"]?.stringValue,
            confidence: object["confidence"]?.numberValue(coercingStrings: true, finiteOnly: false),
            mentions: object["mention_count"]?.exactIntegerValue,
            updatedAt: object["last_seen"]?.stringValue
        )
    }

    private static func graphStringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(\.stringValue)
    }

}
