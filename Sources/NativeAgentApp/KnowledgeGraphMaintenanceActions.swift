import Foundation
import KnowledgeGraph
import MemoryV2
import PersistenceCore

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
            return .failed(UserFacingError.message(error, action: "sweep orphaned entities"))
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
            return .failed(UserFacingError.message(error, action: "sweep orphaned entities"))
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
