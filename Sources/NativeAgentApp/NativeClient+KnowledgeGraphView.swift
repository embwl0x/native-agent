import Foundation
import KnowledgeGraph
import TrustCenter
import PersistenceCore

struct CanonicalAgentGraphProjection: Sendable {
    let entities: [GraphEntity]
    let edges: [AgentGraphEdge]
    let updatedAt: String?
}

/// One coherent mounted graph read. The graph canvas, entity list, and status
/// are projections of the same checked KnowledgeGraph snapshot; a consumer
/// must not re-read each field and accidentally compose a view from different
/// graph generations.
struct NativeClientKnowledgeGraphViewRead {
    let agentGraph: AgentGraph
    let entities: [GraphEntity]
    let status: GraphIndexStatus
}

// ---------------------------------------------------------------------------
// MARK: - NativeClient knowledge graph extensions
// NativeClient knowledge graph read/write helpers
// ---------------------------------------------------------------------------

extension NativeClient {
    /// The mounted graph view must read from the app's injected data root as
    /// well as the production default.  Otherwise an isolated/relaunched app
    /// can display a healthy graph from another profile, and an error banner
    /// cannot truthfully describe the root the user is viewing.
    /// One root-resolved path shared by every mounted graph projection and
    /// search route.  It is internal so the sibling graph read APIs cannot
    /// accidentally fall back to the default profile.
    var knowledgeGraphPath: URL {
        (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
    }

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

    /// Read all graph-view projections from one checked canonical snapshot.
    /// The workshop count is supplementary and remains nil when its separate
    /// store is unavailable; it must not turn an unavailable read into zero or
    /// prevent a sound graph from rendering.
    func getKnowledgeGraphViewRead() async throws -> NativeClientKnowledgeGraphViewRead {
        let projection = try await Self.canonicalAgentGraphProjection(
            graphPath: knowledgeGraphPath
        )
        let executionCount: Int?
        do {
            executionCount = try await getWorkshopExecutions().count
        } catch {
            executionCount = nil
        }
        return NativeClientKnowledgeGraphViewRead(
            agentGraph: Self.agentGraph(from: projection, executionCount: executionCount),
            entities: projection.entities,
            status: Self.graphIndexStatus(from: projection)
        )
    }

    static func agentGraph(
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

    static func graphIndexStatus(from projection: CanonicalAgentGraphProjection) -> GraphIndexStatus {
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
        let reader = makeKnowledgeGraphReader(graphPath: knowledgeGraphPath)
        let env = try await reader.allEntitiesChecked(page: page)
        let data = try env.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(KGEntityResponse.self, from: data)
    }
    func getKGEntity(id: String) async throws -> KGNeighborsResponse {
        let reader = makeKnowledgeGraphReader(graphPath: knowledgeGraphPath)
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
