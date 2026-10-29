import AgentWorkspace
import Foundation
import NativeAgentShared
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `SwiftToolDispatcher+ClaudeBridgeTools.swift` | `SwiftToolDispatcher`: `runClaudeMessage`, `markWakeStartedNothing` finishes shared wake receipts |

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
        // A stale Desk binding is dropped and reported without denying delivery.
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

        let originSessionId = ChatToolSessionInjection.explicitSessionId(in: input)
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
        let timestamp = NativeTimestampFormat.plainZulu(Date())
        var entry = conversation.inboxFields(messageId: messageId, queuedAt: timestamp,
            priority: priority, text: text, sessionId: originSessionId, origin: origin,
            workingDirectory: workingDirectory, deskHandle: deskHandle)
        if Self.builderConversationReferenceSupplied(in: input) { entry["requireExistingConversation"] = .bool(true) }
        if pairReviewer { entry["pairReviewer"] = .bool(true) }
        if fyi { entry["expectsReply"] = .bool(false) }
        let inboxEntry = entry

        let quarantineNote = Self.BuilderInboxQuarantineNote()
        let appendResult: (status: String, retryWake: Bool, queuedAt: String)
        do {
            appendResult = try await Self.appendBuilderInboxMessage(
                messageId, entry: inboxEntry, to: inboxURL, queuedAt: timestamp,
                comparePairReviewer: true, maxLines: JSONLLineCaps.claudeBridgeInbox,
                logLabel: "SwiftToolDispatcher.claudeMessage",
                quarantine: quarantineNote, durable: true
            )
        } catch {
            var failure = Self.builderFailureFields(error, tool: "claude_message",
                reason: "inbox_write_failed", effects: .unknown, owner: inboxURL.path,
                instruction: "Reconcile this message_id against the preserved inbox and execution evidence before another send; this wake did not launch.")
            failure["messageId"] = .string(messageId)
            Self.stampBuilderInboxQuarantine(quarantineNote, on: &failure)
            return .object(failure)
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
        var response = conversation.queuedReceipt(entry: entry, filePath: inboxURL.path,
            queuedAt: appendResult.queuedAt, deduplicated: appendResult.status == "duplicate",
            replyWith: "agent.message")
        response.merge([
            "delivery": .string("queued"),
            "sent": .bool(true),
            "completed": .bool(false),
            "read": .bool(false),
            "detail": .string("Queued for \(who.name); acceptance is owed until its live session reads this message. Open that session and read this exact message with agent.read; do not resend it."),
            "remedy": door.remedy(),
        ]) { _, new in new }
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["detail"] = .string((Self.stringField("detail", in: .object(response)) ?? "") + " desk_item '\(droppedDeskItem)' is not a live Desk item; the message was queued without a Desk binding. Omit desk_item unless you have a live handle from app desk.read.")
        }
        if pairReviewer { response["reviewerPairRequested"] = .bool(true) }
        return .object(response)
    }

    /// Finish failed and skipped wakes without promising work that never started.
    /// Already-completed work retains its prior delivery evidence and reply.
    static func markWakeStartedNothing(_ response: inout [String: JSONValue], agent: String, dataRoot: URL) {
        let wakeup = response["wakeup"] ?? .null
        if let status = stringField("status", in: wakeup), ["failed", "blocked"].contains(status) {
            response["status"] = .string("failed")
            if let why = stringField("fix", in: wakeup) ?? stringField("message", in: wakeup) ?? stringField("detail", in: wakeup) {
                response["detail"] = .string(why)
            }
            return
        }
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
