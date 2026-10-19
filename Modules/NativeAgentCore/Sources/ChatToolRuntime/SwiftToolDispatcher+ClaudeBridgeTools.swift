import AgentWorkspace
import FeedPolicy
import Foundation
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {
    // A carried inbox door is read by its live session; it never starts a headless run.
    func runClaudeMessage(
        input: [String: JSONValue],
        surface: String = "chat",
        configRootOverride: URL? = nil
    ) async throws -> JSONValue {
        let target = Self.stringField("agent", in: .object(input)) ?? "claude"
        guard let door = AgentConversationDelivery.door(for: target, dataRoot: dataRoot, bridgeConfigRoot: configRootOverride), door.liveReader,
              let who = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { ($0.handles ?? []).contains(door.handle) }) else {
            throw ToolFailureError("No contact carries this inbox door.", effects: .none, owner: "Saved agent contacts", nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]))
        }
        let inboxURL = door.inbox
        let text: String, priority: String
        switch Self.bridgeMessageFields(input, tool: "claude_message") {
        case .success(let fields): (text, priority) = fields
        case .failure(let refusal): return refusal.value
        }
        // 2026-09-07: a message to Claude must not die on a stale Desk number.
        // The agent burned eight rounds re-sending with desk_item "123" after
        // each denial and never delivered its review. A binding that is not
        // live is dropped, the message goes, and the result says so.
        let (deskHandle, droppedDeskItem) = try await delegationDeskHandleDroppingStale(input)
        let pairReviewer: Bool
        switch Self.pairReviewerRequested(in: input) {
        case .success(let requested): pairReviewer = requested
        case .failure(let error): return error.value
        }
        let fyi = input["expects_reply"] == .bool(false)
        let requestedTopic: String? = {
            guard case .string(let raw)? = input["topic"] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        let workingDirectory: String?
        switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
        case .success(let path):
            workingDirectory = path
        case .failure(let envelope):
            return envelope
        }

        let originSessionId = Self.extractSessionId(from: input)
        let origin = Self.agentBridgeReplyOrigin(surface: surface, route: ChatToolSessionContext.replyRoute)
        let dir = inboxURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_dir_create_failed"),
                "detail": .string(ChatToolOutcome.errorMessage(error)),
            ])
        }

        let messageId = Self.builderMessageId(input: input)
        let conversation: BuilderConversationSelection
        switch Self.builderConversationSelection(
            input: input,
            agent: .claude,
            topic: requestedTopic,
            messageId: messageId
        ) {
        case .success(let selection): conversation = selection
        case .failure(let error): return error.envelope
        }
        let topic = conversation.topic
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var entry: [String: JSONValue] = [
            "id": .string(messageId),
            "messageId": .string(messageId),
            "createdAt": .string(timestamp),
            "from": .string("assistant"),
            "priority": .string(priority),
            "text": .string(text),
            "read": .bool(false),
        ]
        if let topic { entry["topic"] = .string(topic) }
        if let conversationId = conversation.conversationId {
            entry["conversationId"] = .string(conversationId)
        }
        if Self.builderConversationReferenceSupplied(in: input) { entry["requireExistingConversation"] = .bool(true) }
        if let workingDirectory { entry["workingDirectory"] = .string(workingDirectory) }
        if let deskHandle { entry["deskHandle"] = .string(deskHandle) }
        if pairReviewer { entry["pairReviewer"] = .bool(true) }
        if fyi { entry["expectsReply"] = .bool(false) }
        if !originSessionId.isEmpty { entry["sessionId"] = .string(originSessionId) }
        entry["origin"] = origin
        let inboxEntry = entry

        let persistence = SwiftNativePersistenceCore()
        let quarantineNote = Self.BuilderInboxQuarantineNote()
        let appendResult: (status: String, retryWake: Bool, queuedAt: String)
        do {
            appendResult = try await Self.appendBuilderInboxMessage(
                messageId, entry: inboxEntry, to: inboxURL, queuedAt: timestamp,
                comparePairReviewer: true, maxLines: JSONLLineCaps.claudeBridgeInbox,
                logLabel: "SwiftToolDispatcher.claudeMessage",
                persistence: persistence, quarantine: quarantineNote, durable: true
            )
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_write_failed"),
                "detail": .string(ChatToolOutcome.errorMessage(error)),
            ])
        }
        guard appendResult.status != "conflict" else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("message_id_conflict"),
                "detail": .string("That message_id already names a different message, so nothing was queued. Use a new message_id, or omit it."),
                "messageId": .string(messageId),
            ])
        }
        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "sent": .bool(true),
            "completed": .bool(false),
            "read": .bool(false),
            "messageId": .string(messageId),
            "deduplicated": .bool(appendResult.status == "duplicate"),
            "filePath": .string(inboxURL.path),
            "priority": .string(priority),
            "queuedAt": .string(appendResult.queuedAt),
            "detail": .string("Queued for \(who.name); acceptance is owed until its live session reads this message. Open that session and read this exact message with agent.read; do not resend it."),
            "remedy": door.remedy(),
        ]
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        if let deskHandle { response["deskHandle"] = .string(deskHandle) }
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["detail"] = .string((Self.stringField("detail", in: .object(response)) ?? "") + " desk_item '\(droppedDeskItem)' is not a live Desk item; the message was queued without a Desk binding. Omit desk_item unless you have a live handle from app desk.read.")
        }
        if pairReviewer { response["reviewerPairRequested"] = .bool(true) }
        if let conversationId = conversation.conversationId {
            response["conversationId"] = .string(conversationId)
            response["replyWith"] = .string("agent.message")
        }
        return .object(response)
    }

    /// Maps the wake helper's own status onto the four states this receipt can
    /// honestly claim. "queued" is the floor, never a lie: the durable inbox
    /// row is already written by the time we get here, so an unheard-from or
    /// deduplicated wake is still a real enqueue.
    static func claudeReceiptStatus(_ wakeup: JSONValue?) -> String {
        switch stringField("status", in: wakeup ?? .null) {
        case "sent", "started":
            // Admitted by the helper: a runner exists. Not proof of completion,
            // which is what `delegation_status` and the outcome loop are for.
            return "accepted"
        case "completed", "replayed":
            return "completed"
        case "failed", "blocked":
            // The row is on disk but nothing was admitted to act on it, so the
            // receipt must not read healthier than the send actually was.
            return "failed"
        default:
            return "queued"
        }
    }

    /// A wake that started nothing (the replay guard, wakes switched off, no
    /// helper) leaves the row on disk with no one to act on it: "queued" would
    /// promise an answer that never comes (walk 2, 09-25: OMP "waiting" forever).
    /// The replay guard's skip is the exception: that work already ran, so it
    /// reads completed (deduplicated), with delivery reported separately.
    static func markWakeStartedNothing(_ response: inout [String: JSONValue], agent: String, dataRoot: URL) {
        let wakeup = response["wakeup"] ?? .null
        guard stringField("status", in: wakeup) == "skipped", let reason = stringField("reason", in: wakeup) else { return }
        if reason == "already_completed" {
            // Say which run, its recorded delivery, and any retained answer.
            response["status"] = .string("completed")
            response["deduplicated"] = .bool(true)
            response["reason"] = .string(reason)
            response["note"] = nil
            var prior: [String: JSONValue] = [:]
            for (key, field) in [("job_id", "jobId"), ("completed_at", "completedAt"), ("status", "priorRunStatus")] {
                if let value = stringField(field, in: wakeup) { prior[key] = .string(value) }
            }
            response["prior_job"] = .object(prior)
            let reply = stringField("reply", in: wakeup)
            if let reply { response["reply"] = .string(reply) }
            let delivery = stringField("delivery", in: wakeup)
            if let delivery { response["delivery"] = .string(delivery) }
            let deliveryDetail: String
            switch delivery {
            case "delivered": deliveryDetail = "; that run's answer was delivered then."
            case "pending": deliveryDetail = "; delivery of that run's answer is pending."
            default: deliveryDetail = "; delivery of that run's answer is unconfirmed."
            }
            response["detail"] = .string("\(agent) already answered this exact message, the last one on this conversation"
                + (reply == nil ? deliveryDetail : "; this is that answer." + deliveryDetail)
                + " It was not run again. Reword the message to ask again.")
            if case .object(let labelled) = PeerDataTaintDispatcher.labelled(.object(response), agent: agent.lowercased(), dataRoot: dataRoot) {
                response = labelled
            }
            return
        }
        guard ["disabled_by_environment", "helper_not_found"].contains(reason) else { return }
        response["status"] = .string("unavailable")
        response["sent"] = .bool(false)
        response["reason"] = .string(reason)
        response["note"] = nil
        response["detail"] = .string("Not sent: \(agent) could not be started here (\(reason)), so nothing will answer this message.")
    }
}
