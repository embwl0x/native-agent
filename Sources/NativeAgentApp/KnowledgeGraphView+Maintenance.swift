import Foundation
import KnowledgeGraph
import MemoryV2

extension KnowledgeGraphView {
    /// Policy authority is read separately from graph contents so unreadable
    /// bytes cannot leave the mounted page indefinitely saying "Checking".
    /// The enable action remains unavailable until this checked read succeeds.
    func loadKnowledgeGraphPolicy() async -> Bool {
        if appModel.engine.trust.policy != nil {
            policyReadError = nil
            return true
        }
        do {
            appModel.engine.trust.policy = try await appModel.engine.trust.load()
            policyReadError = nil
            return true
        } catch {
            policyReadError = error.localizedDescription
            return false
        }
    }

    func reloadKnowledgeGraphPolicyAndGraph() async {
        guard await loadKnowledgeGraphPolicy() else { return }
        await loadGraph()
    }

    func loadGraph() async {
        guard !Task.isCancelled else { return }
        // ui-honesty 2026-06-10: clear the previous error at the start of
        // every load — a stale failure message used to persist over a
        // subsequent successful refresh.
        errorMsg = nil
        errorOrigin = nil
        // U5 W-C fix-round: a failed read keeps whatever loaded previously
        // (the banner marks it stale) — but the error is rendered FIRST,
        // never under a fabricated healthy empty state. The read's own error
        // lives on the shared graph (`shownError`).
        await memory.loadGraph()
        guard !Task.isCancelled, memory.graphLoadError == nil else { return }
        let status = await KGNativeStackStatus.load(graphCounts: (totalEntities, totalEdges ?? 0))
        guard !Task.isCancelled else { return }
        nativeStack = status
    }

    func enableKnowledgeGraph(enabled: Bool = true) async {
        guard !isEnablingGraph else { return }
        isEnablingGraph = true
        defer { isEnablingGraph = false }
        enableActionPresentation = enabled ? .enabling : .disabling
        errorMsg = nil
        errorOrigin = nil
        let outcome = await KnowledgeGraphEnableAction.perform(using: appModel, enabled: enabled)
        enableActionPresentation = outcome
        guard outcome == .enabled || outcome == .disabled else { return }
        await loadGraph()
    }

    // U5 W-C: GC sweep — dry-run preview, then user-confirmed apply.

    func previewGCSweep(actions: KnowledgeGraphMaintenanceActions = .init()) async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        applyGCSweepPresentation(
            await KnowledgeGraphMaintenancePresentation.previewState(actions: actions)
        )
    }

    func applyGCSweep(actions: KnowledgeGraphMaintenanceActions = .init()) async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        let presentation = await KnowledgeGraphMaintenancePresentation.applyState(
            expectedCandidateIDs: gcPreviewCandidateIDs,
            actions: actions
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
