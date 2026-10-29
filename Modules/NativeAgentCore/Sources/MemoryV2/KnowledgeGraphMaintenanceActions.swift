import Foundation
import PersistenceCore

// Blueprint: | `KnowledgeGraphMaintenanceActions.swift` | `KnowledgeGraphMaintenanceActions`: canonical orphan-sweep preview/apply; apply requires exactly the reviewed candidate set |

/// The action boundary behind the Knowledge Graph's explicit orphan-sweep
/// controls and the agent's `rebuild_knowledge_graph mode: sweep_orphans`.
/// Both preview and apply re-read the canonical memory store at the moment
/// they run; a preview is never permission to delete a later state.
public struct KnowledgeGraphMaintenanceActions: Sendable {
    public enum ApplyResult: Sendable, Equatable {
        case applied(KnowledgeGraphGCReport)
        case previewDiverged(currentCandidates: [KnowledgeGraphGCCandidate])
    }
    public let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func previewOrphanSweep() async throws -> KnowledgeGraphGCReport {
        let indexer = try await liveIndexer()
        return try await indexer.collectGarbage(apply: false)
    }

    /// Applies only when the candidate set is still exactly the one the user
    /// reviewed. A shrink can mean another writer fixed an item; a superset can
    /// contain a newly orphaned item the user never saw. Both require a new
    /// confirmation instead of silently broadening or narrowing deletion.
    public func applyOrphanSweep(expectedCandidateIDs: Set<String>) async throws -> ApplyResult {
        let indexer = try await liveIndexer()
        let applied = try await indexer.collectGarbage(
            apply: true,
            expectedCandidateIDs: expectedCandidateIDs
        )
        if applied.candidateSetDiverged {
            return .previewDiverged(currentCandidates: applied.candidates)
        }
        return .applied(applied)
    }

    private func liveIndexer() async throws -> SwiftNativeKnowledgeGraphIndexer {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        return try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
    }
}
