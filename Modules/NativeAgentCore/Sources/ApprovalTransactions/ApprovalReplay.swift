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
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ApprovalReplay.swift` | Exact chat tool approval replay interpretation |
extension ApprovalExecution {
    struct ChatToolApprovalReplay: Sendable {
        let toolName: String
        let surface: String
        let fileAccess: String
        let input: [String: JSONValue]
        let sessionId: String?
        let telegramChatId: String?
        let verifiedUserId: String?
        let replyRoute: ChatToolSessionContext.ReplyRoute?
        let envelope: TurnEnvelope
    }
    static func chatToolApprovalReplay(from rec: ApprovalRecord) -> ChatToolApprovalReplay? {
        guard case .object(let payload) = rec.payload,
              payload["kind"] == .string("chat_tool_approval"),
              case .object(let origin)? = payload["origin"],
              let toolName = Self.nonEmptyPayloadString(payload["toolName"]),
              let surface = Self.nonEmptyPayloadString(payload["surface"]),
              case .object(let input)? = payload["input"] else { return nil }
        let sessionId = Self.nonEmptyPayloadString(origin["sessionId"])
        let chatId = Self.nonEmptyPayloadString(origin["chatId"])
        let verifiedUserId = Self.nonEmptyPayloadString(origin["userId"])
        let destinationId = Self.nonEmptyPayloadString(origin["destinationId"])
        let threadId = Self.nonEmptyPayloadString(origin["threadId"])
        let sourceKey = Self.nonEmptyPayloadString(origin["sourceKey"])
        let replyTo = Self.nonEmptyPayloadString(origin["replyTo"])
        let correlationId = Self.nonEmptyPayloadString(origin["correlationId"])
        let replyRoute: ChatToolSessionContext.ReplyRoute? = [
            destinationId, threadId, sourceKey, replyTo, correlationId,
        ].contains(where: { $0 != nil })
            ? ChatToolSessionContext.ReplyRoute(
                surface: Self.nonEmptyPayloadString(origin["surface"]) ?? surface,
                destinationId: destinationId,
                threadId: threadId,
                sourceKey: sourceKey,
                replyTo: replyTo,
                correlationId: correlationId
            )
            : nil
        let fileAccess = if case .string(let mode)? = payload["fileAccess"] { mode } else { "auto" }
        // A card the person decided on his paired iPhone (an action the router
        // verified) authenticates its own follow-up: the persisted envelope never
        // keeps the raising turn's signature, so his decision is the one it runs under.
        let signedDecision: Bool? = if case .signedIOS? = rec.resolutionProvenance { true } else { nil }
        return ChatToolApprovalReplay(
            toolName: toolName,
            surface: surface,
            fileAccess: fileAccess,
            input: input,
            sessionId: sessionId,
            telegramChatId: chatId,
            verifiedUserId: verifiedUserId,
            replyRoute: replyRoute,
            envelope: TurnEnvelope(
                surface: surface,
                agent: Self.nonEmptyPayloadString(origin["agent"]),
                verifiedChatId: chatId,
                verifiedUserId: verifiedUserId,
                commandSignatureVerified: signedDecision,
                deliveryRoute: replyRoute,
                declaredRemote: origin["declaredRemote"] == .bool(true) ? true : nil,
                answerExperienceID: Self.nonEmptyPayloadString(origin["answerExperienceID"])
            )
        )
    }
    private static func nonEmptyPayloadString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
    @discardableResult
    public func reconcileUnappliedChatToolApprovalExecutions(
        dataRoot: URL,
        records: [ApprovalRecord],
        continuation: ChatApprovalContinuation? = nil
    ) async -> (executed: Int, failures: Set<String>) {
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, envelope, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, envelope: envelope, prompt: prompt)
        }
        var failures: Set<String> = []
        var executed = 0
        for rec in records where Self.chatToolApprovalReplay(from: rec) != nil {
            if Self.chatToolApprovalReplay(from: rec) != nil, rec.executedAction == nil {
                nativeLog("[approvalReconcile] reconciling eligible resolved chat tool approval "
                    + "\(rec.id) action=\(rec.action) decision=\(rec.decision ?? "?")")
                await applyResolvedChatToolApproval(from: rec, dataRoot: dataRoot, continuation: continuation)
                executed += 1
            }
            // Execution truth and conversational continuity are separate
            // commits. Heal the latter too: an approved tool that ran before a
            // crash must still leave one resident tool receipt in the original
            // session so the next turn knows it completed and does not retry.
            if !(await ensureChatToolApprovalOutcomeReceipt(
                approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)) {
                failures.insert(rec.id)
            }
        }
        return (executed, failures)
    }
}
