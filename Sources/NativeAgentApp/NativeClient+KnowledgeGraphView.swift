import Foundation
import KnowledgeGraph
import TrustCenter

struct CanonicalAgentGraphProjection: Sendable {
    let entities: [GraphEntity]
    let edges: [AgentGraphEdge]
    let updatedAt: String?
}

// ---------------------------------------------------------------------------
// MARK: - NativeClient knowledge graph extensions
// NativeClient knowledge graph read/write helpers
// ---------------------------------------------------------------------------

extension NativeClient {
    static func canonicalAgentGraphProjection(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath()
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
            entities: entities
        )
        return CanonicalAgentGraphProjection(
            entities: entities,
            edges: edges,
            updatedAt: updatedAt
        )
    }

    static func canonicalKnowledgeGraphSnapshotData(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath()
    ) async throws -> Data {
        let snapshot = try await makeKnowledgeGraphReader(graphPath: graphPath)
            .completeSnapshotChecked()
        return try snapshot.serializedData(pretty: false)
    }

    private static func canonicalKnowledgeGraphUpdatedAt(
        graphPath: URL,
        entities: [GraphEntity]
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
        return SwiftNativeManifestSigner.isoTimestamp(modified)
    }

    // SwiftNativeKnowledgeGraphReader reads the co-located NativeAgent data
    // root and returns the graph envelope re-serialized through
    // JSONDecoder.nativeAgent. Checked reads throw instead of fabricating a
    // healthy empty graph for unreadable storage.
    func getKnowledgeGraph(page: Int = 0) async throws -> KGEntityResponse {
        let reader = makeKnowledgeGraphReader()
        let env = try await reader.allEntitiesChecked(page: page)
        let data = try env.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(KGEntityResponse.self, from: data)
    }
    func getKGEntity(id: String) async throws -> KGNeighborsResponse {
        let reader = makeKnowledgeGraphReader()
        switch try await reader.entityChecked(id: id) {
        case .found(let env):
            let data = try env.serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(KGNeighborsResponse.self, from: data)
        case .notFound:
            // Preserve not-found separately from store read errors.
            throw URLError(.resourceUnavailable)
        }
    }
}
