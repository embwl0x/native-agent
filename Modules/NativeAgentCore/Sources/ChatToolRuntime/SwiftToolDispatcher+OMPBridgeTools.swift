import AgentWorkspace
import FeedPolicy
import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftToolDispatcher {
    // MARK: - OMP asynchronous bridge

    func runOMPMessage(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                "fix": .string("omp_message requires a non-empty 'text' parameter."),
            ])
        }
        let (deskHandle, droppedDeskItem) = try await delegationDeskHandleDroppingStale(input)
        let priority: String = {
            guard case .string(let raw)? = input["priority"] else { return "info" }
            let value = raw.lowercased()
            return ["info", "important", "urgent"].contains(value) ? value : "info"
        }()
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

        if ompMessageWakeupOverride == nil, ompMessageWakeupHelperOverride == nil {
            let returnPath = AgentBridgeRuntime.returnPathReadiness(configRoot: agentBridgeConfigRoot)
            guard returnPath.isReady else { return Self.returnBridgeUnavailableEnvelope(returnPath) }
        }

        let directory = Self.bridgeConfigDirectory(
            named: "omp-bridge",
            configRootOverride: agentBridgeConfigRoot
        )
        let inboxURL = directory.appendingPathComponent("omp-inbox.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_dir_create_failed"),
                "detail": .string(String(describing: error)),
            ])
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
        // The wake refuses a continuation whose saved session is gone
        // (continuation_unavailable) a moment after this returned "queued"
        // (walk 09-25). Its own rule, checked here first: failed now, nothing written.
        if ompMessageWakeupOverride == nil, ompMessageWakeupHelperOverride == nil,
           Self.builderConversationReferenceSupplied(in: input),
           !Self.ompSessionSaved(topic: topic, directory: directory) {
            return .object([
                "status": .string("unavailable"), "sent": .bool(false), "reason": .string("continuation_unavailable"),
                "conversationId": conversation.conversationId.map(JSONValue.string) ?? .null,
                "detail": .string("That OMP conversation's session no longer exists, so nothing was sent and no work started. Start a new conversation to ask again."),
            ])
        }
        let worktreeResult = await BuilderWorktreeAllocator.shared.resolve(
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
        let queuedAt = ISO8601DateFormatter().string(from: Date())
        let originSessionId = Self.extractSessionId(from: input)
        var row: [String: JSONValue] = [
            "id": .string(messageId),
            "messageId": .string(messageId),
            "createdAt": .string(queuedAt),
            "from": .string("assistant"),
            "priority": .string(priority),
            "text": .string(text),
            "timeoutSeconds": .int(Int64(timeoutSeconds)),
            "read": .bool(false),
        ]
        if let topic { row["topic"] = .string(topic) }
        if let conversationId = conversation.conversationId {
            row["conversationId"] = .string(conversationId)
        }
        let requireExistingConversation = Self.builderConversationReferenceSupplied(in: input)
        if requireExistingConversation { row["requireExistingConversation"] = .bool(true) }
        if let workingDirectory { row["workingDirectory"] = .string(workingDirectory) }
        if let deskHandle { row["deskHandle"] = .string(deskHandle) }
        if !originSessionId.isEmpty { row["sessionId"] = .string(originSessionId) }
        let inboxEntry = row

        let persistence = SwiftNativePersistenceCore()
        let quarantineNote = Self.BuilderInboxQuarantineNote()
        let appendResult: (status: String, retryWake: Bool, queuedAt: String)
        do {
            appendResult = try await Self.appendBuilderInboxMessage(
                messageId, entry: inboxEntry, to: inboxURL, queuedAt: queuedAt,
                comparePairReviewer: false, maxLines: JSONLLineCaps.ompBridgeInbox,
                logLabel: "SwiftToolDispatcher.ompMessage",
                persistence: persistence, quarantine: quarantineNote
            )
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_write_failed"),
                "detail": .string(String(describing: error)),
            ])
        }
        guard appendResult.status != "conflict" else {
            return .object([
                "status": .string("failed"),
                "reason": .string("message_id_conflict"),
                "messageId": .string(messageId),
            ])
        }

        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "messageId": .string(messageId),
            "deduplicated": .bool(appendResult.status == "duplicate"),
            "filePath": .string(inboxURL.path),
            "priority": .string(priority),
            "queuedAt": .string(appendResult.queuedAt),
            "timeoutSeconds": .int(Int64(timeoutSeconds)),
            "note": .string("OMP's final reply returns as a separate bridge event. For a contextual follow-up, call omp_message with conversation_mode=resume and this conversationId. For unrelated work, use conversation_mode=new and omit conversation_id."),
        ]
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        if let topic { response["topic"] = .string(topic) }
        if let conversationId = conversation.conversationId {
            response["conversationId"] = .string(conversationId)
            response["replyWith"] = .string("omp_message")
        }
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        // Same receipt promise as the other two lanes; this one discarded the
        // ignored input entirely (astra-comb-3 lane3 #4 / lane1 #4).
        if let ignoredRequestedDirectory {
            response["workingDirectoryIgnored"] = .string(ignoredRequestedDirectory)
            response["directoryNote"] = .string(BuilderWorktreeAllocator.ignoredDirectoryNote)
        }
        if let deskHandle { response["deskHandle"] = .string(deskHandle) }
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["note"] = .string("desk_item '\(droppedDeskItem)' is not a live Desk item; the message was delivered without a Desk binding. Omit desk_item unless you have a live handle from desk_read.")
        }
        if appendResult.status == "duplicate" && !appendResult.retryWake {
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            if appendResult.status == "duplicate" { response["wakeupRetried"] = .bool(true) }
            response["wakeup"] = await postOMPThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                requireExistingConversation: requireExistingConversation,
                queuedAt: appendResult.queuedAt,
                inboxPath: inboxURL.path,
                originSessionId: originSessionId,
                timeoutSeconds: timeoutSeconds,
                workingDirectory: workingDirectory,
                deskHandle: deskHandle
            )
        }
        // A wake that failed admitted nothing to act on the row; "queued" would
        // tell her the answer is coming (the Claude lane already says so).
        if Self.claudeReceiptStatus(response["wakeup"]) == "failed" { response["status"] = .string("failed") }
        Self.markWakeStartedNothing(&response, agent: "OMP")
        return .object(response)
    }

    /// omp_thread_wakeup.js's resume rule: a saved session pointer with an id
    /// under wake-sessions/<topicSlug(topic)>.json or, with no pointer file,
    /// a failed delivery of that topic that names the session OMP kept.
    static func ompSessionSaved(topic: String?, directory: URL) -> Bool {
        // topicSlug exactly: lowercase, every run of non-[a-z0-9] (per code
        // point, so "İ" → "i" + a separator) is one "-", trimmed, 64 long.
        var joined = ""
        var gap = false
        for scalar in (topic ?? "").lowercased().unicodeScalars {
            guard (97...122).contains(scalar.value) || (48...57).contains(scalar.value) else { gap = true; continue }
            if gap, !joined.isEmpty { joined += "-" }
            gap = false
            joined.unicodeScalars.append(scalar)
        }
        joined = String(joined.prefix(64))
        let slug = joined.isEmpty ? "general" : joined
        func session(_ row: Any?) -> Bool {
            ((row as? [String: Any])?["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let file = directory.appendingPathComponent("wake-sessions").appendingPathComponent(slug + ".json")
        if let data = try? Data(contentsOf: file) { return session(try? JSONSerialization.jsonObject(with: data)) }
        guard let deliveries = try? String(contentsOf: directory.appendingPathComponent("wake-deliveries.jsonl"), encoding: .utf8) else { return false }
        return deliveries.split(separator: "\n").contains { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return row["topicSlug"] as? String == slug && row["status"] as? String == "failed" && session(row)
        }
    }

    private func postOMPThreadWakeup(
        messageId: String,
        text: String,
        priority: String,
        topic: String?,
        requireExistingConversation: Bool,
        queuedAt: String,
        inboxPath: String,
        originSessionId: String,
        timeoutSeconds: Int,
        workingDirectory: String?,
        deskHandle: String?
    ) async -> JSONValue {
        var payload: [String: JSONValue] = [
            "messageId": .string(messageId),
            "text": .string(text),
            "priority": .string(priority),
            "queuedAt": .string(queuedAt),
            "inboxPath": .string(inboxPath),
            "source": .string("omp_message"),
            "timeoutSeconds": .int(Int64(timeoutSeconds)),
        ]
        if let topic { payload["topic"] = .string(topic) }
        if requireExistingConversation { payload["requireExistingConversation"] = .bool(true) }
        if !originSessionId.isEmpty { payload["sessionId"] = .string(originSessionId) }
        if let workingDirectory { payload["cwd"] = .string(workingDirectory) }
        if let deskHandle { payload["deskHandle"] = .string(deskHandle) }
        Self.stampDelegationProducer(on: &payload)
        if let ompMessageWakeupOverride { return await ompMessageWakeupOverride(payload) }
        // L1#14 replay guard — see postClaudeThreadWakeup for the four
        // conditions, why a lost/failed prior run is never suppressed, and why
        // this sits after the override.
        if !WakeupReplayGuard.isDisabled(),
           let match = WakeupReplayGuard.terminalDuplicate(
               store: .omp,
               jobsDirectory: WakeupReplayGuard.jobsDirectory(
                   for: .omp, configRoot: agentBridgeConfigRoot),
               topic: topic,
               text: text,
               now: Date()
           ) {
            return WakeupReplayGuard.receipt(match)
        }

        let disabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_OMP_WAKEUP_DISABLED"]?.lowercased()
        if ["1", "true", "yes"].contains(disabled ?? "") {
            return .object([
                "status": .string("skipped"),
                "reason": .string("disabled_by_environment"),
                "env": .string("NATIVE_AGENT_OMP_WAKEUP_DISABLED"),
            ])
        }
        guard let helper = AgentBridgeRuntime.ompHelperURL(
            override: ompMessageWakeupHelperOverride,
            dataRoot: dataRoot
        ) else {
            return .object([
                "status": .string("skipped"),
                "reason": .string("helper_not_found"),
                "expected": .string(AgentBridgeRuntime.expectedHelperPath(
                    named: "omp_thread_wakeup.js",
                    override: ompMessageWakeupHelperOverride,
                    dataRoot: dataRoot
                ).path),
                "fix": .string("Rebuild or reinstall NativeAgent so omp_thread_wakeup.js is at the expected path."),
            ])
        }
        let inputData: Data
        do {
            inputData = try JSONValue.object(payload).serializedData(pretty: false)
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("wakeup_payload_encode_failed"),
                "error": .string(String(describing: error)),
            ])
        }
        let cwd = Self.builderSourceRepoRoot(dataRoot: dataRoot)
            ?? NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        return await runAgentWakeupHelper(helper: helper, inputData: inputData, cwd: cwd,
                                         cli: "omp", variable: "NATIVE_AGENT_OMP_WAKE_BIN", timeout: 30)
    }
}
