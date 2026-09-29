import Foundation
import PersistenceCore

/// Revalidates the canonical evidence before installing the immutable manifest
/// and replaceable pointer. Approval binding is supplied by ApprovalTransactions.
public enum ProcedureExactActivationExecutor {
    public static func activate(
        proposal: ProcedureExactActivationProposal,
        dataRoot: URL,
        evidenceMatches: @Sendable (DeclarativeProcedureArtifact) async -> Bool,
        reviewerDecision: @Sendable () async throws -> ProcedureExactActivationReviewerDecision
    ) async throws -> ProcedureExactActivationManifest {
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        let artifact = try await store.load(proposal.artifactID)
        guard await evidenceMatches(artifact) else {
            throw ProcedureExactActivationError.activationBindingMismatch
        }
        let decision = try await reviewerDecision()
        let manifest = try await store.installAndActivateExact(
                proposal: proposal,
                reviewerDecision: decision
            )
        return manifest
    }
}
