import Foundation
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
    // MARK: - time_now handler

    /// Return current date/time in multiple representations. Zero-input,
    /// zero-side-effect, always safe. Caught by Agent 2026-06-08: she
    /// called time_now mid-test and got "not in the dispatch table" —
    /// the name is sensible, the tool just was never built. Now it is.
    static func impl_time_now() -> JSONValue {
        let now = Date()
        let isoUTC = ISO8601DateFormatter().string(from: now)
        let isoLocalFormatter = ISO8601DateFormatter()
        isoLocalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoLocalFormatter.timeZone = TimeZone.current
        let isoLocal = isoLocalFormatter.string(from: now)
        let epoch = Int64(now.timeIntervalSince1970)
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        let weekdayNames = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
        let weekdayName = weekdayNames[max(1, min(7, weekday)) - 1]
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        let humanFormatter = DateFormatter()
        humanFormatter.dateStyle = .full
        humanFormatter.timeStyle = .medium
        humanFormatter.timeZone = TimeZone.current
        let human = humanFormatter.string(from: now)
        return .object([
            "iso_utc": .string(isoUTC),
            "iso_local": .string(isoLocal),
            "epoch_seconds": .int(epoch),
            "weekday": .string(weekdayName),
            "day_of_year": .int(Int64(dayOfYear)),
            "human": .string(human),
            "timezone": .string(TimeZone.current.identifier),
            "timezone_offset_seconds": .int(Int64(TimeZone.current.secondsFromGMT(for: now))),
        ])
    }

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
    func runClaudeMessage(input: [String: JSONValue], configRootOverride: URL? = nil) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                "fix": .string("claude_message requires a non-empty 'text' parameter."),
            ])
        }
        let priority: String = {
            if case .string(let p)? = input["priority"] {
                let lower = p.lowercased()
                if ["info", "important", "urgent"].contains(lower) { return lower }
            }
            return "info"
        }()
        let topic: String? = {
            if case .string(let t)? = input["topic"], !t.isEmpty { return t }
            return nil
        }()
        // 2026-07-25: the helper clamps 60...3600 and defaults to 900. Before
        // this knob existed there was no way for a caller to say "this is a
        // build, not a question" — and 900s SIGTERMed two Claude sessions
        // mid-build on the wake-delivery-classification work order. Clamp here
        // too so a bad value never reaches the helper.
        let timeoutSeconds: Int? = {
            if case .int(let i)? = input["timeout_seconds"] { return max(60, min(3600, Int(i))) }
            if case .double(let d)? = input["timeout_seconds"] { return max(60, min(3600, Int(d))) }
            return nil
        }()

        let originSessionId = Self.extractSessionId(from: input)
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

        let messageId: String = {
            guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
        }()
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
        let inboxEntry = entry

        // 2026-07-21 audit: mirror the codex_message twin — flock'd
        // read-dedup-append so a caller-supplied message_id is idempotent,
        // and route the append through the shared line cap so the inbox
        // cannot grow unbounded.
        let persistence = SwiftNativePersistenceCore()
        let appendStatus: String
        do {
            appendStatus = try await persistence.withFileLock(inboxURL) {
                let existing = try await persistence.readJSONL(inboxURL).first { row in
                    guard case .object(let object) = row else { return false }
                    return object["messageId"] == .string(messageId) || object["id"] == .string(messageId)
                }
                if case .object(let object)? = existing {
                    guard object["text"] == .string(text) else { return "conflict" }
                    return "duplicate"
                }
                try await appendJSONLCapped(
                    .object(inboxEntry),
                    to: inboxURL,
                    using: persistence,
                    maxLines: JSONLLineCaps.claudeBridgeInbox,
                    logLabel: "SwiftToolDispatcher.claudeMessage",
                    takeLock: false
                )
                return "appended"
            }
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_write_failed"),
                "detail": .string(String(describing: error)),
            ])
        }
        let path = inboxURL.path
        guard appendStatus != "conflict" else {
            return .object([
                "status": .string("failed"),
                "reason": .string("message_id_conflict"),
                "messageId": .string(messageId),
            ])
        }
        let deduplicated = appendStatus == "duplicate"
        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "messageId": .string(messageId),
            "deduplicated": .bool(deduplicated),
            "filePath": .string(path),
            "priority": .string(priority),
            "queuedAt": .string(timestamp),
            "note": .string("The durable inbox row is written, and NativeAgent also wakes a real Claude session with this message as its turn input. Her final reply comes back to you as a separate bridge event; do not wait on this tool result for it."),
        ]
        if deduplicated {
            // A duplicate message_id means this exact event already claimed its
            // wake job on first delivery. Re-firing would double-wake Claude.
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            response["wakeup"] = await postClaudeThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                queuedAt: timestamp,
                inboxPath: path,
                originSessionId: originSessionId,
                timeoutSeconds: timeoutSeconds
            )
        }
        return .object(response)
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
        queuedAt: String,
        inboxPath: String,
        originSessionId: String,
        timeoutSeconds: Int? = nil
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
        if !originSessionId.isEmpty { payload["sessionId"] = .string(originSessionId) }
        if let timeoutSeconds { payload["timeoutSeconds"] = .int(Int64(timeoutSeconds)) }

        if let claudeMessageWakeupOverride {
            return await claudeMessageWakeupOverride(payload)
        }

        let disabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED"]?.lowercased()
        if ["1", "true", "yes"].contains(disabled ?? "") {
            return .object([
                "status": .string("skipped"),
                "reason": .string("disabled_by_environment"),
                "env": .string("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED"),
            ])
        }

        guard let helper = Self.claudeWakeupHelperURL(
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
        return await Task.detached(priority: .utility) {
            Self.runClaudeWakeupHelper(helper: helper, inputData: inputData, cwd: cwd)
        }.value
    }

    private static func claudeWakeupHelperURL(override: URL?, repoRoot: URL) -> URL? {
        let fm = FileManager.default
        let envPath = ProcessInfo.processInfo.environment["NATIVE_AGENT_CLAUDE_WAKEUP_HELPER"]
        let candidates: [URL?] = [
            override,
            envPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
            repoRoot.appendingPathComponent("script/claude_thread_wakeup.js").standardizedFileURL,
        ]
        for candidate in candidates.compactMap({ $0 }) where fm.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// The helper claims the job and detaches; it must never hold the tool
    /// call for the length of Claude's turn. A deadline breach here is a
    /// helper bug, and it is reported as one rather than as a silent success.
    private static func runClaudeWakeupHelper(helper: URL, inputData: Data, cwd: URL) -> JSONValue {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", helper.path]
        process.currentDirectoryURL = cwd

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_spawn_failed"),
                "helper": .string(helper.path),
                "error": .string(String(describing: error)),
            ])
        }

        stdin.fileHandleForWriting.write(inputData)
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(Self.claudeWakeupHelperTimeoutSeconds())
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_timeout"),
                "helper": .string(helper.path),
            ])
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // The helper writes exactly one JSON envelope line; take the LAST line
        // so an unexpected warning above it cannot make a good run read as
        // "no JSON".
        let lastLine = stdoutText.split(separator: "\n").last.map(String.init) ?? ""
        if !lastLine.isEmpty,
           let data = lastLine.data(using: .utf8),
           let parsed = try? JSONValue.parse(data) {
            if case .object(var obj) = parsed {
                obj["helper"] = .string(helper.path)
                obj["exitCode"] = .int(Int64(process.terminationStatus))
                if !stderrText.isEmpty {
                    obj["stderrPreview"] = .string(String(stderrText.prefix(500)))
                }
                return .object(obj)
            }
            return parsed
        }

        return .object([
            "status": .string("failed"),
            "reason": .string("helper_returned_no_json"),
            "helper": .string(helper.path),
            "exitCode": .int(Int64(process.terminationStatus)),
            "stderrPreview": .string(String(stderrText.prefix(500))),
        ])
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

    /// Accepts only a bare `owner/name` GitHub slug. Rejects anything that
    /// could be read as a filesystem path or a traversal attempt, so the
    /// resolver is never handed model-authored path syntax.
    static func isWellFormedRepositorySlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 140 else { return false }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("..") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._"
        )
        for part in parts {
            guard !part.isEmpty, part.count <= 100 else { return false }
            guard part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    func runCodexMessage(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                "fix": .string("codex_message requires a non-empty 'text' parameter."),
            ])
        }
        let priority: String = {
            if case .string(let p)? = input["priority"] {
                let lower = p.lowercased()
                if ["info", "important", "urgent"].contains(lower) { return lower }
            }
            return "info"
        }()
        let topic: String? = {
            if case .string(let t)? = input["topic"], !t.isEmpty { return t }
            return nil
        }()
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
        // Trusted path A: the GitHub Command lane hands us an app-resolved
        // absolute checkout. Still surface-gated -- chat can never set this.
        let dispatcherSuppliedDirectory: String? = {
            guard surface == "github-command",
                  case .string(let raw)? = input["working_directory"] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: value).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url.path
        }()

        // Trusted path B: any caller may name an owner/name GitHub repository.
        // It is NOT a path -- the app resolves it through the same
        // remote-verified resolver the GitHub Command lane uses, so the trust
        // anchor stays "this checkout's git remote really is that repo" rather
        // than "the model said so". An unresolvable or malformed repository
        // yields nil and the send proceeds with today's no-profile behavior.
        let repositoryResolvedDirectory: String? = {
            guard dispatcherSuppliedDirectory == nil,
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

        let workingDirectory = dispatcherSuppliedDirectory ?? repositoryResolvedDirectory
        // This capability marker is created only from the trusted dispatcher
        // surface plus an app-verified checkout. It is never accepted from
        // model-authored input, topic text, or repository-controlled prose.
        let executionProfile = workingDirectory == nil
            ? nil
            : "github-command-repository-network-v1"

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

        // Honor a caller-supplied internal idempotency key (GitHub Command
        // dispatch): the dedup read below matches on messageId, so a random
        // UUID here would make at-most-once delivery unreachable — the same
        // actionable event would append a fresh row on every retry/replay.
        let messageId: String = {
            guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
        }()
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
        if !originSessionId.isEmpty { entry["sessionId"] = .string(originSessionId) }
        entry["origin"] = origin
        entry["brain"] = brain.jsonValue
        if let model = brain.model { entry["model"] = .string(model) }
        if let effort = brain.reasoningEffort { entry["reasoningEffort"] = .string(effort) }
        if let tier = brain.serviceTier { entry["serviceTier"] = .string(tier) }
        if let fast = brain.fast { entry["fast"] = .bool(fast) }
        if let workingDirectory { entry["workingDirectory"] = .string(workingDirectory) }
        if let executionProfile { entry["executionProfile"] = .string(executionProfile) }
        let inboxEntry = entry

        let persistence = SwiftNativePersistenceCore()
        let appendStatus: String
        do {
            appendStatus = try await persistence.withFileLock(inboxURL) {
                let existing = try await persistence.readJSONL(inboxURL).first { row in
                    guard case .object(let object) = row else { return false }
                    return object["messageId"] == .string(messageId) || object["id"] == .string(messageId)
                }
                if case .object(let object)? = existing {
                    guard object["text"] == .string(text) else { return "conflict" }
                    return "duplicate"
                }
                try await persistence.appendJSONL(.object(inboxEntry), to: inboxURL)
                return "appended"
            }
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("inbox_write_failed"),
                "detail": .string(String(describing: error)),
            ])
        }
        let path = inboxURL.path
        guard appendStatus != "conflict" else {
            return .object([
                "status": .string("failed"),
                "reason": .string("message_id_conflict"),
                "messageId": .string(messageId),
            ])
        }
        let deduplicated = appendStatus == "duplicate"
        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "messageId": .string(messageId),
            "deduplicated": .bool(deduplicated),
            "filePath": .string(path),
            "priority": .string(priority),
            "queuedAt": .string(timestamp),
            "origin": origin,
            "brain": brain.jsonValue,
            "note": .string("Codex can read this through the local NativeAgent bridge inbox; NativeAgent also attempts a local Mac notification, a Codex thread wakeup, and a reply watcher that delivers Codex's final answer back through the local bridge. If Codex is already busy, the wakeup is queued until that thread is idle."),
        ]
        response["notification"] = await postCodexMessageArrivalNotification(
            messageId: messageId,
            text: text,
            priority: priority,
            topic: topic
        )
        if deduplicated {
            // A duplicate message_id means this exact actionable event already
            // queued its inbox row and fired its wakeup on first delivery.
            // Re-poking the codex thread would double-wake it, so skip the
            // wakeup side effect entirely and report the dedup outcome.
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            response["wakeup"] = await postCodexThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                queuedAt: timestamp,
                inboxPath: path,
                originSessionId: originSessionId,
                origin: origin,
                brain: brain,
                workingDirectory: workingDirectory,
                executionProfile: executionProfile
            )
        }
        return .object(response)
    }

    private static func bridgeConfigDirectory(named name: String, configRootOverride: URL? = nil) -> URL {
        if let configRootOverride {
            return configRootOverride.appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
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
        workingDirectory: String?,
        executionProfile: String?
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
            if let workingDirectory { payload["workingDirectory"] = .string(workingDirectory) }
            if let executionProfile { payload["executionProfile"] = .string(executionProfile) }
            return await codexMessageWakeupOverride(payload)
        }

        let disabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_WAKEUP_DISABLED"]?.lowercased()
        if ["1", "true", "yes"].contains(disabled ?? "") {
            return .object([
                "status": .string("skipped"),
                "reason": .string("disabled_by_environment"),
                "env": .string("NATIVE_AGENT_CODEX_WAKEUP_DISABLED"),
            ])
        }

        guard let helper = Self.codexWakeupHelperURL(
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
        if let workingDirectory { payload["workingDirectory"] = .string(workingDirectory) }
        if let executionProfile { payload["executionProfile"] = .string(executionProfile) }

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
        return await Task.detached(priority: .utility) {
            Self.runCodexWakeupHelper(helper: helper, inputData: inputData, cwd: cwd)
        }.value
    }

    private static func codexWakeupHelperURL(override: URL?, repoRoot: URL) -> URL? {
        let fm = FileManager.default
        let envPath = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_WAKEUP_HELPER"]
        let candidates: [URL?] = [
            override,
            envPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
            repoRoot.appendingPathComponent("script/codex_thread_wakeup.js").standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/scripts/nativeagent_codex_wakeup.js")
                .standardizedFileURL,
        ]
        for candidate in candidates.compactMap({ $0 }) where fm.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Concurrent accumulator for one child pipe.
    ///
    /// BRIDGES-5: the helper's stdout/stderr must be drained WHILE the child
    /// runs. A macOS pipe holds ~64KB; a helper that emits more (a large
    /// `--recover-reply-jobs` report, a node stack trace) blocks in `write(2)`
    /// forever if the parent only reads after `waitUntilExit`. The old code
    /// read at line 953 — after the poll loop — so any >64KB helper wedged,
    /// hit the deadline, and got reported as `helper_timeout`: a lie, because
    /// the helper was alive and blocked on us.
    private final class HelperPipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private let byteCap: Int
        private var buffer = Data()
        private var truncatedBytes = 0
        private var didFinish = false

        init(byteCap: Int = 8 * 1024 * 1024) {
            self.byteCap = byteCap
        }

        /// Installs the reader. MUST be called before `process.run()`.
        func attach(to handle: FileHandle) {
            handle.readabilityHandler = { [weak self] readHandle in
                guard let self else { return }
                let chunk = readHandle.availableData
                if chunk.isEmpty {
                    readHandle.readabilityHandler = nil
                    self.finish()
                    return
                }
                self.lock.lock()
                // Always CONSUME, even past the cap — dropping bytes we already
                // read keeps memory bounded without ever re-wedging the pipe.
                let room = self.byteCap - self.buffer.count
                if room > 0 {
                    self.buffer.append(chunk.prefix(room))
                    self.truncatedBytes += max(0, chunk.count - room)
                } else {
                    self.truncatedBytes += chunk.count
                }
                self.lock.unlock()
            }
        }

        private func finish() {
            lock.lock()
            let alreadyFinished = didFinish
            didFinish = true
            lock.unlock()
            if !alreadyFinished { finished.signal() }
        }

        /// Bounded wait for EOF, then detach. Never blocks indefinitely: a
        /// killed child can leave a pipe held open by a grandchild.
        func waitForEOF(timeout: TimeInterval, handle: FileHandle) {
            _ = finished.wait(timeout: .now() + timeout)
            handle.readabilityHandler = nil
            finish()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return truncatedBytes > 0
        }
    }

    private static func runCodexWakeupHelper(helper: URL, inputData: Data, cwd: URL) -> JSONValue {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", helper.path]
        process.currentDirectoryURL = cwd

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Readers armed BEFORE run(): from the child's first byte there is a
        // consumer on both pipes, so neither can fill.
        let outDrain = HelperPipeDrain()
        let errDrain = HelperPipeDrain()
        outDrain.attach(to: stdout.fileHandleForReading)
        errDrain.attach(to: stderr.fileHandleForReading)

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_spawn_failed"),
                "helper": .string(helper.path),
                "error": .string(String(describing: error)),
            ])
        }

        // Same hazard in the other direction: a payload larger than the pipe
        // buffer blocks this thread if the helper hasn't started reading yet.
        // Write off-thread and let the deadline loop below stay responsive.
        DispatchQueue.global(qos: .utility).async {
            let handle = stdin.fileHandleForWriting
            try? handle.write(contentsOf: inputData)
            try? handle.close()
        }

        let deadline = Date().addingTimeInterval(Self.codexWakeupHelperTimeoutSeconds())
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // Whatever the helper managed to say before the deadline is real
            // diagnostic evidence — a timeout is no longer a blind report.
            outDrain.waitForEOF(timeout: 1.0, handle: stdout.fileHandleForReading)
            errDrain.waitForEOF(timeout: 1.0, handle: stderr.fileHandleForReading)
            let partialErr = String(data: errDrain.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var timeoutObject: [String: JSONValue] = [
                "status": .string("failed"),
                "reason": .string("helper_timeout"),
                "helper": .string(helper.path),
            ]
            if !partialErr.isEmpty {
                timeoutObject["stderrPreview"] = .string(String(partialErr.prefix(500)))
            }
            return .object(timeoutObject)
        }

        // The child exited; drain to EOF before parsing so a large final flush
        // is never truncated mid-JSON. Waits run CONCURRENTLY and stay short:
        // serial 5s+5s could stretch the helper timeout contract by 10s when a
        // grandchild holds a pipe open (gpt-5.5 review MED) — the normal case
        // (writers closed at exit) returns immediately either way.
        let eofGroup = DispatchGroup()
        eofGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outDrain.waitForEOF(timeout: 2.0, handle: stdout.fileHandleForReading)
            eofGroup.leave()
        }
        errDrain.waitForEOF(timeout: 2.0, handle: stderr.fileHandleForReading)
        eofGroup.wait()
        let outData = outDrain.data
        let errData = errDrain.data
        let stdoutText = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !stdoutText.isEmpty,
           let data = stdoutText.data(using: .utf8),
           let parsed = try? JSONValue.parse(data) {
            if case .object(var obj) = parsed {
                obj["helper"] = .string(helper.path)
                obj["exitCode"] = .int(Int64(process.terminationStatus))
                if !stderrText.isEmpty {
                    obj["stderrPreview"] = .string(String(stderrText.prefix(500)))
                }
                return .object(obj)
            }
            return parsed
        }

        // A capped drain that dropped bytes explains a failed parse honestly:
        // "no JSON" on a >8MiB report is truncation, not a silent helper.
        return .object([
            "status": .string(process.terminationStatus == 0 ? "completed" : "failed"),
            "reason": .string(outDrain.truncated ? "helper_output_truncated" : "helper_returned_no_json"),
            "helper": .string(helper.path),
            "exitCode": .int(Int64(process.terminationStatus)),
            "stderrPreview": .string(String(stderrText.prefix(500))),
        ])
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
        let cwdRaw: String = {
            if case .string(let c)? = input["cwd"], !c.isEmpty { return c }
            _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
            return builderSourceRepoRoot(dataRoot: dataRoot)?.path
                ?? builderWorkspaceRoot(dataRoot: dataRoot).path
        }()
        let timeoutSeconds: Int = {
            if case .int(let i)? = input["timeout_seconds"] { return max(30, min(3600, Int(i))) }
            // 600 -> 180 (the user, 2026-06-09): a hung invoke held the chat for 10
            // silent minutes. 3 min surfaces failure fast; callers with a real
            // long task pass timeout_seconds explicitly (clamp stays 30-3600).
            return 180
        }()

        // Build the prompt — pre-pack context the way last night's spec
        // describes: "context+question with commit hash + summary."
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
            "⏳ Invoking Claude — your ongoing thread, up to \(timeoutSeconds)s…"
        )
        let timedOutFlag = AtomicFlag()
        let heartbeat = Task {
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                elapsed += 30
                await notify?("invoke_progress", "⏳ Claude still working (\(elapsed)s elapsed)…")
            }
        }

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
        // The pointer stores "id\ncwd": the session id + the cwd it was created
        // in (resume-by-id is project-scoped, so we MUST resume from the same dir
        // — gpt-5.5 review MEDIUM).
        // FOLLOW-UP (gpt-5.5 review HIGH): no lock around the session yet —
        // concurrent invokes (same NativeAgent process: Mac chat + Telegram)
        // could race the pointer. Mitigated for now by the conservative
        // rename-aside below (a concurrent failure can't wipe the thread) +
        // Claude Code's own per-session lock; add in-process serialization if
        // concurrent invokes become real.
        let existingLines = (try? String(contentsOf: existingSessionFile, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let sessionId: String
        let sessionArgs: [String]
        let isNewSession: Bool
        let sessionCwd: String
        if let existingLines, let first = existingLines.first, !first.isEmpty {
            sessionId = first
            sessionArgs = ["--resume", sessionId]
            isNewSession = false
            sessionCwd = (existingLines.count >= 2 && !existingLines[1].isEmpty) ? existingLines[1] : cwdRaw
        } else {
            sessionId = UUID().uuidString.lowercased()
            sessionArgs = ["--session-id", sessionId]
            isNewSession = true
            sessionCwd = cwdRaw
        }

        // Resolve `claude` binary. Most users have it in /usr/local/bin/
        // or ~/.claude/bin/, sometimes /opt/homebrew/bin/. Use `env` to
        // honor PATH. Process inherits the user's environment so MCP
        // config, auth, ~/.claude/settings.json all come along.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + sessionArgs + ["-p", fullPrompt]
        process.currentDirectoryURL = URL(fileURLWithPath: sessionCwd)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutBuffer = BoundedBuffer(cap: 512 * 1024)
        let stderrBuffer = BoundedBuffer(cap: 128 * 1024)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        // Result holder so we can return one envelope from the continuation.
        let result: JSONValue = await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            // Single-fire guard — both terminationHandler and the timeout
            // watchdog could try to resume. Continuation must resume EXACTLY once.
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Non-blocking drain: readToEnd would wait for an EOF that a
                // backgrounded grandchild holding the write FD never delivers.
                drainPipeNonBlocking(stdout.fileHandleForReading, into: stdoutBuffer)
                drainPipeNonBlocking(stderr.fileHandleForReading, into: stderrBuffer)
                var stdoutText = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                var stderrText = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                if stdoutBuffer.truncated {
                    stdoutText += "\n[stdout truncated]"
                }
                if stderrBuffer.truncated {
                    stderrText += "\n[stderr truncated]"
                }
                let exitCode = proc.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)

                heartbeat.cancel()
                // Guard the edge where the watchdog fires just as the process
                // exits cleanly: only report a timeout when the exit was
                // actually fatal (gpt-5.5 review nit).
                let didTimeOut = timedOutFlag.isSet && exitCode != 0

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
                    "prompt": fullPrompt,
                    "reply": stdoutText,
                    "stderr": stderrText,
                ]
                if let commitHash { auditEntry["commitHash"] = commitHash }
                if let data = try? JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted]) {
                    try? data.write(to: auditURL)
                }

                // Persist the delegated session id on first successful create
                // so the next invoke RESUMES it. Clear it on a genuine
                // (non-timeout) resume failure so a dead session self-heals into a
                // fresh thread next time instead of failing forever.
                if isNewSession {
                    if exitCode == 0 {
                        // Persist id + the creation cwd so the next invoke resumes
                        // the SAME thread from the SAME project dir.
                        try? "\(sessionId)\n\(sessionCwd)".write(to: sessionFile, atomically: true, encoding: .utf8)
                    }
                } else if exitCode == 0, existingSessionFile != sessionFile {
                    // Promote a successfully resumed legacy pointer to the
                    // identity-neutral filename. Keep the legacy file as a
                    // rollback breadcrumb; all future reads prefer the new one.
                    try? "\(sessionId)\n\(sessionCwd)".write(
                        to: sessionFile,
                        atomically: true,
                        encoding: .utf8
                    )
                } else if exitCode != 0 && !didTimeOut {
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
                    if sessionGone {
                        let stale = existingSessionFile.deletingPathExtension()
                            .appendingPathExtension("stale-\(Int(started.timeIntervalSince1970))")
                        try? FileManager.default.moveItem(at: existingSessionFile, to: stale)
                    }
                }

                if didTimeOut {
                    // Best-effort user-visible line; the failed envelope below is
                    // the durable signal. Sync handler -> hop onto a Task.
                    let timeoutText = "⚠️ Claude invoke timed out after \(timeoutSeconds)s — no reply."
                    Task { await notify?("invoke_timeout", timeoutText) }
                }

                guard resumed.tryResume() else { return }
                if exitCode == 0 {
                    cont.resume(returning: .object([
                        "status": .string("completed"),
                        "runId": .string(runId),
                        "reply": .string(stdoutText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "auditPath": .string(auditURL.path),
                    ]))
                } else {
                    cont.resume(returning: .object([
                        "status": .string("failed"),
                        "reason": .string(didTimeOut
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
                try process.run()
            } catch {
                heartbeat.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard resumed.tryResume() else { return }
                cont.resume(returning: .object([
                    "status": .string("failed"),
                    "reason": .string("spawn_failed"),
                    "runId": .string(runId),
                    "detail": .string(String(describing: error)),
                ]))
                return
            }

            armSubprocessTimeout(process: process, timeoutSeconds: timeoutSeconds) {
                timedOutFlag.set()
            }
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
        let cwdRaw: String = {
            if case .string(let c)? = input["cwd"], !c.isEmpty { return c }
            _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
            return builderSourceRepoRoot(dataRoot: dataRoot)?.path
                ?? builderWorkspaceRoot(dataRoot: dataRoot).path
        }()
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let args = codexExecArguments(
            sandbox: sandbox,
            cwd: cwdRaw,
            lastMessagePath: lastMessageURL.path,
            model: model,
            reasoningEffort: brain.reasoningEffort,
            serviceTier: brain.serviceTier,
            prompt: fullPrompt
        )
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwdRaw)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutBuffer = BoundedBuffer(cap: 512 * 1024)
        let stderrBuffer = BoundedBuffer(cap: 128 * 1024)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        // Watchdog-timeout latch — mirrors invoke_claude so a kill by OUR
        // watchdog reports as a timeout, not an anonymous subprocess_exit_143
        // (gpt-5.5 review MED, 2026-07-02).
        let timedOutFlag = AtomicFlag()
        let result: JSONValue = await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Non-blocking drain — see drainPipeNonBlocking doc comment.
                drainPipeNonBlocking(stdout.fileHandleForReading, into: stdoutBuffer)
                drainPipeNonBlocking(stderr.fileHandleForReading, into: stderrBuffer)
                var stdoutText = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                var stderrText = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                if stdoutBuffer.truncated {
                    stdoutText += "\n[stdout truncated]"
                }
                if stderrBuffer.truncated {
                    stderrText += "\n[stderr truncated]"
                }
                let lastMessage = (try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? ""
                let replyText = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? stdoutText
                    : lastMessage
                let exitCode = proc.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                // Only report a timeout when the exit was actually fatal —
                // same clean-exit-vs-watchdog edge guard as invoke_claude.
                let didTimeOut = timedOutFlag.isSet && exitCode != 0

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
                }

                guard resumed.tryResume() else { return }
                if exitCode == 0 {
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
                        "status": .string("failed"),
                        "reason": .string(didTimeOut
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
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard resumed.tryResume() else { return }
                cont.resume(returning: .object([
                    "status": .string("failed"),
                    "reason": .string("spawn_failed"),
                    "runId": .string(runId),
                    "detail": .string(String(describing: error)),
                ]))
                return
            }

            armSubprocessTimeout(process: process, timeoutSeconds: timeoutSeconds) {
                timedOutFlag.set()
            }
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

    // MARK: - Runs-ledger append for sub-agent spawns
    //
    // Shared tail for invoke_claude / invoke_codex: translate the tool-result
    // envelope into one RunRecord row in <dataRoot>/runs/runs.json. The
    // envelope's "completed" maps to the ledger's "succeeded" (the status
    // string the Runs UI colors green); a watchdog kill maps to "timeout".
    static func appendSpawnRunToLedger(
        kind: String,
        result: JSONValue,
        model: String?,
        prompt: String,
        startedAt: Date,
        dataRoot: URL
    ) async {
        guard case .object(let obj) = result else { return }
        let rawStatus: String = {
            if case .string(let s)? = obj["status"] { return s }
            return "unknown"
        }()
        let timedOut: Bool = {
            if case .bool(let b)? = obj["timedOut"] { return b }
            if case .string(let reason)? = obj["reason"], reason.hasPrefix("timeout_after_") { return true }
            return false
        }()
        let status = rawStatus == "completed" ? "succeeded" : (timedOut ? "timeout" : rawStatus)
        let runId: String = {
            if case .string(let r)? = obj["runId"], !r.isEmpty { return r }
            return UUID().uuidString
        }()
        let reply: String? = {
            if case .string(let r)? = obj["reply"], !r.isEmpty { return r }
            return nil
        }()
        var errorParts: [String] = []
        if status != "succeeded" {
            if case .string(let reason)? = obj["reason"] { errorParts.append(reason) }
            if case .string(let detail)? = obj["detail"], !detail.isEmpty { errorParts.append(detail) }
            if case .string(let stderrText)? = obj["stderr"], !stderrText.isEmpty { errorParts.append(stderrText) }
        }
        await RunLedger.append(
            id: runId,
            kind: kind,
            status: status,
            model: model,
            prompt: prompt,
            output: reply,
            error: errorParts.isEmpty ? nil : errorParts.joined(separator: "\n"),
            createdAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            dataRoot: dataRoot
        )
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
