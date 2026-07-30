import Foundation
import PersistenceCore

public enum ProcedureReviewApprovalError: String, Error, Sendable, Equatable {
    case invalidProposal = "invalid_proposal"
    case approvalNotApproved = "approval_not_approved"
    case approvalNotLocal = "approval_not_local"
    case approvalBindingMismatch = "approval_binding_mismatch"
    case approvalTimestampInvalid = "approval_timestamp_invalid"
}

extension SwiftNativeApprovalInbox {
    public static let procedureReviewApprovalAction = "living_fabric.procedure_review"
    private static let procedureReviewApprovalSchema = "living-fabric-procedure-review.v1"

    @discardableResult
    public func stageProcedureReviewApproval(
        _ proposal: ProcedureReviewProposal
    ) async throws -> ApprovalRecord {
        guard proposal.validates else { throw ProcedureReviewApprovalError.invalidProposal }
        return try await create(.object([
            "title": .string("Review compiled procedure candidate"),
            "action": .string(Self.procedureReviewApprovalAction),
            "risk": .string("high"),
            "reason": .string(
                "Approve this exact payload-free procedure evidence set for manual review scope. The artifact grants no permission, cannot send externally, and cannot auto-activate."
            ),
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
            "payloadPreview": .string(
                "Procedure \(proposal.candidateShapeIdentity.prefix(12)); \(proposal.trajectoryCount) verified trajectories; scope \(proposal.scope.rawValue)."
            ),
            "payload": procedureReviewBinding(proposal),
        ]))
    }

    /// Mints the only production-capable reviewer decision. The compiler later
    /// recomputes `candidateEvidenceDigest`, so even an approved stale proposal
    /// cannot compile a changed candidate.
    public func approvedProcedureReviewerDecision(
        approvalID: String,
        proposal: ProcedureReviewProposal
    ) async throws -> ProcedureReviewerDecision {
        guard proposal.validates else { throw ProcedureReviewApprovalError.invalidProposal }
        let record = try await get(approvalID)
        guard record.action == Self.procedureReviewApprovalAction,
              record.status == "resolved",
              record.decision == ApprovalDecision.approved.rawValue else {
            throw ProcedureReviewApprovalError.approvalNotApproved
        }
        guard record.localOnly, !record.remoteResolvable else {
            throw ProcedureReviewApprovalError.approvalNotLocal
        }
        guard record.payload == procedureReviewBinding(proposal) else {
            throw ProcedureReviewApprovalError.approvalBindingMismatch
        }
        guard let created = procedureReviewDate(record.createdAt),
              let resolvedRaw = record.resolvedAt,
              let resolved = procedureReviewDate(resolvedRaw),
              resolved >= created else {
            throw ProcedureReviewApprovalError.approvalTimestampInvalid
        }
        return ProcedureReviewerDecision(
            candidateShapeIdentity: proposal.candidateShapeIdentity,
            verdict: .approve,
            scope: proposal.scope,
            reviewerIdentity: CausalTransitionEvidence.opaqueIdentity("local-reviewer|\(record.id)"),
            approvalReceiptIdentity: CausalTransitionEvidence.opaqueIdentity(record.id),
            candidateEvidenceDigest: proposal.candidateEvidenceDigest,
            decidedAt: resolvedRaw
        )
    }

    private func procedureReviewBinding(_ proposal: ProcedureReviewProposal) -> JSONValue {
        .object([
            "schema": .string(Self.procedureReviewApprovalSchema),
            "purpose": .string("review_compiled_procedure_candidate"),
            "candidateShapeIdentity": .string(proposal.candidateShapeIdentity),
            "candidateEvidenceDigest": .string(proposal.candidateEvidenceDigest),
            "productRole": .string(proposal.productRole.rawValue),
            "trajectoryCount": .int(Int64(proposal.trajectoryCount)),
            "scope": .string(proposal.scope.rawValue),
            "manualInvocationOnly": .bool(proposal.scope == .manualOnly),
            "automaticActivation": .bool(false),
            "permissionAuthority": .bool(false),
            "externalSendsEligible": .bool(false),
        ])
    }

    private func procedureReviewDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
