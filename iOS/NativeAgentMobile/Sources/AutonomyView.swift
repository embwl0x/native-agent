import SwiftUI

/// Training changes are applied on the Mac.
enum AutonomyMacOnlyNoticePresentation {
    static let message = "Applying training changes happens only on your Mac."
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
                return "Training proposals have not published to this iPhone yet."
            case .clear:
                return "The Mac published its training proposals, and none has a human action waiting."
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


/// iPhone's Self-Improvement drilldown.
///
/// The old screen owned a second store and polled three snapshot files the
/// Mac never produced, so Activity linked to a permanently empty projection.
/// Activity and the tab badge already use iCloudSyncEngine's canonical
/// training projection; this view now reads that same resident
/// state and relies on the engine's KVS/push/foreground refresh owner.
struct AutonomyView: View {
    private let sync = iCloudSyncEngine.shared

    private var trainingProposals: [TrainingProposalSummary] {
        MobileDesignSamples.rows(sync.trainingProposals)
    }

    private var actionableCount: Int {
        trainingProposals.filter(\.isHumanActionable).count
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
            case .clear where trainingProposals.isEmpty:
                AliveCalmState(
                    title: "Nothing to review",
                    line: "When I propose a change to how I work, it shows up here."
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
