// B2.4 (prerelease campaign): the Cognition Observatory's two APPROVAL-shaped
// panels — Standing Views and Schema Proposals — moved OUT of the observatory
// (a read-only surface after the split) and onto the Activity surface, which is
// the app's single "needs your eyes" landing. The rendering is a move (not a
// rewrite) of the former `CognitionObservatoryView.standingViews(_:)` /
// `.schemaProposals(_:)` builders; the resolve wiring is unchanged.
//
// This view loads its own observatory detail and subscribes to the cognition
// change stream so an approve/reject (or a background reflection producing a new
// proposal) reflects live, exactly as the observatory did.

import SwiftUI
import CognitiveSubstrate

// MARK: - Feed loader (shared with ActivityView's inline preview)

enum CognitionProposalsFeed {
    struct Pending: Sendable, Equatable {
        var standingViews: [CognitiveStandingView] = []
        var schemaProposals: [CognitiveSchemaProposal] = []
        var count: Int { standingViews.count + schemaProposals.count }
    }

    /// Proposed-only, the actionable "needs your eyes" set that drives the
    /// Activity row count and inline previews.
    static func pending() async -> Pending {
        let detail = await NativeCognitionRuntime.shared.observatoryDetail()
        return Pending(
            standingViews: detail.standingViews.filter { $0.status == .proposed },
            schemaProposals: detail.schemaProposals.filter { $0.status == .proposed }
        )
    }
}

// MARK: - Full destination view (Activity ▸ Cognition Proposals)

struct CognitionProposalsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var detail: CognitiveObservatoryDetail?

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
                Text("Proposals from \(appModel.agentDisplayName)'s reflection wait for your call here. Approving a standing view lets it start coloring her appraisals; approving a schema proposal applies it to her association model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NativePanel(title: "\(appModel.agentDisplayName)'s Standing Views", systemImage: "eye", tint: .purple) {
                    standingViews(visibleStandingViews)
                }

                NativePanel(title: "Schema Proposals", systemImage: "point.3.connected.trianglepath.dotted", tint: .green) {
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
                            Text(view.status == .active
                                ? "active lens since \(view.updatedAt.formatted(date: .abbreviated, time: .omitted)) — \(view.evidenceNodeIds.count) felt moments, conviction \(Int(min(1.0, 0.5 + 0.1 * Double(view.evidenceNodeIds.count)) * 100))%"
                                : "proposed — waiting for your call")
                                .font(.caption2)
                                .foregroundStyle(view.status == .active ? Color.purple : .secondary)
                        }
                        Spacer()
                        if view.status == .proposed {
                            Button("Approve", systemImage: "checkmark") {
                                Task {
                                    await NativeCognitionRuntime.shared.resolveStandingView(id: view.id, approved: true)
                                    await refresh()
                                }
                            }
                            Button("Reject", systemImage: "xmark") {
                                Task {
                                    await NativeCognitionRuntime.shared.resolveStandingView(id: view.id, approved: false)
                                    await refresh()
                                }
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: Schema proposals (moved from CognitionObservatoryView+Proposals)

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
                        if proposal.status == .proposed {
                            Button("Approve", systemImage: "checkmark") {
                                Task {
                                    await NativeCognitionRuntime.shared.resolveSchemaProposal(id: proposal.id, accepted: true)
                                    await refresh()
                                }
                            }
                            Button("Reject", systemImage: "xmark") {
                                Task {
                                    await NativeCognitionRuntime.shared.resolveSchemaProposal(id: proposal.id, accepted: false)
                                    await refresh()
                                }
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

// MARK: - Inline preview card (Activity landing page)

/// Compact approve/reject card matching the other Activity inline previews
/// (InlineApprovalPreviewCard etc.). Used for the top 1–2 pending cognition
/// proposals so a small queue doesn't force a drill-down.
struct InlineCognitionProposalCard: View {
    let title: String
    let subtitle: String
    // Taste pass 2026-07-24: schema-proposal titles are machine-generated
    // slugs; without the proposal body a user is asked to Approve/Reject
    // something they can't evaluate.
    var detail: String? = nil
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(NativeAgentFont.label)
                .lineLimit(3)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Approve", systemImage: "checkmark") { onApprove() }
                    .controlSize(.small)
                Button("Reject", systemImage: "xmark") { onReject() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
