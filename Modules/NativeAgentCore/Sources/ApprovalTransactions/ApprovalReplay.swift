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
        let fileAccessCeiling: Result<ICloudChatFileAccessPolicy.Ceiling, any Error>
        let input: [String: JSONValue]
        let sessionId: String?
        let telegramChatId: String?
        let verifiedUserId: String?
        let replyRoute: TurnEnvelope.DeliveryRoute?
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
        let replyRoute: TurnEnvelope.DeliveryRoute? = [
            destinationId, threadId, sourceKey, replyTo, correlationId,
        ].contains(where: { $0 != nil })
            ? TurnEnvelope.DeliveryRoute(
                surface: Self.nonEmptyPayloadString(origin["surface"]) ?? surface,
                destinationId: destinationId,
                threadId: threadId,
                sourceKey: sourceKey,
                replyTo: replyTo,
                correlationId: correlationId
            )
            : nil
        let fileAccess = if case .string(let mode)? = payload["fileAccess"] { mode } else { "auto" }
        let ceiling = Result {
            guard let saved = payload["fileAccessCeiling"] else {
                throw ToolFailureError("This approval has no recorded file-access ceiling; raise a new request from its originating conversation.",
                    effects: .none, code: "approval_file_access_unavailable")
            }
            return try JSONDecoder().decode(ICloudChatFileAccessPolicy.Ceiling.self, from: saved.serializedData(pretty: false))
        }
        // A verified paired-phone decision authorizes follow-up because the persisted envelope has no raising-turn signature.
        let signedDecision: Bool? = if case .signedIOS? = rec.resolutionProvenance?.transport { true } else { nil }
        return ChatToolApprovalReplay(
            toolName: toolName,
            surface: surface,
            fileAccess: fileAccess,
            fileAccessCeiling: ceiling,
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
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, turn, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, turn: turn, prompt: prompt)
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
            // Heal continuity separately from execution so a completed effect leaves a receipt instead of inviting a repeat.
            if !(await ensureChatToolApprovalOutcomeReceipt(
                approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)) {
                failures.insert(rec.id)
            }
        }
        return (executed, failures)
    }
}
