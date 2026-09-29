import SwiftUI

/// The iOS self-improvement screen is intentionally observational. Keeping
/// this copy as a named presentation contract prevents its only authority cue
/// from disappearing during a visual-only edit to the footer.
enum AutonomyMacOnlyNoticePresentation {
    static let message = "Applying training changes and approving learned behavior happen only on your Mac."
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
    @EnvironmentObject private var pairingStore: PairingStore
    @ObservedObject private var sync = iCloudSyncEngine.shared

    private var trainingProposals: [TrainingProposalSummary] {
        MobileDesignSamples.rows(sync.trainingProposals)
    }

    private var promotionCandidates: [PromotionCandidateSummary] {
        #if DEBUG
        if MobileDesignSamples.screen != nil, sync.promotionCandidates.isEmpty { return AutonomyDesignSample.candidates }
        #endif
        return sync.promotionCandidates
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
        AlivePage(title: "Self-Improvement", line: "Changes I’ve proposed to how I work.",
                 freshnessGroup: "training_proposals") {
            switch screenState {
            case .awaitingPublication:
                AliveCalmState(title: "Waiting for the Mac", line: screenState.detail)
            case .clear where trainingProposals.isEmpty && promotionCandidates.isEmpty:
                AliveCalmState(
                    title: "Nothing to review",
                    line: "When I propose a change to how I work, or want to keep something I learned, it shows up here."
                )
            default:
                if case .awaitingReview(let count) = screenState {
                    HStack(spacing: 8) {
                        AliveStatusDot(state: .here).scaleEffect(0.75)
                        Text(count == 1 ? "1 waiting on you" : "\(count) waiting on you")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AlivePalette.text)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, -12)
                    .accessibilityElement(children: .combine)
                }

                if !trainingProposals.isEmpty {
                    AliveSection("Proposed changes") {
                        ForEach(Array(trainingProposals.enumerated()), id: \.element.id) { index, proposal in
                            if index > 0 { AliveDivider() }
                            TrainingProposalRow(proposal: proposal)
                        }
                    }
                }

                if !promotionCandidates.isEmpty {
                    AliveSection("Things I learned",
                                 footer: pairingStore.isPaired ? nil : AliveConnection.pairToChange + ".") {
                        ForEach(Array(promotionCandidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { AliveDivider() }
                            PromotionCandidateRow(candidate: candidate)
                        }
                    }
                }
            }

            AliveFootnote(
                AutonomyMacOnlyNoticePresentation.message,
                systemImage: AutonomyMacOnlyNoticePresentation.systemImage
            )
        }
        .macSyncErrorBanner()
        .refreshable { await sync.refreshActivitySnapshot() }
        .task { await sync.refreshActivitySnapshot() }
    }
}

#if DEBUG
/// `-designScreen autonomy`: one learned behaviour waiting on a decision.
private enum AutonomyDesignSample {
    static let candidates: [PromotionCandidateSummary] = try! JSONDecoder().decode(
        [PromotionCandidateSummary].self,
        from: Data(#"[{"id":"design-promotion","title":"Offer a short recap after long research threads","status":"pending","decision":"STAGE_FOR_HUMAN","source":"conversation_review","score":0.82}]"#.utf8)
    )
}
#endif

enum PromotionCandidateDecisionPresentation {
    static func controlsAllowed(isHumanActionable: Bool) -> Bool {
        isHumanActionable
    }
}

private struct TrainingProposalRow: View {
    let proposal: TrainingProposalSummary

    /// Status, where it lands and what kind, as one line of words.
    private var statusLine: String {
        var parts = [AliveWords.humanized(proposal.status.lowercased())]
        if let target = proposal.targetDoc, !target.isEmpty { parts.append("for \(target)") }
        if let kind = proposal.kind, !kind.isEmpty { parts.append(AliveWords.humanized(kind).lowercased()) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(proposal.title)
                .font(.body.weight(.medium))
                .foregroundStyle(AlivePalette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let proposed = proposal.proposed, !proposed.isEmpty {
                Text(proposed)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rationale = proposal.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
                .padding(.top, 2)
        }
        .aliveRow()
    }
}

private struct PromotionCandidateRow: View {
    @EnvironmentObject private var pairingStore: PairingStore
    let candidate: PromotionCandidateSummary
    @State private var isDeciding = false
    @State private var decisionError: String?

    /// Status, where it came from and how sure I am, as one line of words.
    private var statusLine: String {
        var parts = [AliveWords.humanized(candidate.status.lowercased())]
        if let source = candidate.source, !source.isEmpty { parts.append("from \(AliveWords.humanized(source).lowercased())") }
        if let score = candidate.score { parts.append("\(Int((score * 100).rounded()))% sure") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(candidate.title)
                .font(.body.weight(.medium))
                .foregroundStyle(AlivePalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
            if PromotionCandidateDecisionPresentation.controlsAllowed(
                isHumanActionable: candidate.isHumanActionable
            ) {
                HStack(spacing: 10) {
                    Button("Approve") {
                        decide(approve: true)
                    }
                    .alivePrimaryButton()
                    .disabled(isDeciding)
                    Button("Reject") {
                        decide(approve: false)
                    }
                    .aliveSecondaryButton()
                    .disabled(isDeciding)
                    if isDeciding { ProgressView().controlSize(.small) }
                }
                .aliveUnavailable(!pairingStore.isPaired)
                .padding(.top, 6)
                if let decisionError {
                    Text(decisionError)
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .aliveRow()
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
