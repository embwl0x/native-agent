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
                    "status": .string("failed"),
                    "reason": .string("unsupported_reasoning_effort"),
                    "requested": .string(requested),
                    "supported": .array(supported.map(JSONValue.string)),
                ]
                if let model { object["model"] = .string(model) }
                return .object(object)
            case .invalidFastValue:
                return .object([
                    "status": .string("failed"),
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
        if let value = input["fast"] {
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

    private static func codexReplyOrigin(
        surface: String,
        route: ChatToolSessionContext.ReplyRoute?
    ) -> JSONValue {
        let resolved = route ?? ChatToolSessionContext.ReplyRoute(
            surface: surface,
            destinationId: ChatToolSessionContext.verifiedChatId
        )
        var object: [String: JSONValue] = ["surface": .string(resolved.surface)]
        if let value = resolved.destinationId { object["destinationId"] = .string(value) }
        if let value = resolved.threadId { object["threadId"] = .string(value) }
        if let value = resolved.sourceKey { object["sourceKey"] = .string(value) }
        if let value = resolved.replyTo { object["replyTo"] = .string(value) }
        if let value = resolved.correlationId { object["correlationId"] = .string(value) }
        return .object(object)
    }

    private func inferredRepositoryCheckout(fromRequestText text: String) -> String? {
        let candidates = Self.repositorySlugCandidates(inRequestText: text)
        guard !candidates.isEmpty else { return nil }
        var resolved: [String] = []
        for candidate in candidates {
            guard let checkout = GitHubCommandCheckoutResolver.resolve(
                repository: candidate,
                headSHA: nil,
                dataRoot: dataRoot
            ) else { continue }
            let path = checkout.standardizedFileURL.path
            if !resolved.contains(path) { resolved.append(path) }
            if resolved.count > 1 { return nil }
        }
        return resolved.count == 1 ? resolved[0] : nil
    }

    func runCodexMessage(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                "fix": .string("codex_message requires a non-empty 'text' parameter."),
            ])
        }
        let (deskHandle, droppedDeskItem) = try await delegationDeskHandleDroppingStale(input)
        let pairReviewer: Bool
        switch Self.pairReviewerRequested(in: input) {
        case .success(let requested): pairReviewer = requested
        case .failure(let error): return error.value
        }
        let priority: String = {
            if case .string(let p)? = input["priority"] {
                let lower = p.lowercased()
                if ["info", "important", "urgent"].contains(lower) { return lower }
            }
            return "info"
        }()
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
        let originSessionId = Self.extractSessionId(from: input)
        let brain: CodexBrainControls
        switch Self.codexBrainControls(from: input) {
        case .success(let controls): brain = controls
        case .failure(let error): return error.envelope
        }
        let origin = Self.codexReplyOrigin(
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
        // It is NOT a path -- the app resolves it through the same
        // remote-verified resolver the GitHub Command lane uses, so the trust
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
                headSHA: nil,
                dataRoot: dataRoot
            ) else { return nil }
            return checkout.standardizedFileURL.path
        }()

        // If nobody named a repository, infer one from the
        // request itself. Same resolver, same remote-verified trust anchor as
        // path B -- this only removes the caller's obligation to remember the
        // parameter, which is what cost the 2026-08-05 turn every GitHub path.
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
        let worktreeResult = await BuilderWorktreeAllocator.shared.resolve(
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

        if codexMessageWakeupOverride == nil, codexMessageWakeupHelperOverride == nil {
            let returnPath = AgentBridgeRuntime.returnPathReadiness(configRoot: agentBridgeConfigRoot)
            guard returnPath.isReady else {
                return Self.returnBridgeUnavailableEnvelope(returnPath)
            }
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
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_dir_create_failed"),
                "detail": .string(String(describing: error)),
            ])
        }

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
        if !originSessionId.isEmpty { entry["sessionId"] = .string(originSessionId) }
        entry["origin"] = origin
        entry["brain"] = brain.jsonValue
        if let model = brain.model { entry["model"] = .string(model) }
        if let effort = brain.reasoningEffort { entry["reasoningEffort"] = .string(effort) }
        if let tier = brain.serviceTier { entry["serviceTier"] = .string(tier) }
        if let fast = brain.fast { entry["fast"] = .bool(fast) }
        if let workingDirectory { entry["workingDirectory"] = .string(workingDirectory) }
        if let executionProfile { entry["executionProfile"] = .string(executionProfile) }
        if let deskHandle { entry["deskHandle"] = .string(deskHandle) }
        if pairReviewer { entry["pairReviewer"] = .bool(true) }
        if completionMode == "receipt_only" { entry["completionMode"] = .string(completionMode) }
        let inboxEntry = entry

        let persistence = SwiftNativePersistenceCore()
        let quarantineNote = Self.BuilderInboxQuarantineNote()
        let appendResult: (status: String, retryWake: Bool, queuedAt: String)
        do {
            appendResult = try await Self.withCodexInboxDirectoryLock(bridgeDirectory: dir) {
                try await persistence.withFileLock(inboxURL) {
                    let existing = try await Self.checkedBuilderInboxMessage(messageId, inboxURL: inboxURL, persistence: persistence, quarantine: quarantineNote)
                    if case .object(let object)? = existing {
                        // Inbox persistence precedes helper admission. An explicit
                        // retry must keep that exact work order, including its
                        // reply route and requested brain, even if no helper job
                        // exists yet to supply canonical duplicate protection.
                        let operationFields = [
                            "text", "topic", "conversationId", "workingDirectory",
                            "executionProfile", "deskHandle", "completionMode", "pairReviewer",
                            "sessionId", "origin", "brain", "priority",
                            "model", "reasoningEffort", "serviceTier", "fast",
                        ]
                        guard operationFields.allSatisfy({ object[$0] == inboxEntry[$0] }) else {
                            return ("conflict", false, timestamp)
                        }
                        // GitHub commands intentionally may have no chat session;
                        // equality of the stored origin still binds their route.
                        return ("duplicate", Self.builderInboxAllowsExplicitWakeRetry(object, requiresSession: false),
                                Self.stringField("createdAt", in: .object(object)) ?? timestamp)
                    }
                    try await persistence.appendJSONL(.object(inboxEntry), to: inboxURL)
                    return ("appended", false, timestamp)
                }
            }
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_write_failed"),
                "detail": .string(String(describing: error)),
            ])
        }
        let path = inboxURL.path
        guard appendResult.status != "conflict" else {
            return .object([
                "status": .string("failed"),
                "reason": .string("message_id_conflict"),
                "messageId": .string(messageId),
            ])
        }
        let deduplicated = appendResult.status == "duplicate"
        let retryUnacceptedWake = deduplicated && appendResult.retryWake
        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "messageId": .string(messageId),
            "deduplicated": .bool(deduplicated),
            "filePath": .string(path),
            "priority": .string(priority),
            "queuedAt": .string(appendResult.queuedAt),
            "origin": origin,
            "brain": brain.jsonValue,
            "completionMode": .string(completionMode),
            "note": .string(completionMode == "receipt_only"
                ? "NativeAgent queues the note and records Codex's terminal receipt without creating another chat turn for the agent. Failures still return visibly."
                : "NativeAgent queues the inbox row, attempts a Mac notification, wakes Codex, and watches for the final answer. For a contextual follow-up, call codex_message with conversation_mode=resume and this conversationId. For unrelated work, use conversation_mode=new and omit conversation_id. If Codex is busy, the wake remains queued until that thread is idle."),
        ]
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        // The schema's "ignored and noted on the receipt" promise, kept on this
        // lane too: the assignment was already retained, but what the follow-up
        // asked for was dropped silently. `directoryNote` is a distinct key so
        // it cannot be overwritten by the Desk-binding note below.
        if let ignoredRequestedDirectory = worktreeAssignment?.ignoredRequestedDirectory {
            response["workingDirectoryIgnored"] = .string(ignoredRequestedDirectory)
            response["directoryNote"] = .string(BuilderWorktreeAllocator.ignoredDirectoryNote)
        }
        if let deskHandle { response["deskHandle"] = .string(deskHandle) }
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["note"] = .string("desk_item '\(droppedDeskItem)' is not a live Desk item; the message was delivered without a Desk binding. Omit desk_item unless you have a live handle from desk_read.")
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
        if let conversationId = conversation.conversationId {
            response["conversationId"] = .string(conversationId)
            response["replyWith"] = .string("codex_message")
        }
        response["notification"] = await postCodexMessageArrivalNotification(
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
            let wakeup = await postCodexThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                queuedAt: appendResult.queuedAt,
                inboxPath: path,
                originSessionId: originSessionId,
                origin: origin,
                brain: brain,
                threadId: conversation.resumeId,
                workingDirectory: workingDirectory,
                executionProfile: executionProfile,
                deskHandle: deskHandle,
                pairReviewer: pairReviewer,
                completionMode: completionMode
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
        return .object(response)
    }

    /// The Codex inbox has TWO writers with two different locks: this process
    /// appends under `flock` on `codex-inbox.jsonl.lock`, and
    /// `script/codex_thread_wakeup.js` rewrites the WHOLE FILE (read, mark
    /// read, rename over it) under the mkdir lock `.codex-inbox.lock`. The two
    /// never excluded each other, so an append that landed between the
    /// helper's read and its rename was erased — a queued message that
    /// reported "queued" and then simply did not exist. Node has no `flock`,
    /// so this side takes the helper's directory lock as well: mkdir is atomic,
    /// and taking it OUTSIDE the flock keeps one lock order for both writers.
    ///
    /// Same protocol as `withDirLock` in the helper: a `pid` file for
    /// diagnosis, and a lock older than `staleSeconds` is a dead owner's and
    /// may be removed.
    ///
    /// 2026-09-06: a wait that timed out used to proceed WITHOUT the directory
    /// lock, which is exactly the erase race this lock exists to close — an
    /// append that lands between the helper's read and its rename is gone, and
    /// the caller is told "queued". Non-EEXIST `mkdir` failures took the same
    /// unlocked path. The wait is 30s now, and running out of it fails the tool
    /// call instead: the message is not lost, because the caller sees the
    /// failure and still holds it.
    private static func withCodexInboxDirectoryLock<T: Sendable>(
        bridgeDirectory: URL,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let waitSeconds: TimeInterval = 30
        let staleSeconds: TimeInterval = 10 * 60
        let lockDir: URL = {
            if let override = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_INBOX_LOCK"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return bridgeDirectory.appendingPathComponent(".codex-inbox.lock", isDirectory: true)
        }()
        let deadline = Date().addingTimeInterval(waitSeconds)
        var held = false
        while true {
            if mkdir(lockDir.path, 0o700) == 0 {
                held = true
                try? Data("\(getpid())\n\(ISO8601DateFormatter().string(from: Date()))\n\n".utf8)
                    .write(to: lockDir.appendingPathComponent("pid"), options: .atomic)
                break
            }
            let mkdirErrno = errno
            guard mkdirErrno == EEXIST else {
                throw PersistenceCoreError.ioFailure(
                    "codex inbox lock at \(lockDir.path) could not be taken (errno \(mkdirErrno)); "
                    + "the message was not queued"
                )
            }
            if let modified = (try? FileManager.default.attributesOfItem(
                atPath: lockDir.path
            )[.modificationDate]) as? Date,
               Date().timeIntervalSince(modified) > staleSeconds {
                try? FileManager.default.removeItem(at: lockDir)
                continue
            }
            guard Date() < deadline else {
                throw PersistenceCoreError.ioFailure(
                    "codex inbox lock at \(lockDir.path) still held after \(Int(waitSeconds))s; "
                    + "the message was not queued — retry once the Codex helper releases it"
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        defer {
            if held { try? FileManager.default.removeItem(at: lockDir) }
        }
        return try await body()
    }

    private func postCodexMessageArrivalNotification(
        messageId: String,
        text: String,
        priority: String,
        topic: String?
    ) async -> JSONValue {
        let allowed: Bool
        if let codexMessageNotificationPermissionOverride {
            allowed = codexMessageNotificationPermissionOverride
        } else {
            allowed = await MacIntegrationPermissionStore.shared.allows(MacIntegrationID.notifyMac, mode: .write)
        }
        guard allowed else {
            return .object([
                "status": .string("skipped"),
                "posted": .bool(false),
                "reason": .string("mac_notifications_write_denied"),
                "integration": .string(MacIntegrationID.notifyMac),
                "messageId": .string(messageId),
                "fix": .string("Toggle Write ON for Mac Notifications in Settings -> Mac Integration."),
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
            return .object([
                "status": .string("failed"),
                "posted": .bool(false),
                "reason": .string("mac_notification_failed"),
                "messageId": .string(messageId),
                "error": .string(String(describing: error)),
            ])
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
        let preview = ChatSecretRedactor.redactText(String(text.prefix(220)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let topic, !topic.isEmpty {
            return "[\(topic)] \(preview)"
        }
        return preview
    }

    private func postCodexThreadWakeup(
        messageId: String,
        text: String,
        priority: String,
        topic: String?,
        queuedAt: String,
        inboxPath: String,
        originSessionId: String,
        origin: JSONValue,
        brain: CodexBrainControls,
        threadId: String?,
        workingDirectory: String?,
        executionProfile: String?,
        deskHandle: String?,
        pairReviewer: Bool,
        completionMode: String
    ) async -> JSONValue {
        if let codexMessageWakeupOverride {
            var payload: [String: JSONValue] = [
                "messageId": .string(messageId),
                "text": .string(text),
                "priority": .string(priority),
                "queuedAt": .string(queuedAt),
                "inboxPath": .string(inboxPath),
                "source": .string("codex_message"),
            ]
            if let topic { payload["topic"] = .string(topic) }
            if !originSessionId.isEmpty { payload["sessionId"] = .string(originSessionId) }
            payload["origin"] = origin
            payload["brain"] = brain.jsonValue
            if let model = brain.model { payload["model"] = .string(model) }
            if let effort = brain.reasoningEffort { payload["reasoningEffort"] = .string(effort) }
            if let tier = brain.serviceTier { payload["serviceTier"] = .string(tier) }
            if let fast = brain.fast { payload["fast"] = .bool(fast) }
            if let threadId { payload["threadId"] = .string(threadId) }
            if let workingDirectory { payload["workingDirectory"] = .string(workingDirectory) }
            if let executionProfile { payload["executionProfile"] = .string(executionProfile) }
            if let deskHandle { payload["deskHandle"] = .string(deskHandle) }
            if pairReviewer { payload["pairReviewer"] = .bool(true) }
            if completionMode == "receipt_only" { payload["completionMode"] = .string(completionMode) }
            Self.stampDelegationProducer(on: &payload)
            return await codexMessageWakeupOverride(payload)
        }

        // L1#14 replay guard. The codex store UNLINKS a delivered reply-job, so
        // a terminal record still present in reply-jobs/ is one whose work
        // finished and whose handoff is pending recovery — re-firing would
        // duplicate the run. `undelivered/` is deliberately not scanned, so an
        // undeliverable job stays re-askable. After the override for the same
        // hermeticity reason as postClaudeThreadWakeup.
        if !WakeupReplayGuard.isDisabled(),
           let match = WakeupReplayGuard.terminalDuplicate(
               store: .codex,
               jobsDirectory: WakeupReplayGuard.jobsDirectory(
                   for: .codex, configRoot: agentBridgeConfigRoot),
               topic: topic,
               text: text,
               now: Date()
           ) {
            return WakeupReplayGuard.receipt(match)
        }

        let disabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_WAKEUP_DISABLED"]?.lowercased()
        if ["1", "true", "yes"].contains(disabled ?? "") {
            return .object([
                "status": .string("skipped"),
                "reason": .string("disabled_by_environment"),
                "env": .string("NATIVE_AGENT_CODEX_WAKEUP_DISABLED"),
            ])
        }

        guard let helper = AgentBridgeRuntime.codexHelperURL(
            override: codexMessageWakeupHelperOverride,
            repoRoot: rootForRead
        ) else {
            return .object([
                "status": .string("skipped"),
                "reason": .string("helper_not_found"),
                "fix": .string("Install script/codex_thread_wakeup.js or set NATIVE_AGENT_CODEX_WAKEUP_HELPER."),
            ])
        }

        var payload: [String: JSONValue] = [
            "messageId": .string(messageId),
            "text": .string(text),
            "priority": .string(priority),
            "queuedAt": .string(queuedAt),
            "inboxPath": .string(inboxPath),
            "source": .string("codex_message"),
        ]
        if let topic { payload["topic"] = .string(topic) }
        if !originSessionId.isEmpty { payload["sessionId"] = .string(originSessionId) }
        payload["origin"] = origin
        payload["brain"] = brain.jsonValue
        if let model = brain.model { payload["model"] = .string(model) }
        if let effort = brain.reasoningEffort { payload["reasoningEffort"] = .string(effort) }
        if let tier = brain.serviceTier { payload["serviceTier"] = .string(tier) }
        if let fast = brain.fast { payload["fast"] = .bool(fast) }
        if let threadId { payload["threadId"] = .string(threadId) }
        if let workingDirectory { payload["workingDirectory"] = .string(workingDirectory) }
        if let executionProfile { payload["executionProfile"] = .string(executionProfile) }
        if let deskHandle { payload["deskHandle"] = .string(deskHandle) }
        if pairReviewer { payload["pairReviewer"] = .bool(true) }
        if completionMode == "receipt_only" { payload["completionMode"] = .string(completionMode) }
        Self.stampDelegationProducer(on: &payload)

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
        return await Self.runCodexWakeupHelper(helper: helper, inputData: inputData, cwd: cwd)
    }

    private static func runCodexWakeupHelper(helper: URL, inputData: Data, cwd: URL) async -> JSONValue {
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("node_runtime_not_found"),
                "helper": .string(helper.path),
                "fix": .string("Install Node.js, then restart NativeAgent."),
            ])
        }
        var childEnvironment = environment
        if childEnvironment["CODEX_BIN"] == nil,
           let codex = AgentBridgeRuntime.executableURL(named: "codex", environment: environment) {
            childEnvironment["CODEX_BIN"] = codex.path
        }
        return await runBuilderWakeupHelper(
            node: node,
            helper: helper,
            inputData: inputData,
            cwd: cwd,
            environment: childEnvironment,
            timeoutSeconds: codexWakeupHelperTimeoutSeconds()
        )
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
    // This is the Codex-side twin of invoke_claude: Agent can ask Codex to
    // work a focused task, then continue with Codex's final reply.
    static func runInvokeCodex(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
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
        let cwdRaw = builderInvokeWorkingDirectory(input: input, dataRoot: dataRoot)
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
            return "workspace-write"
        }()
        if sandbox == "danger-full-access" {
            // Same root as the audit write below — policy and audit must
            // never diverge on a privileged path (gpt-5.5 review catch).
            let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
            guard codexDangerFullAccessAllowed(policy: policy) else {
                return .object([
                    "status": .string("denied"),
                    "reason": .string("developer_mode_required"),
                    "sandbox": .string(sandbox),
                    "message": .string("invoke_codex danger-full-access requires Developer Mode. Retry with workspace-write or enable Developer Mode locally."),
                ])
            }
        }
        let brain: CodexBrainControls
        switch codexBrainControls(from: input) {
        case .success(let controls): brain = controls
        case .failure(let error): return error.envelope
        }
        let model = brain.model

        var promptParts: [String] = []
        promptParts.append("You are Codex running as a bounded subprocess spawned by NativeAgent.")
        promptParts.append("Return a concise final answer with what you did, what you checked, and any follow-up.")
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
        guard let codex = AgentBridgeRuntime.executableURL(named: "codex", environment: environment) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("codex_cli_not_found"),
                "fix": .string("Install and sign in to Codex CLI, then restart NativeAgent."),
            ])
        }
        let process = Process()
        process.executableURL = codex
        let args = codexExecArguments(
            sandbox: sandbox,
            cwd: cwdRaw,
            lastMessagePath: lastMessageURL.path,
            model: model,
            reasoningEffort: brain.reasoningEffort,
            serviceTier: brain.serviceTier,
            prompt: fullPrompt
        )
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwdRaw)
        process.environment = environment

        let outputCapture = InvokeOutputCapture(process: process)

        // Watchdog-timeout latch — mirrors invoke_claude so a kill by OUR
        // watchdog reports as a timeout, not an anonymous subprocess_exit_143
        // (gpt-5.5 review MED, 2026-07-02).
        let timedOutFlag = AtomicFlag()
        let cancellation = InvokeCancellation()
        let result: JSONValue = await withTaskCancellationHandler {
          await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                let (stdoutText, stderrText) = outputCapture.finish()
                let lastMessage = (try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? ""
                let replyText = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? stdoutText
                    : lastMessage
                let exitCode = proc.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                // Only report a timeout when the exit was actually fatal —
                // same clean-exit-vs-watchdog edge guard as invoke_claude.
                let didTimeOut = timedOutFlag.isSet && exitCode != 0
                let cancelled = cancellation.isCancelled

                var auditEntry: [String: Any] = [
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: started),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "durationMs": durationMs,
                    "exitCode": Int(exitCode),
                    "cwd": cwdRaw,
                    "sandbox": sandbox,
                    "timeoutSeconds": timeoutSeconds,
                    "timedOut": didTimeOut,
                    "cancelled": cancelled,
                    "outcome": cancelled ? "unknown" : "settled",
                    "prompt": fullPrompt,
                    "reply": replyText,
                    "stdout": stdoutText,
                    "stderr": stderrText,
                    "lastMessagePath": lastMessageURL.path,
                ]
                if let commitHash { auditEntry["commitHash"] = commitHash }
                if let model { auditEntry["model"] = model }
                if let effort = brain.reasoningEffort { auditEntry["reasoningEffort"] = effort }
                if let tier = brain.serviceTier { auditEntry["serviceTier"] = tier }
                if let fast = brain.fast { auditEntry["fast"] = fast }
                if let data = try? JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted]) {
                    try? data.write(to: auditURL)
                    Self.trimAgentBridgeAudits(in: auditDir)
                }

                guard resumed.tryResume() else { return }
                if exitCode == 0 && !cancelled {
                    cont.resume(returning: .object([
                        "status": .string("completed"),
                        "runId": .string(runId),
                        "reply": .string(replyText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "sandbox": .string(sandbox),
                        "brain": brain.jsonValue,
                        "auditPath": .string(auditURL.path),
                    ]))
                } else {
                    cont.resume(returning: .object([
                        "status": .string(cancelled ? "cancelled" : "failed"),
                        "outcome": .string(cancelled ? "unknown" : "settled"),
                        "reason": .string(cancelled ? "cancelled_effects_uncertain" : didTimeOut
                            ? "timeout_after_\(timeoutSeconds)s"
                            : "subprocess_exit_\(exitCode)"),
                        "runId": .string(runId),
                        "reply": .string(replyText),
                        "stderr": .string(stderrText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "timedOut": .bool(didTimeOut),
                        "sandbox": .string(sandbox),
                        "brain": brain.jsonValue,
                        "auditPath": .string(auditURL.path),
                    ]))
                }
            }

            do {
                try cancellation.launch(process)
            } catch {
                outputCapture.stopReading()
                guard resumed.tryResume() else { return }
                cont.resume(returning: .object([
                    "status": .string(error is CancellationError ? "cancelled" : "failed"),
                    "reason": .string(error is CancellationError ? "cancelled_before_spawn" : "spawn_failed"),
                    "runId": .string(runId),
                    "detail": .string(String(describing: error)),
                ]))
                return
            }

            armSubprocessTimeout(process: process, timeoutSeconds: timeoutSeconds) {
                timedOutFlag.set()
            }
          }
        } onCancel: {
            cancellation.cancel()
        }
        // Runs-ledger row — see the invoke_claude twin above for rationale.
        await Self.appendSpawnRunToLedger(
            kind: "codex",
            result: result,
            model: model,
            prompt: fullPrompt,
            startedAt: started,
            dataRoot: dataRoot
        )
        return result
    }

    static func codexExecArguments(
        sandbox: String,
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

    static func codexDangerFullAccessAllowed(policy: [String: JSONValue]) -> Bool {
        if case .bool(true)? = policy["developerMode"] {
            return true
        }
        return false
    }
}
