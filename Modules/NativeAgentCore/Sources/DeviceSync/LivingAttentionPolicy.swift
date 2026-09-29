import ApprovalInbox
import CognitiveSubstrate
import PersistenceCore
import Desk

/// "Does she need User?" and "is her body in trouble?", as the Mac's living
/// status panel and the phone's living-status snapshot both read them.
public enum LivingAttentionPolicy {
    /// Useful review queues that do not block a user-requested action. They
    /// remain visible in Approvals without paging the owner as though an
    /// irreversible operation were waiting at a consent boundary.
    private static let optionalReviewActions: Set<String> = [
        "rem.proposal",
        "self_improvement.apply",
    ]

    /// Delegates to Core's `OwnerAttentionPolicy` — the single owner of
    /// "does she need User?". This surface and the Desk headline read the same
    /// rule, so they cannot answer differently in the same minute.
    public static func ownerDecisionDeskCount(in items: [DeskItem]) -> Int {
        OwnerAttentionPolicy.ownerDecisionCount(in: items)
    }

    public static func organismNeedsAttention(_ organism: OrganismSnapshot) -> Bool {
        guard organism.enabled else { return false }
        let body = organism.bodySchema
        return !body.providersHealthy
            || !body.toolHandsAvailable
            || !body.notificationPathHealthy
            || !body.iPhoneReachable
            || !body.memoryHealthy
            || !body.dreamHealthy
            || !body.approvalChannelsOpen
            || body.resourcePressure != .nominal
            || organism.reflexSummary.reviewRequiredCount > 0
    }

    public static func requiredApprovalCount(in rows: [ApprovalRecord]) -> Int {
        rows.filter { row in
            row.status.lowercased() == "pending"
                && !optionalReviewActions.contains(row.action.lowercased())
        }.count
    }

    public static func needsUser(requiredApprovals: Int, ownerDecisionDeskCount: Int) -> Bool {
        OwnerAttentionPolicy.needsOwner(
            approvalsWaiting: requiredApprovals,
            ownerDecisionItems: ownerDecisionDeskCount
        )
    }
}
