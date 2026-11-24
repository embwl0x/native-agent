import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `KnowledgeGraphReadProjection.swift` | `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData`: checked graph projections |

extension KnowledgeGraphEntity {
    /// Only a complete recorded timestamp establishes recency. Do not salvage a date prefix or substitute creation time for missing last-seen evidence.
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
}

public enum AgentGraphReads {
    @concurrent public static func canonicalAgentGraphProjection(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath(),
        surface: String? = nil,
        personaID: String? = nil,
        timestamp: @Sendable (Date) -> String
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

    @concurrent public static func canonicalKnowledgeGraphSnapshotData(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath(),
        surface: String,
        personaID: String? = nil
    ) async throws -> Data {
        let snapshot = try await makeKnowledgeGraphReader(graphPath: graphPath)
            .completeSnapshotChecked(surface: surface, personaID: personaID)
        return try snapshot.serializedData(pretty: false)
    }

    private static func canonicalKnowledgeGraphUpdatedAt(
        graphPath: URL,
        entities: [GraphEntity],
        timestamp: @Sendable (Date) -> String
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

    private static func graphEntity(id: String, object: [String: JSONValue]) -> GraphEntity {
        GraphEntity(
            id: id,
            name: object["name"]?.stringValue ?? id,
            aliases: JSONValue.stringArray(object["aliases"]).isEmpty ? nil : JSONValue.stringArray(object["aliases"]),
            kind: object["type"]?.stringValue,
            confidence: object["confidence"]?.numberValue(coercingStrings: true, finiteOnly: false),
            mentions: object["mention_count"]?.exactIntegerValue,
            updatedAt: object["last_seen"]?.stringValue
        )
    }

}
