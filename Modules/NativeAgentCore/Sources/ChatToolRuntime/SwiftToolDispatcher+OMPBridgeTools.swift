import AgentWorkspace
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SwiftToolDispatcher+OMPBridgeTools.swift` | `SwiftToolDispatcher`: `runOMPMessage`, `ompSessionSaved` |

extension SwiftToolDispatcher {
    // MARK: - OMP asynchronous bridge

    /// The message contract the three bridge tools share: a non-empty text,
    /// and a priority of info, important or urgent (info when omitted).
    static func bridgeMessageFields(_ input: [String: JSONValue], tool: String)
        -> Result<(text: String, priority: String), BridgeArgumentRefusal> {
        func refuse(_ reason: String, _ fix: String) -> Result<(text: String, priority: String), BridgeArgumentRefusal> {
            .failure(BridgeArgumentRefusal(value: .object(["status": .string("failed"), "effects": .string("none"),
                                                 "reason": .string(reason), "fix": .string(fix)])))
        }
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return refuse("missing_text", "\(tool) requires a non-empty 'text' parameter.")
        }
        guard let given = input["priority"], given != .null else { return .success((text, "info")) }
        guard case .string(let raw) = given, ["info", "important", "urgent"].contains(raw.lowercased()) else {
            return refuse("invalid_priority", "\(tool) priority is info, important or urgent; nothing was sent.")
        }
        return .success((text, raw.lowercased()))
    }

    func runOMPMessage(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let text: String, priority: String
        switch Self.bridgeMessageFields(input, tool: "omp_message") {
        case .success(let fields): (text, priority) = fields
        case .failure(let refusal): return refusal.value
        }
        let (deskHandle, droppedDeskItem) = try await delegationDeskHandleDroppingStale(input)
        let requestedTopic: String? = {
            guard case .string(let raw)? = input["topic"] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value.prefix(120))
        }()
        let timeoutSeconds: Int = {
            if case .int(let value)? = input["timeout_seconds"] {
                return max(60, min(3600, Int(value)))
            }
            if case .double(let value)? = input["timeout_seconds"] {
                return Int(exactly: value.rounded(.towardZero)).map { max(60, min(3600, $0)) } ?? 900
            }
            return 900
        }()
        let requestedWorkingDirectory: String?
        switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
        case .success(let path): requestedWorkingDirectory = path
        case .failure(let envelope): return envelope
        }

        let returnPath = AgentBridgeRuntime.returnPathReadiness(configRoot: agentBridgeConfigRoot)
        guard returnPath.isReady else { return Self.returnBridgeUnavailableEnvelope(returnPath) }

        let directory = Self.bridgeConfigDirectory(
            named: "omp-bridge",
            configRootOverride: agentBridgeConfigRoot
        )
        let inboxURL = directory.appendingPathComponent("omp-inbox.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return .object(Self.builderFailureFields(error,
                tool: "omp_message", reason: "inbox_dir_create_failed", effects: .none,
                owner: directory.path,
                instruction: "Repair the OMP inbox directory's reported storage error. No message was queued."))
        }

        let messageId = Self.builderMessageId(input: input)
        let conversation: BuilderConversationSelection
        switch Self.builderConversationSelection(
            input: input,
            agent: .omp,
            topic: requestedTopic,
            messageId: messageId
        ) {
        case .success(let selection): conversation = selection
        case .failure(let error): return error.envelope
        }
        let topic = conversation.topic
        // Refuse a continuation with no saved session before admitting its message.
        if Self.builderConversationReferenceSupplied(in: input),
           !Self.ompSessionSaved(topic: topic, directory: directory) {
            return .object([
                "status": .string("unavailable"), "sent": .bool(false), "reason": .string("continuation_unavailable"),
                "conversationId": conversation.conversationId.map(JSONValue.string) ?? .null,
                "detail": .string("That OMP conversation's session no longer exists, so nothing was sent and no work started. Start a new conversation to ask again."),
            ])
        }
        let worktreeResult = try await BuilderWorktreeAllocator.shared.resolve(
            agent: .omp,
            conversationId: conversation.conversationId,
            messageId: messageId,
            isFollowUp: Self.builderConversationReferenceSupplied(in: input),
            requestedDirectory: requestedWorkingDirectory,
            defaultDirectory: nil,
            configRoot: builderWorktreeConfigRoot
        )
        let workingDirectory: String?
        var ignoredRequestedDirectory: String? = nil
        switch worktreeResult {
        case .unchanged(let path): workingDirectory = path
        case .assigned(let assignment):
            workingDirectory = assignment.workingDirectory
            ignoredRequestedDirectory = assignment.ignoredRequestedDirectory
        case .failed(let reason, let detail):
            return Self.builderWorktreeFailureEnvelope(reason: reason, detail: detail)
        }
        let queuedAt = NativeTimestampFormat.plainZulu(Date())
        let originSessionId = ChatToolSessionInjection.explicitSessionId(in: input)
        let origin = Self.agentBridgeReplyOrigin(surface: surface, route: ChatToolSessionContext.replyRoute)
        var row = conversation.inboxFields(messageId: messageId, queuedAt: queuedAt,
            priority: priority, text: text, sessionId: originSessionId, origin: origin,
            workingDirectory: workingDirectory, deskHandle: deskHandle)
        row["timeoutSeconds"] = .int(Int64(timeoutSeconds))
        let requireExistingConversation = Self.builderConversationReferenceSupplied(in: input)
        if requireExistingConversation { row["requireExistingConversation"] = .bool(true) }
        let inboxEntry = row

        let quarantineNote = Self.BuilderInboxQuarantineNote()
        let appendResult: (status: String, retryWake: Bool, queuedAt: String)
        do {
            appendResult = try await Self.appendBuilderInboxMessage(
                messageId, entry: inboxEntry, to: inboxURL, queuedAt: queuedAt,
                comparePairReviewer: false, maxLines: JSONLLineCaps.ompBridgeInbox,
                logLabel: "SwiftToolDispatcher.ompMessage",
                quarantine: quarantineNote
            )
        } catch {
            var fields = Self.builderFailureFields(error,
                tool: "omp_message", reason: "inbox_write_failed", effects: .unknown,
                owner: inboxURL.path,
                instruction: "Repair the reported inbox storage error from retained rows and message identities. Reconcile this message_id before another send; this wake did not launch.")
            fields["messageId"] = .string(messageId)
            Self.stampBuilderInboxQuarantine(quarantineNote, on: &fields)
            return .object(fields)
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

        var response = conversation.queuedReceipt(entry: row, filePath: inboxURL.path,
            queuedAt: appendResult.queuedAt, deduplicated: appendResult.status == "duplicate",
            replyWith: "omp_message")
        response["timeoutSeconds"] = .int(Int64(timeoutSeconds))
        response["note"] = .string("OMP's final reply returns as a separate bridge event. For a contextual follow-up, call omp_message with conversation_mode=resume and this conversationId. For unrelated work, use conversation_mode=new and omit conversation_id.")
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        if let topic { response["topic"] = .string(topic) }
        // Keep the ignored directory notice independent of the Desk-binding note.
        if let ignoredRequestedDirectory {
            response["workingDirectoryIgnored"] = .string(ignoredRequestedDirectory)
            response["directoryNote"] = .string(BuilderWorktreeAllocator.ignoredDirectoryNote)
        }
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["note"] = .string("desk_item '\(droppedDeskItem)' is not a live Desk item; the message was queued without a Desk binding. Omit desk_item unless you have a live handle from app desk.read.")
        }
        if appendResult.status == "duplicate" && !appendResult.retryWake {
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            if appendResult.status == "duplicate" { response["wakeupRetried"] = .bool(true) }
            response["wakeup"] = await postBuilderThreadWakeup(
                name: "OMP", surface: surface,
                payload: conversation.wakeFields(entry: inboxEntry, agent: .omp,
                    queuedAt: appendResult.queuedAt, inboxPath: inboxURL.path)
            )
        }
        Self.markWakeStartedNothing(&response, agent: "OMP", dataRoot: dataRoot)
        return .object(response)
    }

    /// The selected canonical topic names a saved session pointer with an id
    /// under wake-sessions/<slug>.json or, with no pointer file,
    /// a retained wake-unanswered/<slug>.json identity naming the session OMP
    /// kept, with failed deliveries as a legacy fallback.
    static func ompSessionSaved(topic: String?, directory: URL) -> Bool {
        let slug = topic ?? "general"
        func session(_ row: Any?) -> Bool {
            ((row as? [String: Any])?["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let file = directory.appendingPathComponent("wake-sessions").appendingPathComponent(slug + ".json")
        if let data = try? Data(contentsOf: file) { return session(try? JSONSerialization.jsonObject(with: data)) }
        let unanswered = directory.appendingPathComponent("wake-unanswered").appendingPathComponent(slug + ".json")
        if let data = try? Data(contentsOf: unanswered) { return session(try? JSONSerialization.jsonObject(with: data)) }
        guard let deliveries = try? String(contentsOf: directory.appendingPathComponent("wake-deliveries.jsonl"), encoding: .utf8) else { return false }
        return deliveries.split(separator: "\n").contains { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return row["topicSlug"] as? String == slug && row["status"] as? String == "failed" && session(row)
        }
    }

}
