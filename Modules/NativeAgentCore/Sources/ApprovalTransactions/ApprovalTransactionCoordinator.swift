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
import AuthoredCapabilities
import Transcripts
// Blueprint: | `ApprovalTransactionCoordinator.swift` | Shared tap or person-message authority; approval execution retains outcomes until receipt settlement |
public struct ApprovalExecution: Sendable {
    let effects: any ApprovalTransactionEffects
    let dataRoot: URL
    public init(effects: any ApprovalTransactionEffects, dataRootOverride: URL? = nil) {
        self.effects = effects
        self.dataRoot = dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
    }

    /// Inbox answers share one authority read; a message names its canonical row, never a tap invented for the agent.
    @concurrent public static func decisionProvenance(id: String, turn: Turn, dataRoot: URL) async throws -> ApprovalResolutionProvenance {
        if let act = turn.personAct {
            guard let provenance = ApprovalResolutionProvenance(personAct: act) else {
                throw ToolFailureError("This door did not verify who tapped it, so the approval was not answered. "
                    + "Pair the phone or admit the Telegram sender again.", effects: .none,
                    owner: "approval " + id, code: "approval_identity_required")
            }
            return provenance
        }
        let record = try await SwiftNativeApprovalInbox(root: dataRoot).get(id)
        func refuse() -> ToolFailureError {
            ToolFailureError("Deciding an approval is the person's at every posture: \(record.title) waits for the person's tap. "
                + "inbox.withdraw takes back your own ask.", effects: .none, owner: "approval " + id,
                personDecides: true, code: "owners_call", status: .refused)
        }
        guard let envelope = turn.envelope, envelope.agent == nil,
              turn.origin?.agent == nil, turn.origin?.authored != .agent,
              turn.origin?.surface == nil || turn.origin?.surface == envelope.surface,
              let steering = turn.peerSteering, steering.checkpointSources.isEmpty,
              (turn.origin?.peerSources ?? []).isEmpty, (turn.origin?.elevatedPeerSources ?? []).isEmpty,
              turn.rows.hiddenInput == nil, turn.rows.questionRunID == nil,
              let sessionID = turn.session, NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID,
              !sessionID.isEmpty else { throw refuse() }
        let door: ApprovalResolutionProvenance
        switch envelope.surface {
        case "chat":
            guard envelope.declaredRemote == false else { throw refuse() }
            door = .local(decidedBy: "mac_ui")
        case "ios":
            guard envelope.commandSignatureVerified == true, let clientID = envelope.deliveryRoute?.sourceKey,
                  !clientID.isEmpty else { throw refuse() }
            door = .signedIOS(clientID: clientID, decidedBy: "ios_signed_operator")
        case "telegram":
            guard let chatID = envelope.verifiedChatId, let userID = envelope.verifiedUserId,
                  try await SwiftNativeSecurityCenter(dataRoot: dataRoot).remoteSenderIsAllowlisted(
                    .currentTurn(turn: turn, surface: envelope.surface)) else { throw refuse() }
            door = .telegram(chatID: chatID, userID: userID)
        default: throw refuse()
        }
        guard record.status == "pending", !record.isAgentsOwnDecision,
              try !PermissionLaw.humanDecides(action: record.action, payload: record.payload, turn: turn) else { throw refuse() }
        let messageID = try await personMessageID(sessionID: sessionID, turn: turn, dataRoot: dataRoot)
        guard let messageID else { throw refuse() }
        guard await ChatTurnSteering.shared.canAttributeApprovalToOpeningMessage(sessionId: sessionID, turn: turn, dataRoot: dataRoot) else {
            throw ToolFailureError("The exact message authorizing this decision cannot be established after a message joins a running turn "
                + "or when its open-turn record is unavailable. Nothing was answered. Read the card first or ask the person to tap it; "
                + "you can answer in a fresh message.", effects: .none, owner: "approval " + id,
                personDecides: true, code: "owners_call", status: .refused)
        }
        guard turn.resumingCheckpoint == nil, turn.messageDecisionCalls?.hasOtherCallStarted == false else {
            throw ToolFailureError("This turn started another call, or its earlier calls cannot be verified. "
                + "Read the card first or ask the person to tap it. You can answer in a fresh message.", effects: .none,
                owner: "approval " + id, personDecides: true, code: "owners_call", status: .refused)
        }
        return .personMessage(sessionID: sessionID, messageID: messageID, door: door)
    }

    @concurrent private static func personMessageID(sessionID: String, turn: Turn, dataRoot: URL) async throws -> String? {
        guard let kind = try SessionConversation.checkedKind(sessionID, dataRoot: dataRoot),
              kind == .direct || (turn.envelope?.surface == "telegram" && kind == .channel),
              try !SessionConversation.checkedIsHelper(sessionID, dataRoot: dataRoot) else { return nil }
        let rows = try await SwiftNativePersistenceCore.readJSONL(dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl"))
        let messages = rows.compactMap { $0.objectValue }.filter { $0["role"] == .string("user") && $0["runId"] == .string(turn.run) }
        guard messages.count == 1, let row = messages.first, let id = row["id"]?.stringValue, !id.isEmpty,
              case .object(let metadata)? = row["metadata"], metadata["mechanicalKind"] == nil,
              case .object(let envelope)? = metadata["envelope"], envelope["agent"] == nil,
              envelope["surface"] == turn.envelope.map({ .string($0.surface) }),
              metadata["untrusted_sources"] == nil || metadata["untrusted_sources"] == .array([]) else { return nil }
        if let origin = metadata["origin"] {
            guard case .object(let fields) = origin, fields["agent"] == nil, fields["authored"] != .string("agent") else { return nil }
        }
        return id
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
        if case .personMessage = provenance {
            guard try await Self.decisionProvenance(id: id, turn: turn, dataRoot: dataRoot) == provenance else {
                throw ToolFailureError("The deciding message does not match this turn. Nothing was answered.", effects: .none,
                    owner: "approval " + id, code: "owners_call")
            }
        }
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
            ExecutionEventVocabulary.matches(rec.action, $0.action)
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
