import AgentWorkspace
import Foundation
import NativeAgentShared
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
// Blueprint: | `SwiftToolDispatcher+CodexBridgeTools.swift` | `SwiftToolDispatcher`: `codexBrainControls`, `agentBridgeReplyOrigin`, `runCodexMessage`; inbox admission delegates to `codex_wake_inbox_projection.js`, the sole inbox/history mutation owner, with the helper's directory lock; SubprocessWork settlement retains partial replies and writes the terminal audit and Runs projection |

extension SwiftToolDispatcher {
    // MARK: - Codex return-channel handler
    //
    // Agent calls `codex_message` when she wants to leave Codex an async
    // note for a future session. This intentionally mirrors claude_message's
    // durable JSONL inbox while also trying to post a local NativeAgent macOS
    // notification so the user/Codex sees the arrival without manual polling. The
    // notification leg is best-effort; inbox write remains the source of truth.
    struct CodexBrainControls: Sendable, Equatable {
        let model: String?
        let reasoningEffort: String?
        let serviceTier: String?
        let fast: Bool?

        var jsonValue: JSONValue {
            var object: [String: JSONValue] = [:]
            if let model { object["model"] = .string(model) }
            if let reasoningEffort { object["reasoningEffort"] = .string(reasoningEffort) }
            if let serviceTier { object["serviceTier"] = .string(serviceTier) }
            if let fast { object["fast"] = .bool(fast) }
            return .object(object)
        }
    }

    enum CodexBrainControlError: Error, Equatable {
        case invalidReasoningEffort(requested: String, model: String?, supported: [String])
        case invalidFastValue

