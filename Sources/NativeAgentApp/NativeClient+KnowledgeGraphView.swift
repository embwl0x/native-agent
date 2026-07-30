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
    func searchKG(q: String) async throws -> KGSearchResponse {
        // Empty query keeps the old empty-results contract.
        if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KGSearchResponse(results: [])
        }
        let reader = makeKnowledgeGraphReader()
        let env = try await reader.searchChecked(q: q)
        let data = try env.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(KGSearchResponse.self, from: data)
    }
    // Forget writes run in-process against the co-located data root. The
    // client selects authoritative memory.sqlite whenever it exists and uses
    // JSON only for a true pre-SQLite store.
    func forgetKGEntity(id: String, reason: String) async throws -> [String: Any] {
        // Reject an empty entity id before any graph mutation setup.
        if id.isEmpty {
            throw NSError(domain: "NativeAgent", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "entity_id required"])
        }
        let impl = makeKnowledgeGraphForgetClient(
            graphPath: SwiftNativeKnowledgeGraphReader.defaultPath()
        )
        let result = try await impl.forgetEntity(entityId: id, reason: reason)
        let data = try result.serializedData(pretty: false)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NativeAgent", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "KG forget native response was not a JSON object"])
        }
        return dict
    }
}
