import ApprovalInbox
import SelfImprovement

extension ApprovalTransactionCoordinator {
    public static func reconcileUnappliedSelfEvolution(
        deps: SelfEvolutionApprovalExecutor.SelfEvolutionDeps
    ) async {
        let resolved = await resolvedApprovalsForReconciliation(dataRoot: deps.dataRoot)
        await SelfEvolutionApprovalExecutor.reconcileUnappliedSelfEvolution(
            deps: deps, resolvedApprovals: resolved)
    }
}
