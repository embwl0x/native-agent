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
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import Experiences
// Blueprint: | `ApprovalTransactionCoordinator.swift` | `ApprovalExecution` struct; chat/connector execution owners retain returned outcomes on save failure; a matching decision re-tap repairs only the receipt through `settle`, which owns annotation and terminal slot release; delegates execution-record claim changes to Workshop's executor and terminal browser reads to the browser owner; reconciliation cursor coverage is declared here; Desk resolution observation runs in BackgroundLoops' resident body; admitted Desk decision writes finish through `settle` |
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
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui")
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
        // The generic local resolution door can encounter the same saved card
        // as studio.canon_resolve. Reject damaged evidence before any decision.
        let existing = try await inbox.get(id)
        if existing.action == StudioCanonProposal.approvalAction {
            _ = try StudioCanonProposal.draft(of: existing)
        }
        do {
            rec = try await inbox.resolve(id, decision: decisionEnum, provenance: provenance)
        } catch let error as ApprovalInboxError {
            // The inbox checked the caller's authority before reporting a
            // terminal decision. A matching re-tap may settle its retained
            // result, but must never enter an executor after that result clears.
            guard case .alreadyResolved = error else { throw error }
            let resolved = try await inbox.get(id)
            guard resolved.status == "resolved", resolved.decision == decisionEnum.rawValue,
                  let retained = try ApprovalExecutionOwners.shared.acquireRetained(root: dataRoot, approvalID: id)
            else { throw error }
            rec = try await settleApprovalExecution(id, dataRoot: dataRoot, settlement: retained).get()
            repairedExecutionReceipt = true
        }
        var shouldArchiveVisibleCard = true
        var domainExecutionRequested = false
        if repairedExecutionReceipt {
            if rec.action.hasPrefix("connector.action.") {
                shouldArchiveVisibleCard = ChatToolOutcome.exactResultClass(rec.executedAction ?? .null) == .succeeded
            } else if !Task.isCancelled {
                await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot)
            }
        } else if let executor = approvalExecutors().first(where: {
            ExecutionEventVocabulary.matches(rec.action, $0.action) && $0.shouldReconcile(rec)
        }) {
            domainExecutionRequested = true
            try await executor.execute(rec)
        } else if Self.chatToolApprovalReplay(from: rec) != nil {
            // Generic chat-tool approvals are the ApprovalFiler path used by
            // chat surfaces: resolve the durable inbox record here, then
            // replay only the exact approved tool/input through the normal
            // gated dispatcher. Telegram/iOS/Mac all enter through this same
            // resolver instead of owning transport-specific replay logic.
            await self.applyResolvedChatToolApproval(from: rec, dataRoot: dataRoot)
            shouldArchiveVisibleCard = ApprovalExecutionOwners.shared.settlement(root: dataRoot, approvalID: rec.id) == nil
        } else if rec.action.hasPrefix("connector.action.") {
            shouldArchiveVisibleCard = await applyResolvedConnectorAction(
                from: rec,
                dataRoot: dataRoot
            )
        }
        if ApprovalExecutionOwners.shared.settlement(root: dataRoot, approvalID: rec.id) != nil {
            throw NSError(domain: "NativeAgentApprovals", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "The execution outcome is retained, but its receipt could not be saved. Retry the same decision before closing the app to save it without running the action again."
            ])
        }
        // Every originating conversation reports through the shared owner.
        if !Task.isCancelled, Self.chatToolApprovalReplay(from: rec) == nil {
            await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot)
        }
        let finalRecord = try await inbox.get(rec.id)
        if domainExecutionRequested, finalRecord.executedAction == nil {
            let owed = try await RepairOwed.openDebt(ExperienceStore.at(dataRoot),
                operation: "approval.application:" + rec.id, owner: "Approval " + rec.id)
            let detail = owed?.face?.words ?? "The domain owner has not returned a terminal outcome; execution may be deferred."
            throw NSError(domain: "NativeAgentApprovals", code: 503, userInfo: [
                NSLocalizedDescriptionKey: "Your decision is saved. Application remains owed: \(detail) The card remains visible; no failed effect is inferred."
            ])
        }
        // Approval and visible-card IDs match; all resolvers share live-inbox archival here.
        // A declined archive leaves the decision intact and its card re-tappable.
        if shouldArchiveVisibleCard {
            if await InboxCardActions.updateVisibleStatus(
                id: rec.id, action: "archive",
                inboxPath: LiveNotificationInbox.livePath(
                    dataRoot: dataRoot)) == false {
                nativeLog("[NativeClient] resolve(\(rec.id)): visible-card archive declined — card stays re-tappable")
            }
        }
        // The record as the executor left it, execution annotations included.
        return finalRecord
    }
}
