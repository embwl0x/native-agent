import SwiftUI

/// iPhone's read-only Self-Improvement drilldown.
///
/// The old screen owned a second store and polled three snapshot files the
/// Mac never produced, so Activity linked to a permanently empty projection.
/// Activity and the tab badge already use iCloudSyncEngine's canonical
/// training/promotion projections; this view now reads that same resident
/// state and relies on the engine's KVS/push/foreground refresh owner.
struct AutonomyView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared

    private var trainingProposals: [TrainingProposalSummary] {
        sync.trainingProposals
    }

    private var promotionCandidates: [PromotionCandidateSummary] {
        sync.promotionCandidates
    }

    private var actionableCount: Int {
        trainingProposals.filter(\.isHumanActionable).count
            + promotionCandidates.filter(\.isHumanActionable).count
    }

    var body: some View {
        List {
            Section {
                GlassCard(tint: actionableCount == 0 ? .green : .pink) {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(actionableCount == 0 ? .green : .pink)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(actionableCount == 0 ? "Nothing needs review" : "\(actionableCount) awaiting review")
                                .font(AppFont.section)
                            Text("These are the same proposals shown in Activity and synced from the Mac's canonical stores.")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !trainingProposals.isEmpty {
                Section("Training Proposals") {
                    ForEach(trainingProposals) { proposal in
                        TrainingProposalRow(proposal: proposal)
                    }
                }
            }

            if !promotionCandidates.isEmpty {
                Section("Promotion Candidates") {
                    ForEach(promotionCandidates) { candidate in
                        PromotionCandidateRow(candidate: candidate)
                    }
                }
            }

            if trainingProposals.isEmpty && promotionCandidates.isEmpty {
                Section {
                    AppEmptyState(
                        title: "No Self-Improvement Proposals",
                        systemImage: "wand.and.stars",
                        description: "\(sync.agentDisplayName)'s training proposals and learned-behavior promotion candidates will appear here when the Mac publishes them."
                    )
                    .frame(height: 280)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                Label(
                    "Applying training changes and approving learned behavior remain local-admin actions on the Mac.",
                    systemImage: "lock.circle"
                )
                .font(AppFont.label)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Self-Improvement")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.refreshActivitySnapshot() }
    }
}

private struct TrainingProposalRow: View {
    let proposal: TrainingProposalSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(proposal.targetDoc ?? proposal.title)
                    .font(AppFont.section)
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(status: proposal.status)
            }
            if let proposed = proposal.proposed, !proposed.isEmpty {
                Text(proposed)
                    .font(AppFont.body)
                    .lineLimit(5)
            }
            if let rationale = proposal.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let kind = proposal.kind, !kind.isEmpty {
                Label(kind.replacingOccurrences(of: "_", with: " "), systemImage: "doc.text.magnifyingglass")
                    .font(AppFont.tag)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct PromotionCandidateRow: View {
    let candidate: PromotionCandidateSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.title)
                    .font(AppFont.section)
                    .lineLimit(3)
                Spacer(minLength: 8)
                StatusBadge(status: candidate.status)
            }
            HStack(spacing: 10) {
                if let source = candidate.source, !source.isEmpty {
                    Label(source.replacingOccurrences(of: "_", with: " "), systemImage: "arrow.triangle.branch")
                }
                if let score = candidate.score {
                    Label("\(Int((score * 100).rounded()))%", systemImage: "chart.bar.fill")
                }
                if let decision = candidate.decision, !decision.isEmpty {
                    Label(decision.replacingOccurrences(of: "_", with: " ").lowercased(), systemImage: "person.crop.circle.badge.questionmark")
                }
            }
            .font(AppFont.tag)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}
