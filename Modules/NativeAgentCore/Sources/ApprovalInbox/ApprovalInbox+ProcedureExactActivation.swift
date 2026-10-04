import Foundation
import NativeAgentCore
import PersistenceCore
import Procedures

public enum ProcedureExactActivationApprovalError: String, Error, Sendable, Equatable {
    case invalidProposal = "invalid_proposal"
    case approvalNotApproved = "approval_not_approved"
    case approvalNotLocal = "approval_not_local"
    case approvalBindingMismatch = "approval_binding_mismatch"
    case approvalTimestampInvalid = "approval_timestamp_invalid"
}

extension SwiftNativeApprovalInbox {
    public static let procedureExactActivationApprovalAction =
        "living_fabric.procedure_exact_activation"
    private static let procedureExactActivationApprovalSchema =
        "living-fabric-procedure-exact-activation.v1"

    @discardableResult
    public func stageProcedureExactActivationApproval(
        _ proposal: ProcedureExactActivationProposal
    ) async throws -> ApprovalRecord {
        guard proposal.validates else {
            throw ProcedureExactActivationApprovalError.invalidProposal
        }
        // Said to the person: what it is, why, and what changes. The exact
        // binding stays in the payload and the preview (Details).
        let name = proposal.procedureID
            .replacingOccurrences(of: #"_v\d+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        return try await create(.object([
            "title": .string("Run \(name) on its own from now on?"),
            "action": .string(Self.procedureExactActivationApprovalAction),
            "risk": .string("high"),
            "reason": .string(
                "It has worked \(proposal.verifiedExecutionCount) times with no model needed, about \(proposal.p95ExecutionLatencyMilliseconds) ms each. When a request matches it exactly, I'd run it straight away; anything unclear still comes through me."
            ),
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
            "payloadPreview": .string(
                "Activate \(proposal.procedureID): \(proposal.verifiedExecutionCount) verified zero-provider executions; p95 \(proposal.p95ExecutionLatencyMilliseconds) ms; exact typed routing only."
            ),
            "payload": Self.procedureExactActivationBinding(proposal),
        ]))
    }

    public func approvedProcedureExactActivationDecision(
        approvalID: String,
        proposal: ProcedureExactActivationProposal
    ) async throws -> ProcedureExactActivationReviewerDecision {
        guard proposal.validates else {
            throw ProcedureExactActivationApprovalError.invalidProposal
        }
        let record = try await get(approvalID)
        guard record.action == Self.procedureExactActivationApprovalAction,
              record.status == "resolved",
              record.decision == ApprovalDecision.approved.rawValue else {
            throw ProcedureExactActivationApprovalError.approvalNotApproved
        }
        guard record.localOnly, !record.remoteResolvable else {
            throw ProcedureExactActivationApprovalError.approvalNotLocal
        }
        guard record.payload == Self.procedureExactActivationBinding(proposal) else {
            throw ProcedureExactActivationApprovalError.approvalBindingMismatch
        }
        guard let created = Self.procedureExactActivationDate(record.createdAt),
              let resolvedRaw = record.resolvedAt,
              let resolved = Self.procedureExactActivationDate(resolvedRaw),
              resolved >= created else {
            throw ProcedureExactActivationApprovalError.approvalTimestampInvalid
        }
        return ProcedureExactActivationReviewerDecision(
            proposalDigest: proposal.bindingDigest,
            verdict: .approve,
            reviewerIdentity: CausalTransitionEvidence.opaqueIdentity(
                "local-reviewer|\(record.id)"
            ),
            approvalReceiptIdentity: CausalTransitionEvidence.opaqueIdentity(record.id),
            decidedAt: resolvedRaw
        )
    }

    public static func procedureExactActivationProposal(
        from record: ApprovalRecord
    ) -> ProcedureExactActivationProposal? {
        guard record.action == procedureExactActivationApprovalAction,
              case .object(let payload) = record.payload,
              payload["schema"] == .string(procedureExactActivationApprovalSchema),
              let proposalJSON = payload["proposal"] else { return nil }
        return ProcedureExactActivationProposal(json: proposalJSON)
    }

    private static func procedureExactActivationBinding(
        _ proposal: ProcedureExactActivationProposal
    ) -> JSONValue {
        .object([
            "schema": .string(procedureExactActivationApprovalSchema),
            "purpose": .string("activate_exact_typed_workshop_procedure"),
            "proposal": proposal.toJSON(),
            "proposalDigest": .string(proposal.bindingDigest),
            "automaticSelection": .bool(true),
            "selectionMode": .string("exact_typed"),
            "permissionAuthority": .bool(false),
            "externalSendsEligible": .bool(false),
            "fallbackBeforeAdmission": .bool(true),
        ])
    }

    private static func procedureExactActivationDate(_ raw: String) -> Date? {
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }
}
