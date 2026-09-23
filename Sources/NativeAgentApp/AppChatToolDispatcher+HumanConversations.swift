import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

/// Explicit replies reuse the established assistant transcript and completion delivery owners.
/// No provider call and no synthetic human message is involved.
actor HumanConversationReplyService {
    static let shared = HumanConversationReplyService()
    let dataRoot: URL
    let sender: any AgentBridgeCompletionSending
    let lifecycle: CodexCompletionLifecycle
    let append: @Sendable (String, String, String, String) async throws -> Void

    init(dataRoot: URL = PersistenceCore.defaultDataRoot(),
         sender: (any AgentBridgeCompletionSending)? = nil,
         append: (@Sendable (String, String, String, String) async throws -> Void)? = nil) {
        self.dataRoot = dataRoot
        self.sender = sender ?? LiveAgentBridgeCompletionSender(dataRoot: dataRoot)
        lifecycle = CodexCompletionLifecycle(
            receiptURL: dataRoot.appendingPathComponent("chat/human-reply-delivery/receipts.jsonl"),
            ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
        self.append = append ?? { id, expected, text, run in
            let client = makeNativeAgentAppChatOrchestrationClient(profile: .background, dataRoot: dataRoot)
            try await client.appendHumanConversationReply(sessionID: id, expectedLastMessageID: expected,
                                                          text: text, runID: run)
        }
    }

    func reply(input: [String: JSONValue]) async throws -> JSONValue {
        guard let id = HumanConversationReader.string(input["conversation_session_id"]),
              let expected = HumanConversationReader.string(input["last_message_id"]),
              let text = HumanConversationReader.string(input["text"]),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 16000 else {
            return failure("missing_reply", "Open the conversation, then supply the reply text.")
        }
        guard ChatToolSessionContext.verifiedSessionId != id else {
            return failure("current_turn", "This is the active conversation. Reply normally here; no separate send is needed.")
        }
        let snapshot = try await HumanConversationReader.read(sessionID: id, dataRoot: dataRoot)
        guard snapshot.complete, snapshot.lastMessageID == expected,
              HumanConversationReader.routeAvailable(snapshot.route), let envelope = snapshot.route else {
            return failure("conversation_changed", "The conversation changed or its reply destination is unavailable. Reopen it before replying.")
        }
        let saved = envelope.replyRoute
        let deliverySurface = saved.surface == "app" ? "chat" : saved.surface
        let route = AgentBridgeCompletionRoute(surface: deliverySurface, sessionId: id,
            destinationId: saved.destinationId, threadId: saved.threadId, sourceKey: saved.sourceKey,
            replyTo: saved.replyTo, correlationId: saved.correlationId)
        let deliveryID = "human-reply:" + digest(id + "\u{1f}" + expected)
        let requestDigest = digest(id + "\u{1f}" + expected + "\u{1f}" + text)
        // Known setup failures happen before a claim or transcript mutation.
        do {
            let artifacts = try AgentBridgeCompletionRouter.artifacts(deliveryId: deliveryID,
                surface: deliverySurface, text: text, attachments: [])
            try await sender.preflight(surface: deliverySurface, route: route, artifacts: artifacts)
        } catch {
            return failure("unavailable", "This conversation's delivery connection is unavailable. Nothing was saved or sent.")
        }
        // Claim first. An interrupted or ambiguous attempt is never automatically replayed.
        let claim = try await lifecycle.claim(deliveryId: deliveryID, requestDigest: requestDigest, sessionId: id)
        switch claim {
        case .start: break
        case .cached, .settled:
            return failure("already_attempted", "This reply already has a recorded attempt. Read the conversation; do not resend it.")
        case .inProgress, .outcomeUnknown:
            return failure("outcome_unknown", "A prior reply may have been delivered. Do not resend it.")
        case .conflict:
            return failure("reply_changed", "A reply is already bound to this conversation view. Reopen it before composing another.")
        }
        do {
            try await append(id, expected, text, deliveryID)
            let response = ChatOrchestration.ChatResponse(runId: deliveryID, model: "explicit-assistant-reply",
                                                         output: text, sessionId: id)
            try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: requestDigest)
            let delivery = await AgentBridgeCompletionRouter.deliver(deliveryId: deliveryID,
                requestDigest: requestDigest, text: text, attachments: [], route: route,
                sender: sender, lifecycle: lifecycle)
            return .object(["status": .string(delivery.status), "conversation_session_id": .string(id),
                "title": .string(snapshot.title), "delivery": .string(delivery.delivery),
                "message": .string(delivery.status == "completed" ? "Reply delivered to this conversation."
                    : "Reply is recorded in the conversation; delivery is not confirmed. Do not resend automatically."),
                "detail": delivery.reason.map(JSONValue.string) ?? .null])
        } catch {
            try? await lifecycle.markOutcomeUnknown(deliveryId: deliveryID, requestDigest: requestDigest,
                                                    detail: "explicit_reply_interrupted")
            return failure("outcome_unknown", "Reply completion could not be confirmed. Read the conversation before taking further action; do not resend automatically.")
        }
    }
    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func failure(_ status: String, _ message: String) -> JSONValue {
        .object(["status": .string(status), "message": .string(message), "ok": .bool(false)])
    }
}
