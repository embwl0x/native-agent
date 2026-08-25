import Foundation

extension KnowledgeGraphView {
    /// Policy authority is read separately from graph contents so unreadable
    /// bytes cannot leave the mounted page indefinitely saying "Checking".
    /// The enable action remains unavailable until this checked read succeeds.
    func loadKnowledgeGraphPolicy() async -> Bool {
        if appModel.trustPolicy != nil {
            policyReadError = nil
            return true
        }
        do {
            appModel.trustPolicy = try await appModel.getTrustPolicy()
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
        loading = true; defer { loading = false }
        // ui-honesty 2026-06-10: clear the previous error at the start of
        // every load — a stale failure message used to persist over a
        // subsequent successful refresh.
        errorMsg = nil
        errorOrigin = nil
        do {
            // PATCH-2026-05-15: paginate through ALL pages. Previously only
            // page 0 was fetched, so the sidebar capped at one page (~100)
            // while the footer showed the true total (e.g. 887) and the
            // rest were unreachable. Termination is server-authoritative
            // (total_entities) with an empty-page break + hard page cap so
            // it can never loop forever regardless of server page size.
            var all: [KGEntity] = []
            var allEdges: [KGEdge] = []
            var seenEdgeKeys = Set<String>()
            var total = 0
            var totEdges: Int? = nil
            let maxPages = 500  // hard safety bound
            var page = 0
            while page < maxPages {
                let resp = try await api.getKnowledgeGraph(page: page)
                if page == 0 {
                    total = resp.totalEntities
                    totEdges = resp.totalEdges
                }
                if resp.entities.isEmpty { break }
                all.append(contentsOf: resp.entities)
                // F3: pages return scoped edges (touching only that page's entities),
                // so the same edge can appear on multiple pages — dedupe by from/to/kind.
                for edge in resp.edges ?? [] where seenEdgeKeys.insert(edge.id).inserted {
                    allEdges.append(edge)
                }
                if total > 0 && all.count >= total { break }
                page += 1
            }
            entities = all
            edges = allEdges
            totalEntities = total > 0 ? total : all.count
            totalEdges = totEdges
            errorOrigin = nil
        } catch {
            // U5 W-C fix-round: keep whatever loaded previously (the banner
            // marks it stale) — but the error is rendered FIRST, never under
            // a fabricated healthy empty state.
            errorMsg = error.localizedDescription
            errorOrigin = .graphLoad
        }
    }

    func enableKnowledgeGraph() async {
        guard !isEnablingGraph else { return }
        isEnablingGraph = true
        defer { isEnablingGraph = false }
        enableActionPresentation = .enabling
        errorMsg = nil
        errorOrigin = nil
        let outcome = await KnowledgeGraphEnableAction.perform(using: appModel)
        enableActionPresentation = outcome
        guard outcome == .enabled else { return }
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
