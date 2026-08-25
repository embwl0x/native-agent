import Foundation
import CognitiveSubstrate
import NativeAgentShared
import PersistenceCore

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

    static func run(
        appModel: AppModel,
        dataRoot: URL,
        approvalsOverride: (() async throws -> [ApprovalRequest])? = nil
    ) async -> Outcome {
        let organism = await NativeCognitionRuntime.shared.organismSnapshot()
        var failedEndpoints: [String] = []
        let deskItems: [DeskItem]
        do {
            deskItems = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items
        } catch {
            deskItems = []
            failedEndpoints.append("Desk")
        }
        let activeDeskCount = deskItems.filter { !$0.status.isTerminal }.count
        let blockedDeskCount = deskItems.filter { $0.status == .blocked }.count
        let ownerDecisionDeskCount = LivingAttentionPolicy.ownerDecisionDeskCount(in: deskItems)

        let dreamDiary = await appModel.fetchDreamDiary(limit: 1)
        if dreamDiary == nil { failedEndpoints.append("Dream diary") }
        let latestDream = dreamDiary?.entries.first

        let approvalRows: [ApprovalRequest]
        do {
            if let approvalsOverride {
                approvalRows = try await approvalsOverride()
            } else {
                approvalRows = try await appModel.getApprovals()
            }
        } catch {
            approvalRows = []
            failedEndpoints.append("Approvals")
        }

        guard failedEndpoints.isEmpty else {
            return Outcome(snapshot: nil, failedEndpoints: failedEndpoints)
        }
        let pendingApprovals = approvalRows.filter { $0.status.lowercased() == "pending" }.count
        let requiredApprovals = LivingAttentionPolicy.requiredApprovalCount(in: approvalRows)
        return Outcome(
            snapshot: LivingStatusSnapshot.make(
                organism: organism,
                activeDeskCount: activeDeskCount,
                blockedDeskCount: blockedDeskCount,
                ownerDecisionDeskCount: ownerDecisionDeskCount,
                pendingApprovals: pendingApprovals,
                requiredApprovals: requiredApprovals,
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
