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
        return .object(response)
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
            repoRoot: rootForRead
        ) else {
            return .object([
                "status": .string("skipped"),
                "reason": .string("helper_not_found"),
                "fix": .string("Install script/omp_thread_wakeup.js or set NATIVE_AGENT_OMP_WAKEUP_HELPER."),
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
        return await Self.runOMPWakeupHelper(helper: helper, inputData: inputData, cwd: cwd)
    }

    private static func runOMPWakeupHelper(helper: URL, inputData: Data, cwd: URL) async -> JSONValue {
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("node_runtime_not_found"),
                "helper": .string(helper.path),
            ])
        }
        var childEnvironment = environment
        if childEnvironment["NATIVE_AGENT_OMP_WAKE_BIN"] == nil,
           let omp = AgentBridgeRuntime.executableURL(named: "omp", environment: environment) {
            childEnvironment["NATIVE_AGENT_OMP_WAKE_BIN"] = omp.path
        }
        return await runBuilderWakeupHelper(
            node: node,
            helper: helper,
            inputData: inputData,
            cwd: cwd,
            environment: childEnvironment,
            timeoutSeconds: 30
        )
    }
}
