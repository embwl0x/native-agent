import SwiftUI

/// The iOS self-improvement screen is intentionally observational. Keeping
/// this copy as a named presentation contract prevents its only authority cue
/// from disappearing during a visual-only edit to the footer.
enum AutonomyMacOnlyNoticePresentation {
    static let message = "Applying training changes and approving learned behavior remain local-admin actions on the Mac."
    static let systemImage = "lock.circle"
}

enum AutonomyScreenPresentation {
    enum State: Equatable {
        case awaitingPublication
        case clear
        case awaitingReview(Int)

        var tint: Color {
            switch self {
            case .awaitingPublication: return .orange
            case .clear: return .green
            case .awaitingReview: return .pink
            }
        }

        var title: String {
            switch self {
            case .awaitingPublication: return "Waiting for the Mac snapshot"
            case .clear: return "Nothing needs review"
            case let .awaitingReview(count): return "\(count) awaiting review"
            }
        }

        var detail: String {
            switch self {
            case .awaitingPublication:
                return "Training and promotion projections have not both published to this iPhone yet."
            case .clear:
                return "The Mac published both self-improvement projections, and neither has a human action waiting."
            case .awaitingReview:
                return "These are the same proposals shown in Activity and synced from the Mac's canonical stores."
            }
        }
    }

    static func state(actionableCount: Int, publishedAt: Date?) -> State {
        guard publishedAt != nil else { return .awaitingPublication }
        return actionableCount == 0 ? .clear : .awaitingReview(actionableCount)
    }
}

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
        MobileDesignSamples.rows(sync.trainingProposals)
    }

    private var promotionCandidates: [PromotionCandidateSummary] {
        sync.promotionCandidates
    }

    private var actionableCount: Int {
        trainingProposals.filter(\.isHumanActionable).count
            + promotionCandidates.filter(\.isHumanActionable).count
    }

    private var screenState: AutonomyScreenPresentation.State {
        AutonomyScreenPresentation.state(
            actionableCount: actionableCount,
            publishedAt: sync.selfImprovementSnapshotPublishedAt ?? (MobileDesignSamples.screen == nil ? nil : Date())
        )
    }

    var body: some View {
        List {
            Section {
                MobileReadingSurface {
                    MobileAdaptiveRow(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(screenState.title)
                                .font(.headline)
                            Text(screenState.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if screenState != .awaitingPublication, !trainingProposals.isEmpty {
                Section("Training Proposals") {
                    ForEach(trainingProposals) { proposal in
                        TrainingProposalRow(proposal: proposal)
                    }
                }
            }

            if screenState != .awaitingPublication, !promotionCandidates.isEmpty {
                Section("Promotion Candidates") {
                    ForEach(promotionCandidates) { candidate in
                        PromotionCandidateRow(candidate: candidate)
                    }
                }
            }

            if screenState == .clear, trainingProposals.isEmpty && promotionCandidates.isEmpty {
                Section {
                    MobileReadingEmptyState(
                        title: "No Self-Improvement Proposals",
                        systemImage: "wand.and.stars",
                        kind: .empty,
                        description: "\(sync.agentDisplayName)'s training proposals and learned-behavior promotion candidates will appear here when the Mac publishes them."
                    )
                    .frame(minHeight: 200)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                Label(
                    AutonomyMacOnlyNoticePresentation.message,
                    systemImage: AutonomyMacOnlyNoticePresentation.systemImage
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .mobileReadingScreen()
        .navigationTitle("Self-Improvement")
        .macSyncErrorBanner()
        // E6: freshness of the Mac snapshot behind this list.
        .macSnapshotFreshnessBadge(group: "training_proposals")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.refreshActivitySnapshot() }
        .task { await sync.refreshActivitySnapshot() }
    }
}

enum PromotionCandidateDecisionPresentation {
    static func controlsAllowed(isHumanActionable: Bool) -> Bool {
        isHumanActionable
    }
}

private struct TrainingProposalRow: View {
    let proposal: TrainingProposalSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MobileAdaptiveRow(alignment: .firstTextBaseline) {
                Text(proposal.targetDoc ?? proposal.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                StatusBadge(status: proposal.status)
            }
            if let proposed = proposal.proposed, !proposed.isEmpty {
                Text(proposed)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rationale = proposal.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let kind = proposal.kind, !kind.isEmpty {
                Label(kind.replacingOccurrences(of: "_", with: " "), systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct PromotionCandidateRow: View {
    let candidate: PromotionCandidateSummary
    @State private var isDeciding = false
    @State private var decisionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MobileAdaptiveRow(alignment: .firstTextBaseline) {
                Text(candidate.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                StatusBadge(status: candidate.status)
            }
            MobileAdaptiveRow(spacing: 12) {
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
            .font(.caption)
            .foregroundStyle(.secondary)
            if PromotionCandidateDecisionPresentation.controlsAllowed(
                isHumanActionable: candidate.isHumanActionable
            ) {
                MobileAdaptiveRow {
                    Button("Approve", systemImage: "checkmark") {
                        decide(approve: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDeciding)
                    Button("Reject", systemImage: "xmark") {
                        decide(approve: false)
                    }
                    .buttonStyle(.bordered)
                .tint(.secondary)
                    .tint(NativeAgentMobileTheme.Colors.accentText)
                    .disabled(isDeciding)
                    if isDeciding { ProgressView() }
                }
                if let decisionError {
                    Text(decisionError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func decide(approve: Bool) {
        isDeciding = true
        decisionError = nil
        Task {
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approvePromotion(candidateId: candidate.id)
                } else {
                    _ = try await iCloudSyncEngine.shared.rejectPromotion(candidateId: candidate.id)
                }
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                decisionError = error.localizedDescription
            }
            isDeciding = false
        }
    }
}
