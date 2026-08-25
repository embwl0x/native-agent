import Foundation
import KnowledgeGraph
import MemoryV2
import PersistenceCore

/// The action boundary behind the Knowledge Graph's explicit orphan-sweep
/// controls.  Both preview and apply re-read the canonical memory store at the
/// moment they run; a preview is never permission to delete a later state.
struct KnowledgeGraphMaintenanceActions {
    enum ApplyResult: Sendable, Equatable {
        case applied(KnowledgeGraphGCReport)
        case previewDiverged(currentCandidates: [KnowledgeGraphGCCandidate])
    }
    let dataRoot: URL

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func previewOrphanSweep() async throws -> KnowledgeGraphGCReport {
        let (indexer, facts) = try await liveIndexerAndFacts()
        return try await indexer.collectGarbage(liveFacts: facts, apply: false)
    }

    /// Applies only when the candidate set is still exactly the one the user
    /// reviewed. A shrink can mean another writer fixed an item; a superset can
    /// contain a newly orphaned item the user never saw. Both require a new
    /// confirmation instead of silently broadening or narrowing deletion.
    func applyOrphanSweep(expectedCandidateIDs: Set<String>) async throws -> ApplyResult {
        let (indexer, facts) = try await liveIndexerAndFacts()
        let applied = try await indexer.collectGarbage(
            liveFacts: facts,
            apply: true,
            approvedOverThreshold: true,
            expectedCandidateIDs: expectedCandidateIDs
        )
        if applied.candidateSetDiverged {
            return .previewDiverged(currentCandidates: applied.candidates)
        }
        return .applied(applied)
    }

    private func liveIndexerAndFacts() async throws -> (SwiftNativeKnowledgeGraphIndexer, [KnowledgeGraphMemoryFact]) {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let memories = try await storage.listMemories(persona: nil, status: nil, limit: nil)
        let facts = memories.map {
            KnowledgeGraphMemoryFact(
                id: $0.id,
                content: $0.content,
                source: $0.source,
                status: $0.status,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                metadata: $0.projectionMetadata
            )
        }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        return (indexer, facts)
    }
}

/// Presentation-ready result of the explicit orphan-sweep preview. Keeping
/// the operation's error translation at the action boundary lets every UI
/// surface show the same concrete failure without depending on detached
/// SwiftUI `@State` storage.
enum KnowledgeGraphMaintenancePresentation {
    /// The complete visible state of the explicit sweep action. The view
    /// copies this state into SwiftUI storage; tests can observe the same
    /// result without constructing a detached view whose `@State` is inert.
    struct State: Equatable {
        let status: String?
        let candidates: [KnowledgeGraphGCCandidate]
        let candidateIDs: Set<String>
        let presentsConfirmation: Bool
        let errorMessage: String?
        let requiresGraphReload: Bool
    }

    enum PreviewOutcome: Equatable {
        case noCandidates
        case candidates([KnowledgeGraphGCCandidate])
        case failed(String)
    }

    enum ApplyOutcome: Equatable {
        case applied(KnowledgeGraphGCReport)
        case previewDiverged([KnowledgeGraphGCCandidate])
        case failed(String)
    }

    static func preview(
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> PreviewOutcome {
        do {
            let report = try await actions.previewOrphanSweep()
            return report.candidates.isEmpty
                ? .noCandidates
                : .candidates(report.candidates)
        } catch {
            return .failed("Orphan sweep failed: \(error.localizedDescription)")
        }
    }

    static func previewState(
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> State {
        switch await preview(actions: actions) {
        case .noCandidates:
            return State(
                status: "No orphaned entities.", candidates: [], candidateIDs: [],
                presentsConfirmation: false, errorMessage: nil, requiresGraphReload: false
            )
        case let .candidates(candidates):
            return State(
                status: nil, candidates: candidates, candidateIDs: Set(candidates.map(\.id)),
                presentsConfirmation: true, errorMessage: nil, requiresGraphReload: false
            )
        case let .failed(message):
            return State(
                status: nil, candidates: [], candidateIDs: [],
                presentsConfirmation: false, errorMessage: message, requiresGraphReload: false
            )
        }
    }

    static func apply(
        expectedCandidateIDs: Set<String>,
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> ApplyOutcome {
        do {
            switch try await actions.applyOrphanSweep(expectedCandidateIDs: expectedCandidateIDs) {
            case let .applied(report):
                return .applied(report)
            case let .previewDiverged(currentCandidates):
                return .previewDiverged(currentCandidates)
            }
        } catch {
            return .failed("Orphan sweep failed: \(error.localizedDescription)")
        }
    }

    static func applyState(
        expectedCandidateIDs: Set<String>,
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> State {
        switch await apply(expectedCandidateIDs: expectedCandidateIDs, actions: actions) {
        case let .applied(report):
            return State(
                status: "Removed \(report.entitiesDeleted) entities · \(report.edgesDeleted) edges.",
                candidates: [], candidateIDs: [], presentsConfirmation: false,
                errorMessage: nil, requiresGraphReload: true
            )
        case let .previewDiverged(candidates):
            return State(
                status: nil, candidates: candidates, candidateIDs: Set(candidates.map(\.id)),
                presentsConfirmation: true,
                errorMessage: "Orphan set changed before deletion. Review the updated candidates and confirm again.",
                requiresGraphReload: false
            )
        case let .failed(message):
            return State(
                status: nil, candidates: [], candidateIDs: [],
                presentsConfirmation: false, errorMessage: message, requiresGraphReload: false
            )
        }
    }
}
