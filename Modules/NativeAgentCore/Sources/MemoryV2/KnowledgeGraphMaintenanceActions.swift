import Foundation
import PersistenceCore

// Blueprint: | `KnowledgeGraphMaintenanceActions.swift` | `KnowledgeGraphMaintenanceActions`: exact-reviewed-set orphan removal |

/// Preview grants no permission to delete a later state; both graph controls and `rebuild_knowledge_graph mode: sweep_orphans` reread canonical memory.
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

    /// Require the exact reviewed candidate set: shrinking may reflect another writer's repair, and growth may include unseen orphans; either requires
    /// confirmation.
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
