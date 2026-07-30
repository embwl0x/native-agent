import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import WorkshopExecution

extension NativeClient {
    /// Idempotent executor for the local-only exact-procedure activation card.
    /// Approval persists first; this executor installs an immutable manifest
    /// and one replaceable pointer. Launch reconciliation heals the crash gap.
    static func applyResolvedProcedureExactActivation(
        from record: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard record.action == SwiftNativeApprovalInbox
            .procedureExactActivationApprovalAction,
              record.status == "resolved" else { return }
        guard record.decision == ApprovalDecision.approved.rawValue else {
            try? await annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "action": .string(record.action),
                    "decision": .string(record.decision ?? "unknown"),
                    "activated": .bool(false),
                ]),
                detail: "Exact procedure activation \(record.decision ?? "not approved"); active routing unchanged.",
                root: dataRoot
            )
            return
        }
        guard let proposal = SwiftNativeApprovalInbox
            .procedureExactActivationProposal(from: record) else {
            try? await annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "action": .string(record.action),
                    "status": .string("failed"),
                    "error": .string("invalid activation proposal binding"),
                ]),
                detail: "FAILED: exact procedure activation proposal binding is invalid.",
                root: dataRoot
            )
            return
        }
        do {
            let store = ProcedureArtifactStore(dataRoot: dataRoot)
            let artifact = try await store.load(proposal.artifactID)
            guard await WorkshopProcedureExactActivationQualifier
                .proposalStillMatchesCanonicalEvidence(
                    proposal,
                    dataRoot: dataRoot,
                    artifact: artifact
                ) else {
                throw ProcedureExactActivationError.activationBindingMismatch
            }
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            let decision = try await inbox.approvedProcedureExactActivationDecision(
                approvalID: record.id,
                proposal: proposal
            )
            let manifest = try await store.installAndActivateExact(
                    proposal: proposal,
                    reviewerDecision: decision
                )
            try await annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "action": .string(record.action),
                    "status": .string("activated"),
                    "activation_id": .string(manifest.id),
                    "artifact_id": .string(manifest.proposal.artifactID),
                    "procedure_id": .string(manifest.proposal.procedureID),
                    "selection_mode": .string(manifest.selectionMode),
                    "permission_authority": .bool(false),
                ]),
                detail: "Activated exact typed routing for \(manifest.proposal.procedureID); TrustCenter and canonical verification remain mandatory.",
                root: dataRoot
            )
        } catch {
            try? await annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "action": .string(record.action),
                    "status": .string("failed"),
                    "error": .string(String(describing: error)),
                ]),
                detail: "FAILED: exact procedure activation was not installed (\(error.localizedDescription)).",
                root: dataRoot
            )
        }
    }
}