        var envelope: JSONValue {
            switch self {
            case .invalidReasoningEffort(let requested, let model, let supported):
                var object: [String: JSONValue] = [
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("unsupported_reasoning_effort"),
                    "detail": .string("reasoning_effort \(requested) is not offered here; use one of supported."),
                    "requested": .string(requested),
                    "supported": .array(supported.map(JSONValue.string)),
                ]
                if let model { object["model"] = .string(model) }
                return .object(object)
            case .invalidFastValue:
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("invalid_fast_value"),
                    "fix": .string("fast must be true or false."),
                ])
            }
        }
    }

    static func codexBrainControls(
        from input: [String: JSONValue]
    ) -> Result<CodexBrainControls, CodexBrainControlError> {
        let model: String? = {
            guard case .string(let raw)? = input["model"] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }()
        let effort: String? = {
            guard case .string(let raw)? = input["reasoning_effort"] else { return nil }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            if ["extra_high", "extrahigh"].contains(normalized) { return "xhigh" }
            return normalized.isEmpty ? nil : normalized
        }()
        let fast: Bool?
        if let value = input["fast"], value != .null {
            guard case .bool(let requested) = value else {
                return .failure(.invalidFastValue)
            }
            fast = requested
        } else {
            fast = nil
        }

        if let effort {
            let supported: Set<String>
            if let model {
                supported = OpenAIExecutionControls.supportedReasoningEfforts(
                    model: model,
                    transport: .codexCLI
                )
            } else {
                supported = ["low", "medium", "high", "xhigh", "max", "ultra"]
            }
            guard supported.contains(effort) else {
                return .failure(.invalidReasoningEffort(
                    requested: effort,
                    model: model,
                    supported: supported.sorted()
                ))
            }
        }

        return .success(CodexBrainControls(
            model: model,
            reasoningEffort: effort,
            serviceTier: fast.map { $0 ? "priority" : "default" },
            fast: fast
        ))
    }

    static func agentBridgeReplyOrigin(
        surface: String,
        route: ChatToolSessionContext.ReplyRoute?
    ) -> JSONValue {
        let resolved = route ?? ChatToolSessionContext.ReplyRoute(
            surface: surface,
            destinationId: ChatToolSessionContext.verifiedChatId
        )
        return .object(resolved.stringFields.mapValues(JSONValue.string))
    }

    private func inferredRepositoryCheckout(fromRequestText text: String) -> String? {
        let candidates = Self.repositorySlugCandidates(inRequestText: text)
        guard !candidates.isEmpty else { return nil }
        var resolved: [String] = []
        for candidate in candidates {
            guard let checkout = GitHubCommandCheckoutResolver.resolve(
                repository: candidate,
                dataRoot: dataRoot
            ) else { continue }
            let path = checkout.standardizedFileURL.path
            if !resolved.contains(path) { resolved.append(path) }
            if resolved.count > 1 { return nil }
        }
        return resolved.count == 1 ? resolved[0] : nil
    }

    func runCodexMessage(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard AgentConversationDelivery.lane(for: "codex", dataRoot: dataRoot, bridgeConfigRoot: agentBridgeConfigRoot) != nil else {
            throw ToolFailureError("No contact carries this inbox door.", effects: .none, owner: "Saved agent contacts", nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]))
        }
        let text: String, priority: String
        switch Self.bridgeMessageFields(input, tool: "codex_message") {
        case .success(let fields): (text, priority) = fields
        case .failure(let refusal): return refusal.value
        }
        let (deskHandle, droppedDeskItem) = try await delegationDeskHandleDroppingStale(input)
        let pairReviewer: Bool
        switch Self.pairReviewerRequested(in: input) {
        case .success(let requested): pairReviewer = requested
        case .failure(let error): return error.value
        }
        let requestedTopic: String? = {
            guard case .string(let raw)? = input["topic"] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        let completionMode: String = {
            guard case .string(let raw)? = input["completion_mode"],
                  raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "receipt_only"
            else { return "report" }
            return "receipt_only"
        }()
        // Resolve the builder conversation before repository inference so a
        // follow-up remains the same worker thread while still using the new
        // message text/topic for trusted checkout selection.
        let messageId = Self.builderMessageId(input: input)
        let conversation: BuilderConversationSelection
        switch Self.builderConversationSelection(
            input: input,
            agent: .codex,
            topic: requestedTopic,
            messageId: messageId
        ) {
        case .success(let selection): conversation = selection
        case .failure(let error): return error.envelope
        }
        let topic = conversation.topic
        let originSessionId = ChatToolSessionInjection.explicitSessionId(in: input)
        let brain: CodexBrainControls
        switch Self.codexBrainControls(from: input) {
        case .success(let controls): brain = controls
        case .failure(let error): return error.envelope
        }
        let origin = Self.agentBridgeReplyOrigin(
            surface: surface,
            route: ChatToolSessionContext.replyRoute
        )
        let requestedDirectory: String?
        switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
        case .success(let path): requestedDirectory = path
        case .failure(let envelope): return envelope
        }
        let isFollowUp = Self.builderConversationReferenceSupplied(in: input)

        // Any caller may name an owner/name GitHub repository.
        // It is NOT a path -- the app resolves it through the remote-verified
        // resolver, so the trust
        // anchor stays "this checkout's git remote really is that repo" rather
        // than "the model said so". An unresolvable or malformed repository
        // yields nil and the send proceeds with today's no-profile behavior.
        let repositoryResolvedDirectory: String? = {
            guard !isFollowUp,
                  requestedDirectory == nil,
                  case .string(let raw)? = input["repository"] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isWellFormedRepositorySlug(value) else { return nil }
            guard let checkout = GitHubCommandCheckoutResolver.resolve(
                repository: value,
                dataRoot: dataRoot
            ) else { return nil }
            return checkout.standardizedFileURL.path
        }()

        // An omitted repository is inferred from the request and verified against the checkout remote.
        let inferredRepositoryDirectory: String? = {
            guard !isFollowUp,
                  requestedDirectory == nil,
                  repositoryResolvedDirectory == nil else { return nil }
            return inferredRepositoryCheckout(fromRequestText: [text, topic ?? ""].joined(separator: "\n"))
        }()

        let resolvedBaseDirectory = requestedDirectory
            ?? repositoryResolvedDirectory
            ?? inferredRepositoryDirectory
        let callerSelectedDirectory = requestedDirectory ?? repositoryResolvedDirectory
        let worktreeResult = try await BuilderWorktreeAllocator.shared.resolve(
            agent: .codex,
            conversationId: conversation.conversationId,
            messageId: messageId,
            isFollowUp: isFollowUp,
            requestedDirectory: callerSelectedDirectory,
            defaultDirectory: resolvedBaseDirectory,
            configRoot: builderWorktreeConfigRoot
        )
        let workingDirectory: String?
        let worktreeAssignment: BuilderWorktreeAllocator.Assignment?
        switch worktreeResult {
        case .unchanged(let path):
            workingDirectory = path
            worktreeAssignment = nil
        case .assigned(let assignment):
            workingDirectory = assignment.workingDirectory
            worktreeAssignment = assignment
        case .failed(let reason, let detail):
            return Self.builderWorktreeFailureEnvelope(reason: reason, detail: detail)
        }
        // This capability marker is created only from a remote-verified
        // repository checkout. It is never accepted from caller-supplied
        // working_directory, topic text, or repository-controlled prose.
        let executionProfile = (repositoryResolvedDirectory != nil
            || inferredRepositoryDirectory != nil)
            ? "github-command-repository-network-v1"
            : nil

        let returnPath = AgentBridgeRuntime.returnPathReadiness(configRoot: agentBridgeConfigRoot)
        guard returnPath.isReady else {
            return Self.returnBridgeUnavailableEnvelope(returnPath)
        }
        let dir = Self.bridgeConfigDirectory(
            named: "codex-nativeagent-bridge",
            configRootOverride: agentBridgeConfigRoot
        )
        let inboxURL = dir.appendingPathComponent("codex-inbox.jsonl")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            return .object(Self.builderFailureFields(error,
                tool: "codex_message", reason: "inbox_dir_create_failed", effects: .none,
                owner: dir.path,
                instruction: "Repair the Codex inbox directory's reported storage error. No message was queued."))
        }

        let timestamp = NativeTimestampFormat.plainZulu(Date())
        var entry = conversation.inboxFields(messageId: messageId, queuedAt: timestamp,
            priority: priority, text: text, sessionId: originSessionId, origin: origin,
            workingDirectory: workingDirectory, deskHandle: deskHandle)
        entry["brain"] = brain.jsonValue
        if let model = brain.model { entry["model"] = .string(model) }
        if let effort = brain.reasoningEffort { entry["reasoningEffort"] = .string(effort) }
        if let tier = brain.serviceTier { entry["serviceTier"] = .string(tier) }
        if let fast = brain.fast { entry["fast"] = .bool(fast) }
        if let executionProfile { entry["executionProfile"] = .string(executionProfile) }
        if pairReviewer { entry["pairReviewer"] = .bool(true) }
        if completionMode == "receipt_only" { entry["completionMode"] = .string(completionMode) }
        guard let helper = AgentBridgeRuntime.codexHelperURL(dataRoot: dataRoot) else {
            return .object([
                "status": .string("failed"), "reason": .string("helper_not_found"),
                "remedy": Self.builderFailureRemedy(owner: "NativeAgent app bundle / codex_thread_wakeup.js", instruction: "The bundled Codex wake helper is missing."),
            ])
        }
        let receipt = await runAgentWakeupHelper(
            helper: helper,
            inputData: try JSONValue.object(["inboxPath": .string(inboxURL.path), "entry": .object(entry)]).serializedData(pretty: false),
            cwd: dir,
            cli: "codex", variable: "CODEX_BIN", timeout: 40, launchArguments: ["--append-inbox"]
        )
        guard case .object(let fields) = receipt, case .string(let status)? = fields["status"],
              ["appended", "duplicate", "conflict"].contains(status) else {
            if case .object(var failure) = ChatToolOutcome.normalizedFailure(receipt, tool: "codex_message"),
               failure["reason"] == .string("inbox_write_failed"), failure["remedy"] == nil {
                failure["remedy"] = Self.builderFailureRemedy(owner: inboxURL.path,
                    instruction: "Repair the reported inbox storage error from retained rows and message identities. Reconcile this message_id before another send; this wake did not launch.")
                failure["messageId"] = .string(messageId)
                return .object(failure)
            }
            return receipt
        }
        let appendResult = (
            status: status,
            retryWake: fields["retryWake"] == .bool(true),
            queuedAt: Self.stringField("queuedAt", in: receipt) ?? timestamp
        )
        let quarantineNote = Self.BuilderInboxQuarantineNote()
        if let path = Self.stringField("quarantinedPath", in: receipt) { quarantineNote.record(path) }
        let path = inboxURL.path
        guard appendResult.status != "conflict" else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("message_id_conflict"),
                "detail": .string("That message_id already names a different message, so nothing was queued. Use a new message_id, or omit it."),
                "messageId": .string(messageId),
            ])
        }
        let deduplicated = appendResult.status == "duplicate"
        let retryUnacceptedWake = deduplicated && appendResult.retryWake
        var response = conversation.queuedReceipt(entry: entry, filePath: path,
            queuedAt: appendResult.queuedAt, deduplicated: deduplicated, replyWith: "codex_message")
        response.merge([
            "origin": origin,
            "brain": brain.jsonValue,
            "completionMode": .string(completionMode),
            "note": .string(completionMode == "receipt_only"
                ? "NativeAgent queues the note and records Codex's terminal receipt without creating another chat turn for the agent. Failures still return visibly."
                : "NativeAgent queues the inbox row, attempts a Mac notification, wakes Codex, and watches for the final answer. For a contextual follow-up, call codex_message with conversation_mode=resume and this conversationId. For unrelated work, use conversation_mode=new and omit conversation_id. If Codex is busy, the wake remains queued until that thread is idle."),
        ]) { _, new in new }
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        // Keep the ignored directory notice independent of the Desk-binding note.
        if let ignoredRequestedDirectory = worktreeAssignment?.ignoredRequestedDirectory {
            response["workingDirectoryIgnored"] = .string(ignoredRequestedDirectory)
            response["directoryNote"] = .string(BuilderWorktreeAllocator.ignoredDirectoryNote)
        }
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["note"] = .string("desk_item '\(droppedDeskItem)' is not a live Desk item; the message was queued without a Desk binding. Omit desk_item unless you have a live handle from app desk.read.")
        }
        if pairReviewer { response["reviewerPairRequested"] = .bool(true) }
        if let executionProfile {
            // Make repository attachment observable: a silently-applied profile is
            // indistinguishable from a silently-missing one at the call site.
            response["executionProfile"] = .string(executionProfile)
            response["repositorySource"] = .string(
                repositoryResolvedDirectory != nil ? "repository_parameter"
                    : "inferred_from_request"
            )
        }
        response["notification"] = await postCodexMessageArrivalNotification(
            surface: surface,
            messageId: messageId,
            text: text,
            priority: priority,
            topic: topic
        )
        if deduplicated && !retryUnacceptedWake {
            // The helper marks the inbox row consumed only after a Codex turn
            // and its reply job are both durable. That is authority that the
            // first wake really landed, so an identical resend must not poke
            // Codex again.
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            // A row can predate its wake: inbox persistence happens first, and
            // the app-server helper may then fail. Retrying that unconsumed row
            // is recovery, not duplicate execution. Pinned-thread pending
            // queues own their own message-id dedupe if the first wake was
            // accepted but has not reached an idle point yet.
            if retryUnacceptedWake { response["wakeupRetried"] = .bool(true) }
            let wakeup = await postBuilderThreadWakeup(
                name: "Codex", surface: surface,
                payload: conversation.wakeFields(entry: entry, agent: .codex,
                    queuedAt: appendResult.queuedAt, inboxPath: path)
            )
            response["wakeup"] = wakeup
            let conversationId = conversation.conversationId
                ?? Self.stringField("threadId", in: wakeup).map { "codex:\($0)" }
            if let conversationId {
                response["conversationId"] = .string(conversationId)
                response["replyWith"] = .string("codex_message")
            }
            if let worktreeAssignment,
               let threadId = Self.stringField("threadId", in: wakeup) {
                let binding = await BuilderWorktreeAllocator.shared.bind(
                    worktreeAssignment,
                    agent: .codex,
                    conversationId: "codex:\(threadId)",
                    configRoot: builderWorktreeConfigRoot
                )
                if case .failed(let reason, let detail) = binding {
                    response["worktreeFollowUpWarning"] = .string("\(reason): \(detail)")
                }
            }
        }
        Self.markWakeStartedNothing(&response, agent: "Codex", dataRoot: dataRoot)
        return .object(response)
    }


    private func postCodexMessageArrivalNotification(
        surface: String,
        messageId: String,
        text: String,
        priority: String,
        topic: String?
    ) async -> JSONValue {
        let admitted = await fullMacYoloAdmitted(surface: surface)
        let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMac, mode: .write, fullMacAdmitted: admitted)
        guard allowed else {
            return .object([
                "status": .string("skipped"),
                "posted": .bool(false),
                "reason": .string("mac_notifications_write_denied"),
                "integration": .string(MacIntegrationID.notifyMac),
                "messageId": .string(messageId),
                "fix": .string("Open Trust → Mac → Mac Notifications and enable Write."),
            ])
        }
        guard let bridge = macIntegrationBridge else {
            return .object([
                "status": .string("skipped"),
                "posted": .bool(false),
                "reason": .string("bridge_not_wired"),
                "messageId": .string(messageId),
                "fix": .string("NativeAgent app-side MacIntegrationToolBridge is not injected in this dispatcher."),
            ])
        }

        let title = Self.codexMessageNotificationTitle(priority: priority)
        let body = Self.codexMessageNotificationBody(text: text, topic: topic)
        do {
            let result = try await bridge.macNotify(input: [
                "title": .string(title),
                "message": .string(body),
                "source": .string("codex_message"),
                "messageId": .string(messageId),
            ])
            if case .object(var obj) = result {
                obj["trigger"] = .string("codex_message")
                obj["messageId"] = .string(messageId)
                return .object(obj)
            }
            return .object([
                "status": .string("completed"),
                "posted": .bool(true),
                "delivery": .string("mac_notify_returned_non_object"),
                "trigger": .string("codex_message"),
                "messageId": .string(messageId),
            ])
        } catch {
            var fields = Self.builderFailureFields(error,
                tool: "codex_message", reason: "mac_notification_failed", effects: .unknown,
                owner: "Codex arrival notification through mac.notify",
                instruction: "Inspect the reported notification error and its delivery state before another notification. The inbox message was saved.")
            fields["messageId"] = .string(messageId)
            return .object(fields)
        }
    }

    private static func codexMessageNotificationTitle(priority: String) -> String {
        switch priority {
        case "urgent":
            return "Urgent NativeAgent to Codex"
        case "important":
            return "Important NativeAgent to Codex"
        default:
            return "NativeAgent to Codex"
        }
    }

    private static func codexMessageNotificationBody(text: String, topic: String?) -> String {
        let preview = String(ChatSecretRedactor.redactText(text).prefix(220))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let topic, !topic.isEmpty {
            let safeTopic = String(ChatSecretRedactor.redactText(topic).prefix(160))
            return "[\(safeTopic)] \(preview)"
        }
        return preview
    }

    /// The Node helper owns an RPC timeout (12 seconds by default). Keep the
    /// outer Swift subprocess deadline several seconds longer so Node can close
    /// its app-server socket and emit a structured failure instead of being
    /// killed at the same instant as its inner timeout.
    static func codexWakeupHelperTimeoutSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        let rawMilliseconds = environment["NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS"]
            .flatMap(Int.init) ?? 12_000
        let boundedMilliseconds = min(120_000, max(5_000, rawMilliseconds))
        return TimeInterval(boundedMilliseconds + 8_000) / 1_000
    }
    // MARK: - invoke_codex spawn handler
    //
    // Spawns `codex exec` as a Process, waits for a bounded non-interactive
    // answer, and writes an audit envelope to data/from_codex/<uuid>.json.
    // JSON prompt/reply evidence and CLI last-message text stay local: no
    // backup/export/phone file sync; PrivacyMap: from_codex. Retention is 100 pairs.
    // The phone receives the separately recorded Runs projection.
    // This is the Codex-side twin of invoke_claude: Agent can ask Codex to
    // work a focused task, then continue with Codex's final reply.
    static func runInvokeCodex(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        launch: DrivenAgentLaunch
    ) async throws -> JSONValue {
        if let denied = launch.deniedResult { return denied }
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("missing_text"),
                "detail": .string("Pass the task for Codex as text, a non-empty string."),
            ])
        }
        let context: String = {
            if case .string(let c)? = input["context"] { return c }
            return ""
        }()
        let commitHash: String? = {
            if case .string(let h)? = input["commit_hash"], !h.isEmpty { return h }
            return nil
        }()
        let cwdRaw: String
        do { cwdRaw = try builderInvokeWorkingDirectory(input: input, dataRoot: dataRoot) }
        catch {
            return .object(["status": .string("failed"), "effects": .string("none"),
                "reason": .string("invalid_working_directory"), "detail": .string(error.localizedDescription)])
        }
        let timeoutSeconds: Int = {
            if case .int(let i)? = input["timeout_seconds"] { return max(30, min(3600, Int(i))) }
            return 600
        }()
        let sandbox: String = {
            if case .string(let s)? = input["sandbox"] {
                let lower = s.lowercased()
                if ["read-only", "workspace-write", "danger-full-access"].contains(lower) {
                    return lower
                }
            }
            return launch.permission.codexSandbox
        }()
        if sandbox == "danger-full-access", launch.permission != .fullMac {
            var denied: [String: JSONValue] = [
                "status": .string("denied"),
                "reason": .string("full_mac_required"),
                "sandbox": .string(sandbox),
                "message": .string("invoke_codex danger-full-access requires Full Mac. Retry with workspace-write or turn on Full Mac."),
            ]
            if let note = launch.note { denied["note"] = .string(note) }
            return .object(denied)
        }
        let brain: CodexBrainControls
        switch codexBrainControls(from: input) {
        case .success(let controls): brain = controls
        case .failure(let error): return error.envelope
        }
        let model = brain.model

        var promptParts: [String] = []
        promptParts.append("You are Codex running as a bounded subprocess spawned by NativeAgent.")
        if let commitHash {
            promptParts.append("Anchor commit: \(commitHash)")
        }
        if !context.isEmpty {
            promptParts.append("Context from NativeAgent:\n\(context)")
        }
        promptParts.append("Question/task:\n\(text)")
        let fullPrompt = promptParts.joined(separator: "\n\n")

        let runId = UUID().uuidString
        let started = Date()
        let auditDir = dataRoot
            .appendingPathComponent("from_codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        let auditURL = auditDir.appendingPathComponent("\(runId).json")
        let lastMessageURL = auditDir.appendingPathComponent("\(runId)-last-message.txt")

        let environment = AgentBridgeRuntime.processEnvironment()
        guard let codex = launch.executable.map({ URL(fileURLWithPath: $0) })
                ?? AgentBridgeRuntime.executableURL(named: "codex", environment: environment) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("codex_cli_not_found"),
                "fix": .string("Install and sign in to Codex CLI, then restart NativeAgent."),
            ])
        }
        let process = Process()
        process.executableURL = codex
        var args = codexExecArguments(
            sandbox: sandbox,
            approvalPolicy: launch.permission.codexApprovalPolicy,
            cwd: cwdRaw,
            lastMessagePath: lastMessageURL.path,
            model: model,
            reasoningEffort: brain.reasoningEffort,
            serviceTier: brain.serviceTier,
            prompt: fullPrompt
        )
        if input["skip_git_repo_check"] == .bool(true) { args.insert("--skip-git-repo-check", at: 2) }
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwdRaw)
        process.environment = environment

        let outputCapture = try InvokeOutputCapture(process: process)

        return await SubprocessWork(process).run(timeoutSeconds: timeoutSeconds) { exit in
            let (stdoutText, stderrText) = outputCapture.finish()
            let header = stderrText.components(separatedBy: "--------").dropFirst().first ?? ""
            let fields = Dictionary(header.split(separator: "\n").compactMap { line -> (String, String)? in
                let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return pair.count == 2 && !pair[1].isEmpty ? (pair[0], pair[1]) : nil
            }, uniquingKeysWith: { first, _ in first })
            let reportedBrain = CodexBrainControls(model: fields["model"], reasoningEffort: fields["reasoning effort"],
                serviceTier: fields["service tier"], fast: nil)
            let brainSource = header.isEmpty ? "unreported" : "codex_cli_header"
            let lastMessage = (try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? ""
            let replyText = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdoutText
                : lastMessage
            let exitCode = exit.code
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            let didTimeOut = exit.timedOut
            let cancelled = exit.stopped
            let status = cancelled ? "stopped" : exitCode == 0 ? "completed" : "failed"

            var auditEntry: [String: Any] = [
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(started),
                "completedAt": NativeTimestampFormat.plainZulu(Date()),
                "durationMs": durationMs,
                "exitCode": Int(exitCode),
                "cwd": cwdRaw,
                "sandbox": sandbox,
                "timeoutSeconds": timeoutSeconds,
                "timedOut": didTimeOut,
                "cancelled": cancelled,
                "status": status,
                "outcome": "settled",
                "prompt": fullPrompt,
                "reply": replyText,
                "stdout": stdoutText,
                "stderr": stderrText,
                "lastMessagePath": lastMessageURL.path,
                "brainSource": brainSource,
            ]
            if let commitHash { auditEntry["commitHash"] = commitHash }
            if let model = reportedBrain.model { auditEntry["model"] = model }
            if let effort = reportedBrain.reasoningEffort { auditEntry["reasoningEffort"] = effort }
            if let tier = reportedBrain.serviceTier { auditEntry["serviceTier"] = tier }
            if let fast = brain.fast { auditEntry["fast"] = fast }
            let auditError: String?
            do {
                try JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted])
                    .write(to: auditURL, options: .atomic)
                Self.trimAgentBridgeAudits(in: auditDir)
                auditError = nil
            } catch { auditError = String(describing: error) }

            let completed = exitCode == 0 && !cancelled
            let terminalStatus = auditError == nil ? status : "failed"
            let reason = completed ? nil : didTimeOut ? "timeout_after_\(timeoutSeconds)s" : cancelled ? "stopped"
                : exit.launchError != nil ? "spawn_failed" : "subprocess_exit_\(exitCode)"
            let detail: String? = if let auditError {
                "The captured reply is returned, but its audit could not be saved: \(auditError)"
            } else if let error = exit.launchError {
                ChatToolOutcome.errorMessage(ToolFailureError(error, effects: .none, code: "spawn_failed"))
            } else if !completed {
                exit.launched ? "The process ended. Its partial reply and captured output are saved; any changes already made remain."
                    : "Stopped before launch. Nothing ran."
            } else { nil }
            var result: JSONValue
            if completed {
                result = .object([
                    "status": .string("completed"),
                    "runId": .string(runId),
                    "reply": .string(replyText),
                    "durationMs": .int(Int64(durationMs)),
                    "exitCode": .int(Int64(exitCode)),
                    "sandbox": .string(sandbox),
                    "launch": launch.receipt,
                    "brain": reportedBrain.jsonValue,
                    "brain_source": .string(brainSource),
                    "requested_brain": brain.jsonValue,
                    "auditPath": .string(auditURL.path),
                ])
            } else {
                result = .object([
                    "status": .string(status),
                    "outcome": .string("settled"),
                    "reason": reason.map(JSONValue.string) ?? .null,
                    "runId": .string(runId),
                    "reply": .string(replyText),
                    "stderr": .string(stderrText),
                    "durationMs": .int(Int64(durationMs)),
                    "exitCode": .int(Int64(exitCode)),
                    "timedOut": .bool(didTimeOut),
                    "sandbox": .string(sandbox),
                    "brain": reportedBrain.jsonValue,
                    "brain_source": .string(brainSource),
                    "requested_brain": brain.jsonValue,
                    "auditPath": .string(auditURL.path),
                    "detail": detail.map(JSONValue.string) ?? .null,
                ])
                if let error = exit.launchError, case .object(var fields) = result {
                    fields.merge(Self.builderFailureFields(
                        ToolFailureError(error, effects: .none, code: "spawn_failed"),
                        tool: "invoke_codex", reason: "spawn_failed", effects: .none,
                        owner: "Codex process launch at \(codex.path) in \(cwdRaw)",
                        instruction: "Repair the reported Codex executable or working-directory launch error. Codex did not launch."),
                        uniquingKeysWith: { _, cause in cause })
                    result = .object(fields)
                }
            }
            if let auditError, case .object(var fields) = result {
                fields["status"] = .string(terminalStatus)
                fields["audit_error"] = .string(auditError)
                fields["detail"] = detail.map(JSONValue.string) ?? .null
                result = .object(fields)
            }
            let ledgerStatus = terminalStatus == "completed" ? "succeeded"
                : !completed && didTimeOut ? "timeout" : terminalStatus
            let diagnostics = ledgerStatus == "succeeded" ? [] : [reason, detail, completed ? nil : stderrText]
                .compactMap { $0 }.filter { !$0.isEmpty }
            await RunLedger.append(id: runId, kind: "codex", status: ledgerStatus, model: model,
                prompt: fullPrompt, output: replyText.isEmpty ? nil : replyText,
                error: diagnostics.isEmpty ? nil : diagnostics.joined(separator: "\n"),
                createdAt: started, durationSeconds: Date().timeIntervalSince(started), dataRoot: dataRoot)
            return result
        }
    }

    static func codexExecArguments(
        sandbox: String,
        approvalPolicy: String,
        cwd: String,
        lastMessagePath: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        prompt: String
    ) -> [String] {
        var args = [
            "codex", "exec",
            "--ephemeral",
            "--sandbox", sandbox,
            "-c", "approval_policy=\"\(approvalPolicy)\"",
            "-C", cwd,
            "--color", "never",
            "-o", lastMessagePath,
        ]
        if let model {
            args.append(contentsOf: ["-m", model])
        }
        if let reasoningEffort {
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""])
        }
        if let serviceTier {
            args.append(contentsOf: ["-c", "service_tier=\"\(serviceTier)\""])
        }
        args.append(prompt)
        return args
    }
}
