import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import Dispatcher
import Browser
import Experiences
// Blueprint: | `ApprovalTransactionCoordinator.swift` | Shared approval execution retains outcomes until receipt settlement; the decision archives its matter |
public struct ApprovalExecution: Sendable {
    let effects: any ApprovalTransactionEffects
    let dataRoot: URL
    public init(effects: any ApprovalTransactionEffects, dataRootOverride: URL? = nil) {
        self.effects = effects
        self.dataRoot = dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
    }
    public func resolveApproval(
        id: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui"),
        turn: Turn
    ) async throws -> ApprovalRecord {
        let inbox = SwiftNativeApprovalInbox(
            root: dataRoot
        )
        let decisionEnum: ApprovalDecision
        switch decision {
        case "approve", "approved": decisionEnum = .approved
        case "deny", "denied", "reject", "rejected": decisionEnum = .denied
        case "cancel", "canceled": decisionEnum = .canceled
        default:
            throw NSError(domain: "NativeAgentApprovals", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "unknown decision verb: \(decision)"
            ])
        }
        let rec: ApprovalRecord
        var repairedExecutionReceipt = false
        // The generic local resolution door can encounter the same saved card as studio.canon_resolve. Reject damaged evidence before any decision.
        let existing = try await inbox.get(id)
        if existing.action == StudioCanonProposal.approvalAction {
            _ = try StudioCanonProposal.draft(of: existing)
        }
        do {
            rec = try await inbox.resolve(id, decision: decisionEnum, provenance: provenance)
        } catch let error as ApprovalInboxError {
            // The inbox checked the caller's authority before reporting a terminal decision. A matching re-tap may settle its retained result, but must never
            // enter an executor after that result clears.
            guard case .alreadyResolved = error else { throw error }
            let resolved = try await inbox.get(id)
            guard resolved.status == "resolved", resolved.decision == decisionEnum.rawValue,
                  let retained = try ApprovalExecutionOwners.shared.acquireRetained(root: dataRoot, approvalID: id)
            else { throw error }
            rec = try await settleApprovalExecution(id, dataRoot: dataRoot, settlement: retained).get()
            repairedExecutionReceipt = true
        }
        var domainExecutionRequested = false
        if repairedExecutionReceipt {
            if !rec.action.hasPrefix("connector.action."), !Task.isCancelled {
                await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot)
            }
        } else if let executor = approvalExecutors(turn: turn).first(where: {
            ExecutionEventVocabulary.matches(rec.action, $0.action) && $0.shouldReconcile(rec)
        }) {
            domainExecutionRequested = true
            try await executor.execute(rec)
        } else if Self.chatToolApprovalReplay(from: rec) != nil {
            // Every surface replays the exact approved tool and input through this shared gated dispatcher.
            await self.applyResolvedChatToolApproval(from: rec, dataRoot: dataRoot)
        } else if rec.action.hasPrefix("connector.action.") {
            _ = await applyResolvedConnectorAction(
                from: rec,
                dataRoot: dataRoot
            )
        }
        if ApprovalExecutionOwners.shared.settlement(root: dataRoot, approvalID: rec.id) != nil {
            throw NSError(domain: "NativeAgentApprovals", code: 500, userInfo: [
                NSLocalizedDescriptionKey: """
                    The execution outcome is retained, but its receipt could not be saved. Retry the same decision before closing the app to save it \
                    without running the action again.
                    """
            ])
        }
        if !Task.isCancelled, Self.chatToolApprovalReplay(from: rec) == nil {
            await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot)
        }
        let finalRecord = try await inbox.get(rec.id)
        if domainExecutionRequested, finalRecord.executedAction == nil {
            let owed = try await RepairOwed.openDebt(ExperienceStore.at(dataRoot),
                operation: "approval.application:" + rec.id, owner: "Approval " + rec.id)
            let detail = owed?.face?.words ?? "The domain owner has not returned a terminal outcome; execution may be deferred."
            throw NSError(domain: "NativeAgentApprovals", code: 503, userInfo: [
                NSLocalizedDescriptionKey: "Your decision is saved. Application remains owed: \(detail) No failed effect is inferred."
            ])
        }
        return finalRecord
    }
}
