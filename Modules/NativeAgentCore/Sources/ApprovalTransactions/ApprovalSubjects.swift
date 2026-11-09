import Foundation
import Experiences
import ChatToolRuntime
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import MemoryV2
import ApprovalInbox
import DreamREMCycle
import TrustCenter
// Blueprint: | `ApprovalSubjects.swift` | Domain outcomes feed shared settlement. |
extension ApprovalExecution {
    private static func notDone(_ reason: String) -> ApprovalExecutionOwners.Settlement {
        .init(action: .object(["status": .string("refused"), "effects": .string("none"),
            "error": .string(reason)]), detail: "Not done: " + reason)
    }

    /// Only an owner's explicit no-effect refusal is terminal. An uncertain write still throws to the shared owed-application owner.
    private func performPartApprovalExecution(_ rec: ApprovalRecord,
        operation: () async throws -> ApprovalExecutionOwners.Settlement
    ) async {
        await Self.performDomainApprovalExecution(rec, dataRoot: dataRoot) {
            do { return try await operation() }
            catch let error as ToolFailureError where error.effects == .none {
                return Self.notDone(error.localizedDescription)
            }
        }
    }

    func applyResolvedREMProposal(from rec: ApprovalRecord) async {
        guard rec.action == "rem.proposal", rec.status == "resolved", let decision = rec.decision else { return }
        await Self.performDomainApprovalExecution(rec, dataRoot: dataRoot) {
            guard case .object(let payload) = rec.payload,
                  case .object(let proposal)? = payload["proposal"],
                  case .string(let proposalID)? = proposal["id"], !proposalID.isEmpty else {
                throw ApprovalInboxError.malformedResponse("REM approval carries no proposal id")
            }
            let store = REMProposalStore(dataRoot: dataRoot)
            switch decision {
            case "approved":
                guard case .string(let reviewedText)? = proposal["proposalText"], !reviewedText.isEmpty else {
                    throw ApprovalInboxError.malformedResponse("REM approval carries no reviewed proposal text")
                }
                // The resolved card applies durable lesson evidence; no live turn or sense read owns this reconciliation.
                let application = try await store.applyApprovedLesson(proposalId: proposalID, expectedProposalText: reviewedText,
                    context: MemoryWriteContext(turn: nil, senseReads: nil, telling: nil))
                if application.stale {
                    return .init(action: .object(["op": .string("rem_proposal_stale"), "proposalId": .string(proposalID), "error": .string("stale")]),
                        detail: "Standing lesson stale — its source correction changed before application. Nothing was added to GROWTH or graduated.")
                }
                do {
                    try await REMLessonOrigin.record(application.row,
                        memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot), dataRoot: dataRoot)
                } catch {
                    await RepairOwed.owe(dataRoot, id: "rem.origin:" + proposalID, kind: .run,
                        operation: "rem.origin:" + proposalID, owner: "REM lesson origin",
                        words: error.localizedDescription, lever: "Record the approved proposal's origin without applying its lesson again.").value
                }
                return .init(action: .object(["op": .string("rem_proposal_approve"), "proposalId": .string(proposalID),
                    "growthAppended": .bool(application.growthAppended)]),
                    detail: application.growthAppended ? "REM proposal approved — lesson added to GROWTH and sources graduated"
                        : "REM proposal approved — existing GROWTH lesson and source graduation reconciled")
            case "denied":
                _ = try await store.applyDenial(proposalId: proposalID, reason: "denied via approval inbox")
                return .init(action: .object(["op": .string("rem_proposal_deny"), "proposalId": .string(proposalID)]),
                    detail: "REM proposal denied — tombstoned")
            case "canceled":
                try await store.clearApprovalStamp(proposalId: proposalID)
                return .init(action: .object(["op": .string("rem_proposal_cancel"), "proposalId": .string(proposalID)]),
                    detail: "REM proposal canceled — left pending for a fresh card")
            default: throw ApprovalInboxError.malformedResponse("invalid REM decision: \(decision)")
            }
        }
    }

    public func applyResolvedSkillScriptInstall(from rec: ApprovalRecord, turn: Turn?) async {
        guard rec.action == SwiftNativeApprovalInbox.skillScriptInstallAction, rec.status == "resolved" else { return }
        await performPartApprovalExecution(rec) {
            guard let (skill, digest) = SwiftNativeApprovalInbox.skillScriptInstallBinding(rec) else {
                return Self.notDone("the skill install card names no skill and digest")
            }
            var done: [String: JSONValue] = ["skill": .string(skill), "digest": .string(digest), "installed": .bool(false)]
            var detail = "Not approved: \(skill)'s script stays drafted."
            if rec.decision == ApprovalDecision.approved.rawValue {
                let turn = await approvedEffectTurn(from: rec)
                try await effects.enableSkill(name: skill, reviewedDigest: digest, turn: turn)
                done["installed"] = .bool(true)
                detail = "Installed \(skill)'s script, digest \(digest.prefix(12))."
            }
            return .init(action: .object(done), detail: detail)
        }
    }

    /// Canon writes require StudioCanonSeatGate and the agent's live turn.
    public func applyResolvedStudioCanonProposal(from rec: ApprovalRecord, dataRoot requestedRoot: URL? = nil) async {
        let root = requestedRoot ?? dataRoot
        guard rec.action == StudioCanonProposal.approvalAction, rec.status == "resolved", let decision = rec.decision else { return }
        await Self.performDomainApprovalExecution(rec, dataRoot: root) {
            let work: String
            do { work = try StudioCanonProposal.draft(of: rec).workTitle }
            catch {
                return .init(action: .object(["op": .string("studio_canon_payload_unavailable"), "rowWritten": .bool(false)]),
                    detail: error.localizedDescription)
            }
            if decision != ApprovalDecision.approved.rawValue {
                return .init(action: .object(["op": .string("studio_canon_\(decision)"), "work": .string(work), "rowWritten": .bool(false)]),
                    detail: "Canon proposal \(decision) — nothing written")
            }
            let landed = try await SwiftNativeStudioStore(dataRoot: root).readCanon().contains { $0.proposalID == rec.id }
            if landed {
                return .init(action: .object(["op": .string("studio_canon_already_applied"), "work": .string(work), "rowWritten": .bool(false)]),
                    detail: "Canon row for \(work) is already on the ledger")
            }
            let agentSeat = StudioCanonSeat.isAgent(rec.decidedBy)
            return .init(action: .object(["op": .string(agentSeat ? "studio_canon_needs_agent_turn" : "studio_canon_refused"),
                "decidedBy": .string(rec.decidedBy ?? ""), "work": .string(work), "rowWritten": .bool(false)]),
                detail: agentSeat ? "The approved canon row has not landed; run app studio.canon_resolve in the agent's live turn. "
                    + "It is idempotent by proposal id."
                    : "Canon proposal not applied: \(StudioCanonError.approvalNotFromAgentSeat(rec.decidedBy ?? "unknown").localizedDescription)")
        }
    }
}
