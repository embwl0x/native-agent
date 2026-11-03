import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import Procedures
import WorkshopExecution
// Blueprint: | `ProcedureExactActivationApproval.swift` | `ApprovalExecution`: `applyResolvedProcedureExactActivation` |

extension ApprovalExecution {
    /// Idempotent executor for the local-only exact-procedure activation card.
    /// Approval persists first; this executor installs an immutable manifest
    /// and one replaceable pointer. Launch reconciliation heals the crash gap.
    public static func applyResolvedProcedureExactActivation(
        from record: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard record.action == SwiftNativeApprovalInbox
            .procedureExactActivationApprovalAction,
              record.status == "resolved" else { return }
        await performDomainApprovalExecution(record, dataRoot: dataRoot) {
        guard record.decision == ApprovalDecision.approved.rawValue else {
            return .init(action: .object([
                    "action": .string(record.action),
                    "decision": .string(record.decision ?? "unknown"),
                    "activated": .bool(false),
                ]),
                detail: "Exact procedure activation \(record.decision ?? "not approved"); active routing unchanged.")
        }
        guard let proposal = SwiftNativeApprovalInbox
            .procedureExactActivationProposal(from: record) else {
            return .init(action: .object([
                    "action": .string(record.action),
                    "status": .string("failed"),
                    "error": .string("invalid activation proposal binding"),
                ]),
                detail: "FAILED: exact procedure activation proposal binding is invalid."
            )
        }
            let store = ProcedureArtifactStore(dataRoot: dataRoot)
            let artifact = try await store.load(proposal.artifactID)
            guard await WorkshopProcedureExactActivationQualifier.proposalStillMatchesCanonicalEvidence(
                proposal, dataRoot: dataRoot, artifact: artifact
            ) else {
                throw ProcedureExactActivationError.activationBindingMismatch
            }
            let decision = try await SwiftNativeApprovalInbox(root: dataRoot)
                .approvedProcedureExactActivationDecision(approvalID: record.id, proposal: proposal)
            let manifest = try await store.installAndActivateExact(
                proposal: proposal, reviewerDecision: decision
            )
            return .init(action: .object([
                    "action": .string(record.action),
                    "status": .string("activated"),
                    "activation_id": .string(manifest.id),
                    "artifact_id": .string(manifest.proposal.artifactID),
                    "procedure_id": .string(manifest.proposal.procedureID),
                    "selection_mode": .string(manifest.selectionMode),
                    "permission_authority": .bool(false),
                ]),
                detail: "Activated exact typed routing for \(manifest.proposal.procedureID); TrustCenter and canonical verification remain mandatory."
            )
        }
    }
}
