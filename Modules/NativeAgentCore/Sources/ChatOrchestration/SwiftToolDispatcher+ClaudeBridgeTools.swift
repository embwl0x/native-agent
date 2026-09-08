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
    // MARK: - Claude return-channel handler
    //
    // Bridge's her→me path. Agent calls `claude_message` when she wants to
    // flag something to Claude for follow-up. Writes a JSONL entry to
    // ~/.config/claude-bridge/claude-inbox.jsonl, which stays the durable
    // record Claude's UserPromptSubmit hook reads at session start.
    //
    // 2026-07-25 (User's directive, docs/build_plans/claude-wakeup-parity.md):
    // the inbox alone made `claude_message` a note-in-a-bottle — it only
    // landed when User happened to start a session. After the append, this now
    // also fires script/claude_thread_wakeup.js, which starts a real
    // `claude -p` turn with the message as input and posts Claude's final
    // reply back to Agent over the local bridge. Inbox append remains the
    // source of truth; the wakeup is an additive side effect whose receipt
    // rides in the tool result under "wakeup", exactly like codex_message.
    func runClaudeMessage(
        input: [String: JSONValue],
        surface: String = "chat",
        configRootOverride: URL? = nil
    ) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                "fix": .string("claude_message requires a non-empty 'text' parameter."),
            ])
        }
        // 2026-09-07: a message to Claude must not die on a stale Desk number.
        // The agent burned eight rounds re-sending with desk_item "123" after
        // each denial and never delivered its review. A binding that is not
        // live is dropped, the message goes, and the result says so.
        let deskHandle: String?
        var droppedDeskItem: String?
        do {
            deskHandle = try await delegationDeskHandle(input)
        } catch AutonomyGateError.toolDenied(let reason) where reason.contains("is not a live Desk item") {
            deskHandle = nil
            if case .string(let raw)? = input["desk_item"] { droppedDeskItem = raw }
        }
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
        let requestedWorkingDirectory: String?
        switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
        case .success(let path):
            requestedWorkingDirectory = path
        case .failure(let envelope):
            return envelope
        }
        // 2026-07-25: the helper clamps 60...3600 and defaults to 900. Before
        // this knob existed there was no way for a caller to say "this is a
        // build, not a question" — and 900s SIGTERMed two Claude sessions
        // mid-build on the wake-delivery-classification work order. Clamp here
        // too so a bad value never reaches the helper.
        let timeoutSeconds: Int? = {
            if case .int(let i)? = input["timeout_seconds"] { return max(60, min(3600, Int(i))) }
            if case .double(let d)? = input["timeout_seconds"] {
                return Int(exactly: d.rounded(.towardZero)).map { max(60, min(3600, $0)) }
            }
            return nil
        }()

        let originSessionId = Self.extractSessionId(from: input)
        if claudeMessageWakeupOverride == nil, claudeMessageWakeupHelperOverride == nil {
            let returnPath = AgentBridgeRuntime.returnPathReadiness(configRoot: configRootOverride)
            guard returnPath.isReady else {
                return Self.returnBridgeUnavailableEnvelope(returnPath)
            }
        }
        let dir = Self.bridgeConfigDirectory(named: "claude-bridge", configRootOverride: configRootOverride)
        let inboxURL = dir.appendingPathComponent("claude-inbox.jsonl")

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
        let worktreeResult = await BuilderWorktreeAllocator.shared.resolve(
            agent: .claude,
            conversationId: conversation.conversationId,
            messageId: messageId,
            isFollowUp: Self.builderConversationReferenceSupplied(in: input),
            requestedDirectory: requestedWorkingDirectory,
            defaultDirectory: nil,
            configRoot: builderWorktreeConfigRoot
        )
        let workingDirectory: String?
        switch worktreeResult {
        case .unchanged(let path): workingDirectory = path
        case .assigned(let assignment): workingDirectory = assignment.workingDirectory
        case .failed(let reason, let detail):
            return Self.builderWorktreeFailureEnvelope(reason: reason, detail: detail)
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
        let requireExistingConversation = Self.builderConversationReferenceSupplied(in: input)
        if requireExistingConversation { entry["requireExistingConversation"] = .bool(true) }
        if let workingDirectory { entry["workingDirectory"] = .string(workingDirectory) }
        if let deskHandle { entry["deskHandle"] = .string(deskHandle) }
        if pairReviewer { entry["pairReviewer"] = .bool(true) }
        if !originSessionId.isEmpty { entry["sessionId"] = .string(originSessionId) }
        if let timeoutSeconds { entry["timeoutSeconds"] = .int(Int64(timeoutSeconds)) }
        let inboxEntry = entry

        let persistence = SwiftNativePersistenceCore()
        let quarantineNote = Self.BuilderInboxQuarantineNote()
        let appendResult: (status: String, retryWake: Bool, queuedAt: String)
        do {
            appendResult = try await Self.appendBuilderInboxMessage(
                messageId, entry: inboxEntry, to: inboxURL, queuedAt: timestamp,
                comparePairReviewer: true, maxLines: JSONLLineCaps.claudeBridgeInbox,
                logLabel: "SwiftToolDispatcher.claudeMessage",
                persistence: persistence, quarantine: quarantineNote
            )
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
        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "messageId": .string(messageId),
            "deduplicated": .bool(deduplicated),
            "filePath": .string(path),
            "priority": .string(priority),
            "queuedAt": .string(appendResult.queuedAt),
        ]
        Self.stampBuilderInboxQuarantine(quarantineNote, on: &response)
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        if let deskHandle { response["deskHandle"] = .string(deskHandle) }
        if let droppedDeskItem {
            response["deskItemIgnored"] = .string(droppedDeskItem)
            response["note"] = .string("desk_item '\(droppedDeskItem)' is not a live Desk item; the message was delivered without a Desk binding. Omit desk_item unless you have a live handle from desk_list.")
        }
        if pairReviewer { response["reviewerPairRequested"] = .bool(true) }
        if let conversationId = conversation.conversationId {
            response["conversationId"] = .string(conversationId)
            response["replyWith"] = .string("claude_message")
        }
        if deduplicated && !appendResult.retryWake {
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            // Only this explicit same-id call retries helper admission. The
            // canonical helper still deduplicates execution and preserves
            // unknown effects; an inbox append alone is not a wake claim.
            if deduplicated { response["wakeupRetried"] = .bool(true) }
            response["wakeup"] = await postClaudeThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                requireExistingConversation: requireExistingConversation,
                queuedAt: appendResult.queuedAt,
                inboxPath: path,
                originSessionId: originSessionId,
                timeoutSeconds: timeoutSeconds,
                workingDirectory: workingDirectory,
                deskHandle: deskHandle,
                pairReviewer: pairReviewer
            )
        }
        response["note"] = .string(Self.claudeWakeupReceiptNote(response["wakeup"]))
        // The wake outcome is the only lifecycle signal this call ever learns,
        // and the receipt used to throw it away: `status` was the hardcoded
        // "queued" above, so an accepted — or even an already-completed — send
        // was classified `.unknown` and rendered "completion unconfirmed"
        // forever. Promote what the helper actually said. The nested `wakeup`
        // object stays exactly as it was; only the top-level tag, which is the
        // one thing ChatToolOutcome.exactResultClass reads, is corrected.
        response["status"] = .string(Self.claudeReceiptStatus(response["wakeup"]))
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
        case "delivered_live":
            // The resumed session is already open interactively, so the helper
            // deliberately spawned nothing (script/claude_thread_wakeup.js
            // live-session guard). The durable inbox row IS the delivery to
            // that live session — an accepted send, not a failed one.
            return "accepted"
        case "delivered_inbox":
            // 2026-09-06: the helper could not establish presence, so nothing
            // was admitted to act on the row. The durable enqueue is real; a
            // live delivery is not claimed.
            return "queued"
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

    static func claudeWakeupReceiptNote(_ wakeup: JSONValue?) -> String {
        let state: String
        switch stringField("status", in: wakeup ?? .null) {
        case "sent", "started":
            state = "The durable inbox row is written and Claude's wake was accepted. Her final reply returns as a separate bridge event; this receipt does not prove the work completed."
        case "queued":
            state = "The durable inbox row is written and Claude's wake is queued, not yet confirmed running."
        case "delivered_live":
            state = "The durable inbox row is written and that conversation is ALREADY OPEN interactively on this Mac, so no unattended session was spawned for it — the live session was not interrupted or replaced. It picks the message up from the inbox; inspect delegation_status (status delivered_live, with the holding pid) rather than expecting a wake completion event."
        case "delivered_inbox":
            state = "The durable inbox row is written, but this Mac could not be scanned for an open Claude session, so NO unattended session was spawned and live presence could not be established. The message waits in the inbox for whatever session reads it next; no wake completion event is coming for it."
        case "completed", "replayed":
            state = "The durable inbox row is written and the helper returned a result. Inspect the wakeup result and final reply before judging task completion."
        case "deduplicated":
            state = "This inbox message already exists; no new wake was launched by this call. Inspect delegation_status for its actual lifecycle."
        default:
            state = "The durable inbox row is written, but this call did not confirm a new Claude wake. Inspect wakeup and delegation_status; uncertain admission must be reconciled before resending."
        }
        return state + " For a contextual follow-up, use claude_message with conversation_mode=resume and this conversationId. For unrelated work, use conversation_mode=new and omit conversation_id."
    }

    // MARK: - claude_message wakeup spawn
    //
    // Deliberately NOT a clone of the codex wakeup machinery (Agent's design
    // fence): Claude's runtime is a spawned `claude` process, so the helper
    // owns the whole round trip and returns a claim receipt in well under a
    // second — the long turn runs in the helper's own detached child. That is
    // why this Swift side has a short deadline and no reply watcher.
    private func postClaudeThreadWakeup(
        messageId: String,
        text: String,
        priority: String,
        topic: String?,
        requireExistingConversation: Bool,
        queuedAt: String,
        inboxPath: String,
        originSessionId: String,
        timeoutSeconds: Int? = nil,
        workingDirectory: String? = nil,
        deskHandle: String? = nil,
        pairReviewer: Bool = false
    ) async -> JSONValue {
        var payload: [String: JSONValue] = [
            "messageId": .string(messageId),
            "text": .string(text),
            "priority": .string(priority),
            "queuedAt": .string(queuedAt),
            "inboxPath": .string(inboxPath),
            "source": .string("claude_message"),
        ]
        if let topic { payload["topic"] = .string(topic) }
        if requireExistingConversation { payload["requireExistingConversation"] = .bool(true) }
        if !originSessionId.isEmpty { payload["sessionId"] = .string(originSessionId) }
        if let timeoutSeconds { payload["timeoutSeconds"] = .int(Int64(timeoutSeconds)) }
        if let workingDirectory { payload["cwd"] = .string(workingDirectory) }
        if let deskHandle { payload["deskHandle"] = .string(deskHandle) }
        if pairReviewer { payload["pairReviewer"] = .bool(true) }
        Self.stampDelegationProducer(on: &payload)

        if let claudeMessageWakeupOverride {
            return await claudeMessageWakeupOverride(payload)
        }

        // L1#14 replay guard. Placed AFTER the test override on purpose: the
        // guard reads a real directory, and when `agentBridgeConfigRoot` is nil
        // that directory is the LIVE ~/.config. A test that injects an override
        // must never be able to reach it. Production sets no override, so the
        // production order is unchanged — guard, then helper. The guard's own
        // behaviour is covered directly in WakeupReplayGuardTests.
        if !WakeupReplayGuard.isDisabled(),
           let match = WakeupReplayGuard.terminalDuplicate(
               store: .claude,
               jobsDirectory: WakeupReplayGuard.jobsDirectory(
                   for: .claude, configRoot: agentBridgeConfigRoot),
               topic: topic,
               text: text,
               now: Date()
           ) {
            return WakeupReplayGuard.receipt(match)
        }

        let disabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED"]?.lowercased()
        if ["1", "true", "yes"].contains(disabled ?? "") {
            return .object([
                "status": .string("skipped"),
                "reason": .string("disabled_by_environment"),
                "env": .string("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED"),
            ])
        }

        guard let helper = AgentBridgeRuntime.claudeHelperURL(
            override: claudeMessageWakeupHelperOverride,
            repoRoot: rootForRead
        ) else {
            return .object([
                "status": .string("skipped"),
                "reason": .string("helper_not_found"),
                "fix": .string("Install script/claude_thread_wakeup.js or set NATIVE_AGENT_CLAUDE_WAKEUP_HELPER."),
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
        return await Self.runClaudeWakeupHelper(helper: helper, inputData: inputData, cwd: cwd)
    }

    /// The helper claims the job and detaches; it must never hold the tool
    /// call for the length of Claude's turn. A deadline breach here is a
    /// helper bug, and it is reported as one rather than as a silent success.
    private static func runClaudeWakeupHelper(helper: URL, inputData: Data, cwd: URL) async -> JSONValue {
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
        if childEnvironment["NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN"] == nil,
           let claude = AgentBridgeRuntime.executableURL(named: "claude", environment: environment) {
            childEnvironment["NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN"] = claude.path
        }
        return await runBuilderWakeupHelper(
            node: node,
            helper: helper,
            inputData: inputData,
            cwd: cwd,
            environment: childEnvironment,
            timeoutSeconds: claudeWakeupHelperTimeoutSeconds()
        )
    }

    /// The helper's own work is a job claim plus a detached spawn — seconds at
    /// most. 30s leaves generous headroom for a cold `node` start without
    /// letting a wedged helper hold a chat turn.
    static func claudeWakeupHelperTimeoutSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        let rawSeconds = environment["NATIVE_AGENT_CLAUDE_WAKEUP_HELPER_TIMEOUT_SECONDS"]
            .flatMap(Int.init) ?? 30
        return TimeInterval(min(300, max(5, rawSeconds)))
    }

    // MARK: - invoke_claude session pointer

    /// Cross-process exclusion for the `invoke_claude` session pointer.
    ///
    /// Deliberately SYNCHRONOUS. The pointer's lifecycle has two halves — the
    /// read/check before the run and the write/reset after it — and the second
    /// half executes inside `Process.terminationHandler`, which cannot await.
    /// It locks the same `<path>.lock` sidecar `PersistenceCore.withFileLock`
    /// uses, with the same LOCK_EX and the same acquire-then-validate-inode
    /// contract, so the two remain mutually exclusive.
    ///
    /// 2026-09-06: bounded acquisition failure skips the body. Running it
    /// unlocked can overwrite a concurrent invocation's resume pointer.
    @discardableResult
    static func withSessionPointerLock<T>(_ target: URL, _ body: () -> T) -> T? {
        let lockPath = target.path + ".lock"
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let deadline = Date().addingTimeInterval(5)
        var attempts = 0
        while attempts < 8 {
            attempts += 1
            let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0 { break }
            var acquired = false
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
                let e = errno
                if e != EWOULDBLOCK && e != EINTR { break }
                if Date() >= deadline { break }
                usleep(20_000)
            }
            guard acquired else { Darwin.close(fd); break }
            // Do we hold the file that is CURRENTLY at lockPath? A reaped or
            // replaced sidecar would otherwise leave us locking a corpse while
            // a newcomer locks the live one — mutual exclusion silently gone.
            var held = stat()
            var atPath = stat()
            let sameInode = fstat(fd, &held) == 0
                && stat(lockPath, &atPath) == 0
                && held.st_dev == atPath.st_dev
                && held.st_ino == atPath.st_ino
            if !sameInode {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
                usleep(5_000)
                continue
            }
            defer {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
            return body()
        }
        return nil
    }

    /// The session id a pointer file currently names, or nil when it is absent
    /// or empty. Callers hold `withSessionPointerLock`; this is the re-read
    /// that makes the lock load-bearing across the long gap between the two
    /// halves of the pointer's lifecycle.
    static func sessionPointerSessionID(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let first = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: - invoke_claude spawn handler
    //
    // Spawns `claude -p "<context+question>"` as a Process, blocks until
    // the subprocess exits (or timeout fires + we terminate). Captures
    // stdout/stderr. Writes audit envelope to data/from_claude/<uuid>.json
    // with prompt, exit code, duration, summary. Returns Agent-facing
    // JSON envelope with the reply text.
    // 2026-06-09 notify-don't-hang: emits live notice events (start /
    // 30s heartbeat / timeout) through ToolNoticeBus so the user sees
    // progress instead of a silent multi-minute hang.
    //
    // Async via withCheckedContinuation — Process.terminationHandler
    // resumes the continuation exactly once. Timeout watchdog terminates the
    // spawned process group, then the same handler returns the envelope.
    static func runInvokeClaude(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                // 2026-09-06: every outcome reports pointer handling evidence.
                "sessionPointerStatus": .string("not_checked"),
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
            // 600 -> 180 (the user, 2026-06-09): a hung invoke held the chat for 10
            // silent minutes. 3 min surfaces failure fast; callers with a real
            // long task pass timeout_seconds explicitly (clamp stays 30-3600).
            return 180
        }()

        var promptParts: [String] = []
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

        // Notify-don't-hang: capture the turn's notice sink from the task-local
        // BEFORE entering the continuation — the Process terminationHandler and
        // the watchdog run off the task tree and can't read TaskLocals. nil when
        // invoked outside a chat turn (background loops): emission just no-ops.
        let notify = ToolNoticeBus.emit
        await notify?(
            "invoke_started",
            "⏳ Working on a longer step… (up to \(timeoutSeconds)s)"
        )
        let timedOutFlag = AtomicFlag()
        let heartbeat = Task {
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                elapsed += 30
                await notify?("invoke_progress", "⏳ Still working… (\(elapsed)s elapsed)")
            }
        }
        // 2026-09-06: admission and launch failures own the heartbeat too.
        defer { heartbeat.cancel() }

        // Persistent agent-to-Claude session. Instead of a blank `claude -p`
        // per message, resume the same dedicated thread every time so the
        // configured resident agent and Claude retain real continuity. The id
        // is pinned at <dataRoot>/from_claude/agent_session.txt:
        // first call creates it via --session-id, every call after --resume's it.
        // (A `claude` session already loads the full persona + memory + MCP tools
        // via the inherited env — the only thing missing before was CONTINUITY.)
        let sessionDirectory = dataRoot
            .appendingPathComponent("from_claude", isDirectory: true)
        let sessionFile = sessionDirectory.appendingPathComponent("agent_session.txt")
        // Read-only migration compatibility for pointers written before the
        // filename became identity-neutral. Build the retired name from
        // fragments so a fresh binary does not advertise the private instance
        // identity that the old filename contained.
        let legacySessionName = [
            "claude",
            ["ay", "ala"].joined(),
            "session.txt",
        ].joined(separator: "_")
        let legacySessionFile = sessionDirectory.appendingPathComponent(legacySessionName)
        let existingSessionFile = FileManager.default.fileExists(atPath: sessionFile.path)
            ? sessionFile
            : legacySessionFile
        // Resume is project-scoped: retain the creation cwd with the ID.
        // Admission and termination each lock and reread the pointer so a
        // settlement cannot reset a different invocation's current session.
        let pointerProvenance = dataRoot.standardizedFileURL.path
        let lockedDecision: (id: String, args: [String], isNew: Bool, cwd: String)?
            = withSessionPointerLock(sessionFile) {
                let existingLines = (try? String(contentsOf: existingSessionFile, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let pointerIsForeign = existingLines?.count ?? 0 >= 3
                    && existingLines?[2] != pointerProvenance
                if pointerIsForeign {
                    let rejected = existingSessionFile.deletingPathExtension()
                        .appendingPathExtension("foreign-\(Int(started.timeIntervalSince1970))")
                    try? FileManager.default.moveItem(at: existingSessionFile, to: rejected)
                }
                if !pointerIsForeign, let existingLines, let first = existingLines.first, !first.isEmpty {
                    return (
                        first,
                        ["--resume", first],
                        false,
                        (existingLines.count >= 2 && !existingLines[1].isEmpty) ? existingLines[1] : cwdRaw
                    )
                }
                let fresh = UUID().uuidString.lowercased()
                return (fresh, ["--session-id", fresh], true, cwdRaw)
            }
        guard let pointerDecision = lockedDecision else {
            return .object([
                "status": .string("failed"),
                "reason": .string("session_pointer_lock_unavailable"),
                "sessionPointerStatus": .string("lock_unavailable"),
            ])
        }
        let sessionId = pointerDecision.id
        let sessionArgs = pointerDecision.args
        let isNewSession = pointerDecision.isNew
        let sessionCwd = pointerDecision.cwd

        // Resolve `claude` binary. Most users have it in /usr/local/bin/
        // or ~/.claude/bin/, sometimes /opt/homebrew/bin/. Use `env` to
        // honor PATH. Process inherits the user's environment so MCP
        // config, auth, ~/.claude/settings.json all come along.
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let claude = AgentBridgeRuntime.executableURL(named: "claude", environment: environment) else {
            heartbeat.cancel()
            return .object([
                "status": .string("failed"),
                "reason": .string("claude_cli_not_found"),
                "sessionPointerStatus": .string("admitted_not_settled"),
                "fix": .string("Install and sign in to Claude Code, then restart NativeAgent."),
            ])
        }
        let process = Process()
        process.executableURL = claude
        process.arguments = sessionArgs + ["-p", fullPrompt]
        process.currentDirectoryURL = URL(fileURLWithPath: sessionCwd)
        process.environment = environment

        let outputCapture = InvokeOutputCapture(process: process)

        let cancellation = InvokeCancellation()
        let result: JSONValue = await withTaskCancellationHandler {
          await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            // Single-fire guard — both terminationHandler and the timeout
            // watchdog could try to resume. Continuation must resume EXACTLY once.
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                let (stdoutText, stderrText) = outputCapture.finish()
                let exitCode = proc.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)

                heartbeat.cancel()
                // Guard the edge where the watchdog fires just as the process
                // exits cleanly: only report a timeout when the exit was
                // actually fatal (gpt-5.5 review nit).
                let didTimeOut = timedOutFlag.isSet && exitCode != 0
                let cancelled = cancellation.isCancelled

                // Audit envelope to data/from_claude/<uuid>.json (best-effort,
                // failure is non-fatal — Agent already has the reply in hand).
                let auditDir = dataRoot
                    .appendingPathComponent("from_claude", isDirectory: true)
                try? FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
                let auditURL = auditDir.appendingPathComponent("\(runId).json")
                var auditEntry: [String: Any] = [
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: started),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "durationMs": durationMs,
                    "exitCode": Int(exitCode),
                    "cwd": cwdRaw,
                    "timeoutSeconds": timeoutSeconds,
                    // 2026-06-09 (Agent's catch): exit 143 + empty reply was
                    // ambiguous — record whether OUR watchdog killed it.
                    "timedOut": didTimeOut,
                    "cancelled": cancelled,
                    "outcome": cancelled ? "unknown" : "settled",
                    "sessionId": sessionId,
                    "prompt": fullPrompt,
                    "reply": stdoutText,
                    "stderr": stderrText,
                ]
                if let commitHash { auditEntry["commitHash"] = commitHash }
                if let data = try? JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted]) {
                    try? data.write(to: auditURL)
                    Self.trimAgentBridgeAudits(in: auditDir)
                }

                // Persist the delegated session id on first successful create
                // so the next invoke RESUMES it. Clear it on a genuine
                // (non-timeout) resume failure so a dead session self-heals into a
                // fresh thread next time instead of failing forever.
                // Same lock as the read/check above: this is the WRITE half of
                // one read-check-write, and the two halves are separated by a
                // minutes-long subprocess. The lock alone cannot span that gap,
                // so each branch re-reads the live pointer under it — that is
                // what stops one invoke's settlement landing on another's.
                let pointerSettlement: Void? = Self.withSessionPointerLock(sessionFile) {
                    if isNewSession {
                        if exitCode == 0 && !cancelled {
                            // Persist id + the creation cwd so the next invoke resumes
                            // the SAME thread from the SAME project dir. Never clobber
                            // a pointer another invoke established while we ran: the
                            // first thread to land owns the topic, and last-writer-wins
                            // here silently orphans it.
                            if Self.sessionPointerSessionID(sessionFile) == nil {
                                try? "\(sessionId)\n\(sessionCwd)\n\(pointerProvenance)".write(to: sessionFile, atomically: true, encoding: .utf8)
                            }
                        }
                    } else if exitCode == 0, existingSessionFile != sessionFile {
                        // Promote a successfully resumed legacy pointer to the
                        // identity-neutral filename. Keep the legacy file as a
                        // rollback breadcrumb; all future reads prefer the new one.
                        // Only when nothing newer already sits there.
                        let live = Self.sessionPointerSessionID(sessionFile)
                        if live == nil || live == sessionId {
                            try? "\(sessionId)\n\(sessionCwd)\n\(pointerProvenance)".write(
                                to: sessionFile,
                                atomically: true,
                                encoding: .utf8
                            )
                        }
                    } else if exitCode != 0 && !didTimeOut && !cancelled {
                        // Self-heal ONLY a genuinely-gone session (explicit
                        // session-not-found marker), and RENAME the pointer aside
                        // rather than delete it — a transient / concurrent / auth
                        // failure must NEVER silently wipe the resident thread
                        // review BLOCKING). Every other failure keeps the pointer.
                        let lower = stderrText.lowercased()
                        let sessionGone = lower.contains("no conversation found")
                            || lower.contains("session not found")
                            || lower.contains("no session found")
                            || (lower.contains("session") && lower.contains("does not exist"))
                        // ...and only when the pointer on disk is still the one
                        // THIS run resumed. A concurrent invoke may have healed
                        // the thread while we ran; renaming its fresh pointer
                        // aside is precisely the live `.stale-<ts>` damage.
                        if sessionGone, Self.sessionPointerSessionID(existingSessionFile) == sessionId {
                            let stale = existingSessionFile.deletingPathExtension()
                                .appendingPathExtension("stale-\(Int(started.timeIntervalSince1970))")
                            try? FileManager.default.moveItem(at: existingSessionFile, to: stale)
                        }
                    }
                }

                if pointerSettlement == nil {
                    NSLog("invoke_claude: resume pointer lock unavailable; session remains in the invocation audit")
                }

                if didTimeOut {
                    // Best-effort user-visible line; the failed envelope below is
                    // the durable signal. Sync handler -> hop onto a Task.
                    let timeoutText = "⚠️ The longer step timed out after \(timeoutSeconds)s — no reply."
                    Task { await notify?("invoke_timeout", timeoutText) }
                }

                guard resumed.tryResume() else { return }
                if exitCode == 0 && !cancelled {
                    cont.resume(returning: .object([
                        "status": .string("completed"),
                        "runId": .string(runId),
                        "reply": .string(stdoutText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "auditPath": .string(auditURL.path),
                        "sessionId": .string(sessionId),
                        "sessionPointerStatus": .string(pointerSettlement == nil ? "lock_unavailable" : "checked"),
                    ]))
                } else {
                    cont.resume(returning: .object([
                        "status": .string(cancelled ? "cancelled" : "failed"),
                        "outcome": .string(cancelled ? "unknown" : "settled"),
                        "sessionId": .string(sessionId),
                        "sessionPointerStatus": .string(pointerSettlement == nil ? "lock_unavailable" : "checked"),
                        "reason": .string(cancelled ? "cancelled_effects_uncertain" : didTimeOut
                            ? "timeout_after_\(timeoutSeconds)s"
                            : "subprocess_exit_\(exitCode)"),
                        "runId": .string(runId),
                        "reply": .string(stdoutText),
                        "stderr": .string(stderrText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "timedOut": .bool(didTimeOut),
                        "auditPath": .string(auditURL.path),
                    ]))
                }
            }

            do {
                try cancellation.launch(process)
            } catch {
                heartbeat.cancel()
                outputCapture.stopReading()
                guard resumed.tryResume() else { return }
                cont.resume(returning: .object([
                    "status": .string(error is CancellationError ? "cancelled" : "failed"),
                    "reason": .string(error is CancellationError ? "cancelled_before_spawn" : "spawn_failed"),
                    "sessionPointerStatus": .string("admitted_not_settled"),
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
        // Runs-ledger row (R25 follow-up): the Runs UI + iOS runs snapshot read
        // <dataRoot>/runs/runs.json. Every spawn that reached the continuation
        // gets one row; validation refusals above never spawned and stay off
        // the ledger. Best-effort — never fails the invoke.
        await Self.appendSpawnRunToLedger(
            kind: "claude",
            result: result,
            model: nil,
            prompt: fullPrompt,
            startedAt: started,
            dataRoot: dataRoot
        )
        return result
    }

}
