// B2.4 (prerelease campaign): the Cognition Observatory's Standing Views and
// Schema Proposals panels moved OUT of the observatory and onto Activity.
// Standing Views remain the only actionable cognition proposals here. Schema
// rows are read-only lineage from the canonical Dream/REM approval path.
//
// This view loads its own observatory detail and subscribes to the cognition
// change stream so an approve/reject (or a background reflection producing a new
// proposal) reflects live, exactly as the observatory did.

import SwiftUI
import Observation
import CognitiveSubstrate

// MARK: - Feed loader (shared with ActivityView's inline preview)

enum CognitionProposalsFeed {
    struct Pending: Sendable, Equatable {
        var standingViews: [CognitiveStandingView] = []
        var schemaProposals: [CognitiveSchemaProposal] = []
        var count: Int { standingViews.count + schemaProposals.count }
    }

    enum Read: Sendable, Equatable {
        case available(Pending)
        case unavailable(String)

        var pending: Pending {
            guard case .available(let pending) = self else { return Pending() }
            return pending
        }
    }

    /// Proposed-only, the actionable "needs your eyes" set that drives the
    /// Activity row count and inline previews.
    static func pending() async -> Pending {
        await pending(runtime: .shared)
    }

    /// Keep the feed's filtering at its real runtime boundary.  The default
    /// remains the resident runtime; accepting a runtime makes an isolated
    /// cognition store testable without teaching the feed about test data or
    /// creating a second proposal representation.
    static func pending(runtime: NativeCognitionRuntime) async -> Pending {
        await read(runtime: runtime).pending
    }

    /// A disabled cognition runtime is not a successful empty proposal read.
    /// Activity uses this richer result for its live subscription while the
    /// legacy convenience method above keeps callers that only need a count
    /// source-compatible.
    static func read(runtime: NativeCognitionRuntime) async -> Read {
        let detail = await runtime.observatoryDetail()
        guard detail.configuration.enabled else {
            return .unavailable("Cognition proposals are unavailable while cognition is off.")
        }
        return .available(Pending(
            standingViews: detail.standingViews.filter { $0.status == .proposed },
            schemaProposals: []
        ))
    }
}

// MARK: - Full destination view (Activity ▸ Cognition Proposals)

struct CognitionProposalsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var detail: CognitiveObservatoryDetail?
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
            let changes = await NativeCognitionRuntime.shared.changes()
            await refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func refresh() async {
        detail = await NativeCognitionRuntime.shared.observatoryDetail()
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
                // Pending first: actionable rows must never hide behind the cap.
                ForEach(Array((visibleViews.filter { $0.status == .proposed } + visibleViews.filter { $0.status != .proposed }).prefix(8)), id: \.id) { view in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(view.body)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text(CognitionObservatoryPresentation.standingViewStatus(view))
                                .font(.caption2)
                                .foregroundStyle(view.status == .active ? Color.purple : .secondary)
                        }
                        Spacer()
                        ForEach(
                            CognitionSurfaceDispositionPresentation.standingViewActions(
                                isPending: view.status == .proposed
                            ),
                            id: \.self
                        ) { action in
                            Button(
                                action.title,
                                systemImage: action == .approve ? "checkmark" : "xmark"
                            ) {
                                Task {
                                    let result = await CognitionProposalActions.resolveWithOutcome(
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
                ForEach(Array((proposals.filter { $0.status == .proposed } + proposals.filter { $0.status != .proposed }).prefix(8)), id: \.id) { proposal in
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

    private func reportReview(_ status: CognitionProposalActions.ResolveStatus, action: String) {
        switch status {
        case .applied:
            reviewError = nil
            appModel.systemToasts.push(success: "\(action) standing view saved.")
        case .unavailable(let message):
            reviewError = "\(action) not applied: \(message)"
            appModel.systemToasts.push(error: reviewError ?? message)
        }
    }
}

// MARK: - Inline preview card (Activity landing page)

/// Compact approve/reject card matching the other Activity inline previews
/// (InlineApprovalPreviewCard etc.). Used for the top 1–2 pending cognition
/// proposals so a small queue doesn't force a drill-down.
@MainActor @Observable
final class InlineCognitionProposalCardActionState {
    enum Decision: Sendable, Equatable {
        case approve
        case reject
    }

    enum Feedback: Sendable, Equatable {
        case saved(String)
        case unavailable(String)

        var message: String {
            switch self {
            case .saved(let message), .unavailable(let message): return message
            }
        }

        var isError: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    private(set) var inFlight: Decision?
    private(set) var feedback: Feedback?

    var hasSavedDecision: Bool {
        guard case .saved = feedback else { return false }
        return true
    }

    var canResolve: Bool {
        inFlight == nil && !hasSavedDecision
    }

    func begin(_ decision: Decision) -> Bool {
        guard inFlight == nil else { return false }
        feedback = nil
        inFlight = decision
        return true
    }

    func settle(
        _ status: CognitionProposalActions.ResolveStatus,
        decision: Decision
    ) -> Feedback {
        defer { inFlight = nil }
        let result: Feedback
        switch status {
        case .applied:
            result = .saved(decision == .approve
                ? "Standing view approved and saved."
                : "Standing view rejected and retired.")
        case .unavailable(let detail):
            result = .unavailable("Standing-view review not applied: \(detail)")
        }
        feedback = result
        return result
    }
}

struct InlineCognitionProposalCard: View {
    let proposalID: UUID
    let title: String
    let subtitle: String
    // Taste pass 2026-07-24: schema-proposal titles are machine-generated
    // slugs; without the proposal body a user is asked to Approve/Reject
    // something they can't evaluate.
    let detail: String
    let onResolve: @MainActor (Bool) async -> CognitionProposalActions.ResolveStatus

    @State private var actionState = InlineCognitionProposalCardActionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(NativeAgentFont.label)
                .lineLimit(3)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let feedback = actionState.feedback {
                Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(feedback.isError ? Color.orange : Color.green)
                    .lineLimit(2)
                    .accessibilityIdentifier("activity.inlineDecisionActions.feedback.\(proposalID.uuidString)")
            }
            if actionState.inFlight != nil {
                Label("Saving decision…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("activity.inlineDecisionActions.inFlight.\(proposalID.uuidString)")
            }
            HStack(spacing: 8) {
                Button("Approve", systemImage: "checkmark") { resolve(.approve) }
                    .controlSize(.small)
                    .accessibilityIdentifier("activity.inlineDecisionActions.approve.\(proposalID.uuidString)")
                    .disabled(!actionState.canResolve)
                Button("Reject", systemImage: "xmark") { resolve(.reject) }
                    .controlSize(.small)
                    .accessibilityIdentifier("activity.inlineDecisionActions.reject.\(proposalID.uuidString)")
                    .disabled(!actionState.canResolve)
            }
        }
        .padding(.vertical, 4)
    }

    private func resolve(_ decision: InlineCognitionProposalCardActionState.Decision) {
        guard actionState.begin(decision) else { return }
        Task {
            let status = await onResolve(decision == .approve)
            actionState.settle(status, decision: decision)
        }
    }
}
