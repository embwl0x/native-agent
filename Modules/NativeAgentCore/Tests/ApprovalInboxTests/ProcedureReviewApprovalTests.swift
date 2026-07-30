import Foundation
import PersistenceCore
import Testing
@testable import ApprovalInbox

@Suite("Procedure review approval provenance")
struct ProcedureReviewApprovalTests {
    @Test("only exact resolved local candidate evidence mints reviewer decision")
    func exactLocalReview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_783_915_202)
        let inbox = SwiftNativeApprovalInbox(root: root, clock: { now })
        let proposal = ProcedureReviewProposal(
            candidateShapeIdentity: CausalTransitionEvidence.opaqueIdentity("shape"),
            candidateEvidenceDigest: CausalTransitionEvidence.opaqueIdentity("evidence"),
            productRole: .workshopFirstProduct,
            trajectoryCount: 12,
            scope: .manualAndCanary
        )
        let pending = try await inbox.stageProcedureReviewApproval(proposal)
        #expect(pending.localOnly)
        #expect(!pending.remoteResolvable)
        await #expect(throws: ProcedureReviewApprovalError.approvalNotApproved) {
            _ = try await inbox.approvedProcedureReviewerDecision(
                approvalID: pending.id,
                proposal: proposal
            )
        }
        _ = try await inbox.resolve(pending.id, decision: .approved, decidedBy: "local_user")
        let decision = try await inbox.approvedProcedureReviewerDecision(
            approvalID: pending.id,
            proposal: proposal
        )
        #expect(decision.verdict == .approve)
        #expect(decision.scope == .manualAndCanary)
        #expect(decision.candidateEvidenceDigest == proposal.candidateEvidenceDigest)
        #expect(decision.approvalReceiptIdentity == CausalTransitionEvidence.opaqueIdentity(pending.id))

        let changed = ProcedureReviewProposal(
            candidateShapeIdentity: proposal.candidateShapeIdentity,
            candidateEvidenceDigest: CausalTransitionEvidence.opaqueIdentity("changed"),
            productRole: .workshopFirstProduct,
            trajectoryCount: 12,
            scope: .manualAndCanary
        )
        await #expect(throws: ProcedureReviewApprovalError.approvalBindingMismatch) {
            _ = try await inbox.approvedProcedureReviewerDecision(
                approvalID: pending.id,
                proposal: changed
            )
        }
    }

    @Test("exact procedure activation binds local approval to implementation and evidence")
    func exactActivationReview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-activation-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_783_915_202)
        let inbox = SwiftNativeApprovalInbox(root: root, clock: { now })
        let proposal = ProcedureExactActivationProposal(
            artifactID: CausalTransitionEvidence.opaqueIdentity("artifact"),
            procedureShapeIdentity: CausalTransitionEvidence.opaqueIdentity("shape"),
            procedureID: "local_file_copy_v1",
            implementationIdentity: CausalTransitionEvidence.opaqueIdentity("implementation"),
            qualifyingInvocationIDs: (0..<12).map {
                CausalTransitionEvidence.opaqueIdentity("invocation-\($0)")
            },
            qualifyingTrajectoryIDs: (0..<12).map {
                CausalTransitionEvidence.opaqueIdentity("trajectory-\($0)")
            },
            verifiedExecutionCount: 12,
            distinctInputCount: 12,
            zeroProviderExecutionCount: 12,
            sourceEvidenceTrajectoryCount: 2,
            p95ExecutionLatencyMilliseconds: 500,
            evaluatedAt: "2026-07-14T12:00:00Z"
        )
        let pending = try await inbox.stageProcedureExactActivationApproval(proposal)
        #expect(pending.localOnly)
        #expect(!pending.remoteResolvable)
        #expect(SwiftNativeApprovalInbox.procedureExactActivationProposal(from: pending) == proposal)
        await #expect(throws: ProcedureExactActivationApprovalError.approvalNotApproved) {
            _ = try await inbox.approvedProcedureExactActivationDecision(
                approvalID: pending.id,
                proposal: proposal
            )
        }
        _ = try await inbox.resolve(pending.id, decision: .approved, decidedBy: "local_user")
        let decision = try await inbox.approvedProcedureExactActivationDecision(
            approvalID: pending.id,
            proposal: proposal
        )
        #expect(decision.validates)
        #expect(decision.proposalDigest == proposal.bindingDigest)

        let changed = ProcedureExactActivationProposal(
            artifactID: proposal.artifactID,
            procedureShapeIdentity: proposal.procedureShapeIdentity,
            procedureID: proposal.procedureID,
            implementationIdentity: proposal.implementationIdentity,
            qualifyingInvocationIDs: proposal.qualifyingInvocationIDs,
            qualifyingTrajectoryIDs: proposal.qualifyingTrajectoryIDs,
            verifiedExecutionCount: 12,
            distinctInputCount: 12,
            zeroProviderExecutionCount: 12,
            sourceEvidenceTrajectoryCount: 2,
            p95ExecutionLatencyMilliseconds: 501,
            evaluatedAt: proposal.evaluatedAt
        )
        await #expect(throws: ProcedureExactActivationApprovalError.approvalBindingMismatch) {
            _ = try await inbox.approvedProcedureExactActivationDecision(
                approvalID: pending.id,
                proposal: changed
            )
        }
    }
}
