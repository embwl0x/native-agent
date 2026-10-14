// B2.4 (prerelease campaign): the Cognition Observatory's Standing Views and
// Schema Proposals panels moved OUT of the observatory and onto Activity.
// Standing Views remain the only actionable cognition proposals here. Schema
// rows are read-only lineage from the canonical Dream/REM approval path.
//
// This view loads its own observatory detail and subscribes to the cognition
// change stream so an approve/reject (or a background reflection producing a new
// proposal) reflects live, exactly as the observatory did.

import Cognition
import SwiftUI
import Observation
import CognitiveSubstrate

// MARK: - Feed loader (Today's standing-views count)

// MARK: - Full destination view (Today ▸ Standing views)

struct CognitionProposalsView: View {
    @Environment(AppModel.self) private var appModel
    private var cognition: CognitionViewFacade { appModel.engine.cognitionView }
    private var detail: CognitiveObservatoryDetail? {
        get { cognition.proposalsDetail }
        nonmutating set { cognition.proposalsDetail = newValue }
    }
    @State private var reviewError: String?

    // Retired views never render; the observatory applied the same filter so the
    // count and body can't disagree.
    private var visibleStandingViews: [CognitiveStandingView] {
        (detail?.standingViews ?? []).filter { $0.status != .retired }
    }

    private var schemaProposals: [CognitiveSchemaProposal] {
        detail?.schemaProposals ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                if let reviewError {
                    Label(reviewError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Standing views from \(appModel.agentDisplayName)'s reflection wait for your call here. Replay schemas below are read-only lineage from the canonical Dream/REM approval path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NativePanel(title: "\(appModel.agentDisplayName)'s Standing Views", systemImage: "eye", tint: .purple) {
                    standingViews(visibleStandingViews)
                }

                NativePanel(title: "REM Replay Lineage", systemImage: "point.3.connected.trianglepath.dotted", tint: .green) {
                    schemaProposalsBody(schemaProposals)
                }
            }
            .padding(NativeAgentSpacing.xl)
        }
        .navigationTitle("Cognition Proposals")
        .task {
            let changes = await cognition.changes()
            await refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func refresh() async {
        await cognition.refreshProposals()
    }

    // MARK: Standing views (moved from CognitionObservatoryView+Proposals)

    @ViewBuilder
    private func standingViews(_ visibleViews: [CognitiveStandingView]) -> some View {
        if visibleViews.isEmpty {
            Text("No standing views yet — reflection proposes them as they settle.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                // Pending first: actionable rows come first.
                //
                // 2026-09-06: the `prefix(8)` cap is gone. The substrate keeps
                // more standing views than that, and this screen is the ONLY
                // place they can be approved or retired — anything past the
                // eighth row was simply invisible, with no expander and no
                // count to say rows were being withheld. The page already
                // scrolls; a long list is a long list.
                ForEach(visibleViews.filter { $0.status == .proposed } + visibleViews.filter { $0.status != .proposed }, id: \.id) { view in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(view.body)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text(CognitionProposalPresentation.standingViewStatus(view))
                                .font(.caption2)
                                .foregroundStyle(view.status == .active ? Color.purple : .secondary)
                        }
                        Spacer()
                        ForEach(
                            CognitionSurfaceDispositionPresentation.standingViewActions(
                                isPending: view.status == .proposed,
                                isLeaning: view.isLeaning
                            ),
                            id: \.self
                        ) { action in
                            Button(action.title, systemImage: action.systemImage) {
                                Task {
                                    guard let runtime = cognition.runtime else { return }
                                    let result = action == .retire
                                        ? await runtime.retireStandingViewWithOutcome(id: view.id)
                                        : await runtime.resolveStandingViewWithOutcome(
                                            id: view.id,
                                            approved: action.approved
                                        )
                                    detail = result.detail
                                    reportReview(result.status, action: action.title)
                                }
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: Read-only Dream/REM schema lineage

    @ViewBuilder
    private func schemaProposalsBody(_ proposals: [CognitiveSchemaProposal]) -> some View {
        if proposals.isEmpty {
            Text("No schema proposals from replay.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                // 2026-09-06: uncapped for the same reason the standing-view
                // list above is — the eight-row cap had no expander and no
                // count, so every schema proposal past the eighth was simply
                // invisible on the only screen that shows them. The page
                // scrolls.
                ForEach(proposals.filter { $0.status == .proposed } + proposals.filter { $0.status != .proposed }, id: \.id) { proposal in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.title)
                                .font(.caption.weight(.semibold))
                            Text(proposal.body)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("\(proposal.status.rawValue), \(proposal.target), confidence \(String(format: "%.2f", proposal.confidence))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                }
            }
        }
    }

    private func reportReview(_ status: NativeCognitionRuntime.StandingViewReviewStatus, action: String) {
        switch status {
        case .applied:
            reviewError = nil
            appModel.systemToasts.push(success: "\(action) standing view saved.")
        case .unavailable(let message):
            reviewError = "\(action) not applied: \(message)"
            appModel.systemToasts.push(error: reviewError ?? message)
        case .notSaved(let detail):
            reviewError = "\(action) was not saved: \(detail)"
            appModel.systemToasts.push(error: reviewError ?? detail)
        }
    }
}

enum CognitionProposalPresentation {
    static func standingViewStatus(_ view: CognitiveStandingView) -> String {
        switch view.status {
        case .active:
            // Phase 5 D: independent occurrences, not nodes re-reading dragged along.
            return "active lens since \(view.updatedAt.formatted(date: .abbreviated, time: .omitted)) — \(view.independentOccurrenceCount) independent occurrence(s)"
        case .held:
            // Named for what it IS: the agent's, unsigned, and yours to end.
            return "held by \(AgentVoice.live.object) since \(view.updatedAt.formatted(date: .abbreviated, time: .omitted)) — no signature needed, retire any time"
        case .retired:
            return "retired"
        case .proposed:
            return "proposed — waiting for your call"
        case .opinion:
            // Phase 5 D1: formed on independent recurrence, with its reasons. Hers.
            return "\(AgentVoice.live.possessive) opinion — because \(view.because)"
        case .interest:
            return "\(AgentVoice.live.possessive) interest — fades unless revisited"
        }
    }

}

enum CognitionSurfaceDispositionPresentation {
    enum StandingViewAction: String, CaseIterable, Hashable, Sendable {
        case approve
        case reject
        /// The way OUT of a view she is already leaning on — active or held.
        /// Not `reject`: rejecting is a verdict on a proposal, retiring is
        /// ending something she has been living with, and the timeline records
        /// them as the different facts they are.
        case retire

        var title: String {
            switch self {
            case .approve: "Approve"
            case .reject: "Reject"
            case .retire: "Retire"
            }
        }

        var approved: Bool { self == .approve }

        var systemImage: String {
            switch self {
            case .approve: "checkmark"
            case .reject: "xmark"
            case .retire: "archivebox"
            }
        }
    }


    /// Pending views get the review pair; a view she is already leaning on
    /// (active or held) gets the one control that was missing until 2026-09-02.
    static func standingViewActions(isPending: Bool, isLeaning: Bool = false) -> [StandingViewAction] {
        if isPending { return [.approve, .reject] }
        return isLeaning ? [.retire] : []
    }
}
