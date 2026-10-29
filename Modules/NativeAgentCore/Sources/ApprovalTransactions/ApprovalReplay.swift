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
    static func chatToolApprovalReplay(from rec: ApprovalRecord, reportingOnly: Bool = false) -> ChatToolApprovalReplay? {
        guard case .object(let payload) = rec.payload else { return nil }
        let kind: String = {
            if case .string(let value)? = payload["kind"] { return value }
            return ""
        }()
        let telegram: [String: JSONValue] = {
            var fields: [String: JSONValue] = [:]
            if reportingOnly, case .object(let state)? = rec.chatContinuation,
               case .object(let queued)? = state["delivery"] { fields = queued }
            if case .object(let obj)? = payload["telegram"] { fields.merge(obj) { _, value in value } }
            return fields
        }()
        let origin: [String: JSONValue] = if case .object(let obj)? = payload["origin"] { obj } else { [:] }
        let generic = kind == "chat_tool_approval" || kind == "telegram_tool_approval"
        let toolName: String
        let surface: String
        let input: [String: JSONValue]
        if generic {
            guard let name = Self.nonEmptyPayloadString(payload["toolName"]),
                  let door = Self.nonEmptyPayloadString(payload["surface"]),
                  case .object(let arguments)? = payload["input"] else { return nil }
            toolName = name; surface = door; input = arguments
        } else {
            // Legacy Telegram payloads supply reporting identity only. They
            // never enter generic tool execution or rewrite the stored payload.
            guard reportingOnly, Self.nonEmptyPayloadString(telegram["chatId"]) != nil,
                  (Self.nonEmptyPayloadString(origin["sessionId"]) ?? Self.nonEmptyPayloadString(telegram["sessionId"])) != nil,
                  !rec.isAgentsOwnDecision else { return nil }
            if case .malformed = TelegramApprovalFiler.recordedTopic(rec.payload) { return nil }
            toolName = rec.action; surface = "telegram"; input = [:]
        }
        let sessionId = Self.nonEmptyPayloadString(origin["sessionId"])
            ?? Self.nonEmptyPayloadString(telegram["sessionId"])
        let chatId = Self.nonEmptyPayloadString(origin["chatId"])
            ?? Self.nonEmptyPayloadString(telegram["chatId"])
        let decidingUser: String? = if !generic, case .telegram(let decidedChat, let user)? = rec.resolutionProvenance,
            decidedChat == chatId { user } else { nil }
        let verifiedUserId = Self.nonEmptyPayloadString(origin["userId"])
            ?? Self.nonEmptyPayloadString(telegram["fromUserId"])
            ?? decidingUser
        let destinationId = Self.nonEmptyPayloadString(origin["destinationId"])
            ?? (surface == "telegram" ? chatId : nil)
        let threadId = Self.nonEmptyPayloadString(origin["threadId"])
            ?? Self.nonEmptyPayloadString(telegram["threadId"])
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
        let raw: String?
        switch value {
        case .string(let s)?: raw = s
        case .int(let i)?: raw = String(i)
        case .double(let d)?: raw = Int(exactly: d.rounded(.towardZero)).map { String($0) }
        default: raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
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
        for rec in records where Self.chatToolApprovalReplay(from: rec, reportingOnly: true) != nil {
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
