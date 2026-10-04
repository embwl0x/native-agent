import Foundation
import ApprovalInbox
import Cognition
import CognitiveSubstrate
import NativeAgentShared
import PersistenceCore
import Desk

/// The mounted Living Status refresh owns a complete snapshot: mixing one
/// fresh endpoint with guessed zeroes from another would fabricate a calm
/// state. This operation keeps the real reads together and returns an explicit
/// receipt when no replacement snapshot was admitted.
@MainActor
struct LivingStatusRefreshOperation {
    struct Outcome {
        let snapshot: LivingStatusSnapshot?
        let failedEndpoints: [String]

        /// A partial read is not a replacement snapshot. The mounted panel
        /// keeps its prior identity and pairs it with the adverse receipt.
        func applying(to previous: LivingStatusSnapshot?) -> LivingStatusSnapshot? {
            snapshot ?? previous
        }

        @MainActor
        func status(previous: AppModel.PanelRefreshStatus?, at date: Date = Date()) -> AppModel.PanelRefreshStatus {
            AppModel.nextRefreshStatus(
                previous: previous,
                failedEndpoints: failedEndpoints,
                at: date
            )
        }
    }

    static func run(appModel: AppModel) async -> Outcome {
        guard let organism = await appModel.engine.cognitionView.organismSnapshot() else {
            return Outcome(snapshot: nil, failedEndpoints: ["Cognition"])
        }
        var failedEndpoints: [String] = []
        // The Desk's own overview: its Needs you is the one "needs User".
        let board = await appModel.engine.desk.loadBoard(includeOverview: true)
        let overview = board.overview!
        if !overview.unavailable.isEmpty { failedEndpoints.append("Desk") }
        let activeDeskCount = board.items.filter { !$0.status.isTerminal }.count
        let blockedDeskCount = board.items.filter { $0.status == .blocked }.count

        let dreamDiary = await appModel.fetchDreamDiary(limit: 1)
        if dreamDiary == nil { failedEndpoints.append("Dream diary") }
        let latestDream = dreamDiary?.entries.first

        let approvalRows: [ApprovalRecord]
        do {
            approvalRows = try await appModel.engine.approvals.list()
        } catch {
            approvalRows = []
            failedEndpoints.append("Approvals")
        }

        guard failedEndpoints.isEmpty else {
            return Outcome(snapshot: nil, failedEndpoints: failedEndpoints)
        }
        return Outcome(
            snapshot: LivingStatusSnapshot.make(
                organism: organism,
                activeDeskCount: activeDeskCount,
                blockedDeskCount: blockedDeskCount,
                ownerWaiting: overview.needsYouCount,
                pendingApprovals: approvalRows.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status) }.count,
                latestDream: latestDream,
                agentDisplayName: appModel.agentDisplayName
            ),
            failedEndpoints: []
        )
    }
}

/// A completed refresh is not silent: an unavailable read and retained last
/// known snapshot each have distinct, user-visible feedback.
enum LivingStatusRefreshPresentation: Equatable {
    case loading
    case current
    case retainedFailure
    case unavailable
    case empty

    static func resolve(
        hasSnapshot: Bool,
        status: AppModel.PanelRefreshStatus?
    ) -> Self {
        if status?.isStale == true { return hasSnapshot ? .retainedFailure : .unavailable }
        guard status != nil else { return .loading }
        return hasSnapshot ? .current : .empty
    }

    var adverseMessage: String? {
        switch self {
        case .retainedFailure:
            return "Refresh couldn't complete — showing the last known state."
        case .unavailable:
            return "Refresh couldn't complete — current state is unavailable; no calm or needs-nothing state was inferred."
        case .empty:
            return "Refresh completed, but no current state was available."
        case .loading, .current:
            return nil
        }
    }
}
