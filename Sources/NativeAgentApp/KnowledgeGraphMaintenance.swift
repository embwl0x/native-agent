import EngineRuntime
import MemoryV2
import SwiftUI
import AppKit
import Foundation
import Combine
import Cognition
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `KnowledgeGraphMaintenance.swift` | Knowledge Graph orphan preview and reviewed deletion presentation; canonical maintenance actions require the exact candidate set |

/// Converts the canonical orphan-sweep result into visible state.
enum KnowledgeGraphMaintenancePresentation {
    struct State: Equatable {
        let status: String?
        let candidates: [KnowledgeGraphGCCandidate]
        let candidateIDs: Set<String>
        let presentsConfirmation: Bool
        let errorMessage: String?
        let requiresGraphReload: Bool
    }

    static func previewState(
        actions: KnowledgeGraphMaintenanceActions
    ) async -> State {
        do {
            let candidates = try await actions.previewOrphanSweep().candidates
            return State(
                status: candidates.isEmpty ? "No orphaned entities." : nil,
                candidates: candidates, candidateIDs: Set(candidates.map(\.id)),
                presentsConfirmation: !candidates.isEmpty, errorMessage: nil, requiresGraphReload: false
            )
        } catch {
            return State(
                status: nil, candidates: [], candidateIDs: [],
                presentsConfirmation: false,
                errorMessage: UserFacingError.message(error, action: "sweep orphaned entities"),
                requiresGraphReload: false
            )
        }
    }

    static func applyState(
        expectedCandidateIDs: Set<String>,
        actions: KnowledgeGraphMaintenanceActions
    ) async -> State {
        do {
            switch try await actions.applyOrphanSweep(expectedCandidateIDs: expectedCandidateIDs) {
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
            }
        } catch {
            return State(
                status: nil, candidates: [], candidateIDs: [],
                presentsConfirmation: false,
                errorMessage: UserFacingError.message(error, action: "sweep orphaned entities"),
                requiresGraphReload: false
            )
        }
    }
}

extension KnowledgeGraphView {
    // GC sweep: dry-run preview, then user-confirmed apply on this engine.

    func previewGCSweep() async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        applyGCSweepPresentation(
            await KnowledgeGraphMaintenancePresentation.previewState(actions: .init(dataRoot: appModel.engine.dataRoot))
        )
    }

    func applyGCSweep() async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        let presentation = await KnowledgeGraphMaintenancePresentation.applyState(
            expectedCandidateIDs: gcPreviewCandidateIDs,
            actions: .init(dataRoot: appModel.engine.dataRoot)
        )
        applyGCSweepPresentation(presentation)
        if presentation.requiresGraphReload {
            await loadGraph()
        }
    }

    private func applyGCSweepPresentation(
        _ presentation: KnowledgeGraphMaintenancePresentation.State
    ) {
        gcStatus = presentation.status
        gcCandidates = presentation.candidates
        gcPreviewCandidateIDs = presentation.candidateIDs
        showGCConfirm = presentation.presentsConfirmation
        errorMsg = presentation.errorMessage
        errorOrigin = presentation.errorMessage == nil ? nil : .maintenance
    }
}
