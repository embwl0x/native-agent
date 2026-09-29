import Foundation
import KnowledgeGraph
import TrustCenter
import PersistenceCore

typealias CanonicalAgentGraphProjection = KnowledgeGraph.CanonicalAgentGraphProjection

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
        try await KnowledgeGraphReadProjection.canonicalAgentGraphProjection(graphPath: graphPath, timestamp: SwiftNativeManifestSigner.isoTimestamp)
    }

    static func canonicalKnowledgeGraphSnapshotData(
        graphPath: URL = SwiftNativeKnowledgeGraphReader.defaultPath()
    ) async throws -> Data {
        try await KnowledgeGraphReadProjection.canonicalKnowledgeGraphSnapshotData(graphPath: graphPath)
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
            executionCount = try await DeskFacade(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()).taskRows().count
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
        KnowledgeGraphReadProjection.agentGraph(from: projection, executionCount: executionCount)
    }

    static func graphIndexStatus(from projection: CanonicalAgentGraphProjection) -> GraphIndexStatus {
        KnowledgeGraphReadProjection.graphIndexStatus(from: projection)
    }


}
