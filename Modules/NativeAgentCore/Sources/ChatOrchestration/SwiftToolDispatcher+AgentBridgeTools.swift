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
    /// A wire handle over the builder CLIs' existing conversation state.
    /// NativeAgent does not copy transcripts or create a second session store:
    /// Codex owns its thread id, while Claude and OMP own per-topic pointers.
    private enum BuilderConversationAgent: String {
        case codex
        case claude
        case omp
    }

    private struct BuilderConversationSelection {
        let conversationId: String?
        let resumeId: String?
        let topic: String?
    }

    private enum BuilderConversationReferenceError: Error {
        case malformed(expectedAgent: BuilderConversationAgent)
        case agentMismatch(expected: BuilderConversationAgent, actual: String)
        case topicMismatch(conversationId: String, topic: String)

        var envelope: JSONValue {
            switch self {
            case .malformed(let expectedAgent):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("invalid_conversation_id"),
                    "fix": .string("Pass the exact \(expectedAgent.rawValue):… conversationId returned by the first builder message."),
                ])
            case .agentMismatch(let expected, let actual):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("conversation_agent_mismatch"),
                    "expectedAgent": .string(expected.rawValue),
                    "actualAgent": .string(actual),
                    "fix": .string("Reply with the same builder tool that created this conversation."),
                ])
            case .topicMismatch(let conversationId, let topic):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("conversation_topic_mismatch"),
                    "conversationId": .string(conversationId),
                    "topic": .string(topic),
                    "fix": .string("Omit topic when replying, or use the topic encoded by conversationId."),
                ])
            }
        }
    }

    private static func builderConversationSelection(
        input: [String: JSONValue],
        agent: BuilderConversationAgent,
        topic: String?,
        messageId: String
    ) -> Result<BuilderConversationSelection, BuilderConversationReferenceError> {
        let suppliedReference: String?
        if let rawReference = input["conversation_id"] {
            guard case .string(let raw) = rawReference else {
                return .failure(.malformed(expectedAgent: agent))
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return .failure(.malformed(expectedAgent: agent)) }
            suppliedReference = value
        } else {
            suppliedReference = nil
        }

        guard let suppliedReference else {
            if agent == .codex {
                return .success(.init(conversationId: nil, resumeId: nil, topic: topic))
            }
            let stableTopic = topic ?? "conversation-\(shortStableBuilderMessageId(messageId))"
            let slug = builderTopicSlug(stableTopic)
            return .success(.init(
                conversationId: "\(agent.rawValue):\(slug)",
                resumeId: slug,
                topic: slug
            ))
        }

        let pieces = suppliedReference.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .failure(.malformed(expectedAgent: agent)) }
        let actualAgent = String(pieces[0])
        guard actualAgent == agent.rawValue else {
            return .failure(.agentMismatch(expected: agent, actual: actualAgent))
        }
        let resumeId = String(pieces[1])
        guard !resumeId.isEmpty, resumeId.count <= 160,
              resumeId.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value)
                      || (65...90).contains(value)
                      || (97...122).contains(value)
                      || scalar == "-" || scalar == "_" || scalar == "."
              }) else {
            return .failure(.malformed(expectedAgent: agent))
        }

        if agent != .codex {
            guard builderTopicSlug(resumeId) == resumeId else {
                return .failure(.malformed(expectedAgent: agent))
            }
            if let topic, builderTopicSlug(topic) != resumeId {
                return .failure(.topicMismatch(conversationId: suppliedReference, topic: topic))
            }
        }
        return .success(.init(
            conversationId: suppliedReference,
            resumeId: resumeId,
            topic: agent == .codex ? topic : resumeId
        ))
    }

    /// Matches `topicSlug` in both builder wake helpers: ASCII lowercase
    /// alphanumerics, collapsed dash separators, 64-character ceiling.
    private static func builderTopicSlug(_ raw: String) -> String {
        var output = ""
        var pendingSeparator = false
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(value) || (97...122).contains(value)
            if isASCIIAlphaNumeric {
                if pendingSeparator, !output.isEmpty { output.append("-") }
                pendingSeparator = false
                output.unicodeScalars.append(scalar)
            } else if !output.isEmpty {
                pendingSeparator = true
            }
        }
        let canonical = String(output.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return canonical.isEmpty ? "general" : canonical
    }

    /// File-internal accessor so the replay guard slugs a topic EXACTLY the way
    /// the conversation-reference validator above does. A second slug function
    /// would be a cross-vocabulary seam waiting to silently mismatch.
    static func builderTopicSlugForReplayGuard(_ raw: String) -> String {
        builderTopicSlug(raw)
    }

    private static func shortStableBuilderMessageId(_ messageId: String) -> String {
        SHA256.hash(data: Data(messageId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func stringField(_ name: String, in value: JSONValue) -> String? {
        guard case .object(let object) = value, case .string(let string)? = object[name] else { return nil }
        return string
    }

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
        let workingDirectory: String?
        switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
        case .success(let path):
            workingDirectory = path
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
            if case .double(let d)? = input["timeout_seconds"] { return max(60, min(3600, Int(d))) }
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

        let messageId: String = {
            guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
        }()
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
        if let workingDirectory { entry["workingDirectory"] = .string(workingDirectory) }
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
                    guard object["text"] == .string(text),
                          object["topic"] == inboxEntry["topic"],
                          object["workingDirectory"] == inboxEntry["workingDirectory"] else {
                        return "conflict"
                    }
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
            "note": .string("The durable inbox row is written and a real Claude session is waking. Her final reply returns as a separate bridge event. Use conversationId with claude_message for a contextual follow-up; omit it for new work."),
        ]
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        if let conversationId = conversation.conversationId {
            response["conversationId"] = .string(conversationId)
            response["replyWith"] = .string("claude_message")
        }
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
                timeoutSeconds: timeoutSeconds,
                workingDirectory: workingDirectory
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
        timeoutSeconds: Int? = nil,
        workingDirectory: String? = nil
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
        if let workingDirectory { payload["cwd"] = .string(workingDirectory) }

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
            timeoutSeconds: claudeWakeupHelperTimeoutSeconds(),
            successfulNoJSONStatus: "failed"
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

    // MARK: - OMP asynchronous bridge

    func runOMPMessage(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                "fix": .string("omp_message requires a non-empty 'text' parameter."),
            ])
        }
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
                return max(60, min(3600, Int(value)))
            }
            return 900
        }()
        let workingDirectory: String?
        switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
        case .success(let path): workingDirectory = path
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

        let messageId: String = {
            guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
        }()
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
        if let workingDirectory { row["workingDirectory"] = .string(workingDirectory) }
        if !originSessionId.isEmpty { row["sessionId"] = .string(originSessionId) }
        let inboxEntry = row

        let persistence = SwiftNativePersistenceCore()
        let appendStatus: String
        do {
            appendStatus = try await persistence.withFileLock(inboxURL) {
                let existing = try await persistence.readJSONL(inboxURL).first { value in
                    guard case .object(let object) = value else { return false }
                    return object["messageId"] == .string(messageId) || object["id"] == .string(messageId)
                }
                if case .object(let object)? = existing {
                    guard object["text"] == .string(text),
                          object["topic"] == inboxEntry["topic"],
                          object["workingDirectory"] == inboxEntry["workingDirectory"] else {
                        return "conflict"
                    }
                    return "duplicate"
                }
                try await appendJSONLCapped(
                    .object(inboxEntry),
                    to: inboxURL,
                    using: persistence,
                    maxLines: JSONLLineCaps.ompBridgeInbox,
                    logLabel: "SwiftToolDispatcher.ompMessage",
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
        guard appendStatus != "conflict" else {
            return .object([
                "status": .string("failed"),
                "reason": .string("message_id_conflict"),
                "messageId": .string(messageId),
            ])
        }

        var response: [String: JSONValue] = [
            "status": .string("queued"),
            "messageId": .string(messageId),
            "deduplicated": .bool(appendStatus == "duplicate"),
            "filePath": .string(inboxURL.path),
            "priority": .string(priority),
            "queuedAt": .string(queuedAt),
            "timeoutSeconds": .int(Int64(timeoutSeconds)),
            "note": .string("OMP's final reply returns as a separate bridge event. Use conversationId with omp_message for a contextual follow-up; omit it for new work."),
        ]
        if let topic { response["topic"] = .string(topic) }
        if let conversationId = conversation.conversationId {
            response["conversationId"] = .string(conversationId)
            response["replyWith"] = .string("omp_message")
        }
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        if appendStatus == "duplicate" {
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            response["wakeup"] = await postOMPThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                queuedAt: queuedAt,
                inboxPath: inboxURL.path,
                originSessionId: originSessionId,
                timeoutSeconds: timeoutSeconds,
                workingDirectory: workingDirectory
            )
        }
        return .object(response)
    }

    private func postOMPThreadWakeup(
        messageId: String,
        text: String,
        priority: String,
        topic: String?,
        queuedAt: String,
        inboxPath: String,
        originSessionId: String,
        timeoutSeconds: Int,
        workingDirectory: String?
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
        if !originSessionId.isEmpty { payload["sessionId"] = .string(originSessionId) }
        if let workingDirectory { payload["cwd"] = .string(workingDirectory) }
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
            timeoutSeconds: 30,
            successfulNoJSONStatus: "failed"
        )
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

    /// Repository slugs a codex_message request mentions, most-confident first.
    ///
    /// This exists because forgetting the `repository` parameter silently costs
    /// the caller the whole `github-command-repository-network-v1` execution
    /// profile: no network, no writable checkout, so Codex has zero GitHub paths
    /// and grinds until the harness kills the turn (2026-08-05 incident, turn
    /// 019fd2e5-0b16-7b31-bf28-1df55570c4bd). Omission must be impossible, not
    /// merely rare.
    ///
    /// This widens only WHERE the slug is read from, never the trust boundary:
    /// every candidate still goes through `GitHubCommandCheckoutResolver`, whose
    /// anchor is the checkout's own git remote. The explicit `repository`
    /// parameter already accepts any model-authored slug, so reading one out of
    /// the request text grants no authority the caller did not already have.
    static func repositorySlugCandidates(inRequestText text: String) -> [String] {
        var urlSlugs: [String] = []
        var bareSlugs: [String] = []
        // github.com/<owner>/<name> is unambiguous; a bare owner/name token is a
        // weaker signal and is only consulted when no URL names a repository.
        for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
            var token = String(rawToken).trimmingCharacters(
                in: CharacterSet(charactersIn: "`\"'<>(),;:[]{}!?*")
            )
            if token.isEmpty { continue }
            // Both the https path form and the SSH form git@github.com:owner/name.
            let hostRange = token.range(of: "github.com/") ?? token.range(of: "github.com:")
            if let range = hostRange {
                var slug = String(token[range.upperBound...])
                for suffix in [".git", "/pull", "/issues", "/tree", "/blob", "/commit", "/compare"] {
                    if let cut = slug.range(of: suffix) { slug = String(slug[slug.startIndex..<cut.lowerBound]) }
                }
                let parts = slug.split(separator: "/").prefix(2).map(String.init)
                if parts.count == 2 {
                    let candidate = "\(parts[0])/\(parts[1])"
                    if isWellFormedRepositorySlug(candidate), !urlSlugs.contains(candidate) {
                        urlSlugs.append(candidate)
                    }
                }
                continue
            }
            // A bare token must be exactly owner/name -- never a path fragment
            // ("docs/build_plans" resolves to nothing, but rejecting the shape
            // early keeps the resolver off obviously-wrong candidates).
            if token.hasPrefix("/") || token.hasSuffix("/") { continue }
            if token.hasSuffix(".git") { token = String(token.dropLast(4)) }
            guard isWellFormedRepositorySlug(token) else { continue }
            let parts = token.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0].count >= 2, parts[1].count >= 2 else { continue }
            if !bareSlugs.contains(token) { bareSlugs.append(token) }
        }
        // Cap the resolver's work: each candidate walks directories and shells
        // out to git. A request naming a dozen slugs is not a repo request.
        return Array((urlSlugs.isEmpty ? bareSlugs : urlSlugs).prefix(8))
    }

    /// Resolve at most ONE checkout from the request text. Ambiguity -- two
    /// different repositories that both resolve -- yields nil and the send
    /// proceeds with today's no-profile behavior, because guessing which
    /// repository the caller meant would hand Codex a network-enabled writable
    /// checkout of the wrong tree.
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

    private enum AgentBridgeWorkingDirectoryResolution {
        case success(String?)
        case failure(JSONValue)
    }

    /// Resolve an explicit bridge cwd at the same effect-time TrustCenter
    /// boundary as native shell tools. Canonical workspace/source roots remain
    /// valid in ordinary modes. An external directory requires active Full Mac
    /// file authority plus the explicit outside-workspace allow posture.
    private func resolveAgentBridgeWorkingDirectory(
        input: [String: JSONValue],
        surface: String
    ) async -> AgentBridgeWorkingDirectoryResolution {
        guard case .string(let raw)? = input["working_directory"] else {
            return .success(nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_invalid"),
                "detail": .string("working_directory must name an existing directory."),
            ]))
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_invalid"),
                "workingDirectory": .string(url.path),
                "detail": .string("working_directory must resolve to an existing absolute directory."),
            ]))
        }

        if Self.builderAllowedRoots(dataRoot: dataRoot).contains(where: { root in
            let rootPath = root.path
            return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
        }) {
            return .success(url.path)
        }

        if let reason = MacControlSensitivePathFence.reason(forPath: url.path)
            ?? MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_sensitive_path_denied"),
                "workingDirectory": .string(url.path),
                "detail": .string(reason),
            ]))
        }

        let access = await fullMacToolAccess(surface: surface)
        guard access.fullMacActive,
              access.fileOpsAllowed,
              Self.builderYoloPermissionLevels.contains(access.permissionLevel),
              access.outsideWorkspaceDefault == "allow" else {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_outside_workspace_denied"),
                "workingDirectory": .string(url.path),
                "workspaceRoot": .string(Self.builderWorkspaceRoot(dataRoot: dataRoot).path),
                "detail": .string("An external coding directory requires active Full Mac YOLO with outside-workspace access set to allow."),
            ]))
        }
        return .success(url.path)
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
        let requestedTopic: String? = {
            guard case .string(let raw)? = input["topic"] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        // Resolve the builder conversation before repository inference so a
        // follow-up remains the same worker thread while still using the new
        // message text/topic for trusted checkout selection.
        let messageId: String = {
            guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
        }()
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

        let requestedDirectory: String?
        if dispatcherSuppliedDirectory == nil {
            switch await resolveAgentBridgeWorkingDirectory(input: input, surface: surface) {
            case .success(let path): requestedDirectory = path
            case .failure(let envelope): return envelope
            }
        } else {
            requestedDirectory = nil
        }

        // Trusted path B: any caller may name an owner/name GitHub repository.
        // It is NOT a path -- the app resolves it through the same
        // remote-verified resolver the GitHub Command lane uses, so the trust
        // anchor stays "this checkout's git remote really is that repo" rather
        // than "the model said so". An unresolvable or malformed repository
        // yields nil and the send proceeds with today's no-profile behavior.
        let repositoryResolvedDirectory: String? = {
            guard dispatcherSuppliedDirectory == nil,
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

        // Trusted path C: nobody named a repository, so infer one from the
        // request itself. Same resolver, same remote-verified trust anchor as
        // path B -- this only removes the caller's obligation to remember the
        // parameter, which is what cost the 2026-08-05 turn every GitHub path.
        let inferredRepositoryDirectory: String? = {
            guard dispatcherSuppliedDirectory == nil,
                  requestedDirectory == nil,
                  repositoryResolvedDirectory == nil else { return nil }
            return inferredRepositoryCheckout(fromRequestText: [text, topic ?? ""].joined(separator: "\n"))
        }()

        let workingDirectory = dispatcherSuppliedDirectory
            ?? requestedDirectory
            ?? repositoryResolvedDirectory
            ?? inferredRepositoryDirectory
        // This capability marker is created only from the trusted dispatcher
        // surface plus an app-verified checkout. It is never accepted from
        // model-authored input, topic text, or repository-controlled prose:
        // the inferred path carries it only because the checkout itself was
        // resolved by remote verification, exactly as the explicit path is.
        let executionProfile = (dispatcherSuppliedDirectory != nil
            || repositoryResolvedDirectory != nil
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
                    // executionProfile is part of the equality contract: a row
                    // queued WITHOUT the network profile is not the same work
                    // order as one queued with it. Without this, a resend that
                    // newly resolves a repository is answered "duplicate" while
                    // the durable row still carries no profile -- the response
                    // would advertise a capability the queued turn never gets
                    // (gpt-5.5 review, 2026-08-05).
                    guard object["text"] == .string(text),
                          object["conversationId"] == inboxEntry["conversationId"],
                          object["workingDirectory"] == inboxEntry["workingDirectory"],
                          object["executionProfile"] == inboxEntry["executionProfile"] else {
                        return "conflict"
                    }
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
            "note": .string("NativeAgent queues the inbox row, attempts a Mac notification, wakes Codex, and watches for the final answer. Use the returned conversationId with codex_message for a contextual follow-up; omit it for new work. If Codex is busy, the wake remains queued until that thread is idle."),
        ]
        if let workingDirectory { response["workingDirectory"] = .string(workingDirectory) }
        if let executionProfile {
            // Make the auto-attach observable: a silently-applied profile is
            // indistinguishable from a silently-missing one at the call site.
            response["executionProfile"] = .string(executionProfile)
            response["repositorySource"] = .string(
                dispatcherSuppliedDirectory != nil ? "dispatcher"
                    : repositoryResolvedDirectory != nil ? "repository_parameter"
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
        if deduplicated {
            // A duplicate message_id means this exact actionable event already
            // queued its inbox row and fired its wakeup on first delivery.
            // Re-poking the codex thread would double-wake it, so skip the
            // wakeup side effect entirely and report the dedup outcome.
            response["wakeup"] = .object(["status": .string("deduplicated")])
        } else {
            let wakeup = await postCodexThreadWakeup(
                messageId: messageId,
                text: text,
                priority: priority,
                topic: topic,
                queuedAt: timestamp,
                inboxPath: path,
                originSessionId: originSessionId,
                origin: origin,
                brain: brain,
                threadId: conversation.resumeId,
                workingDirectory: workingDirectory,
                executionProfile: executionProfile
            )
            response["wakeup"] = wakeup
            let conversationId = conversation.conversationId
                ?? Self.stringField("threadId", in: wakeup).map { "codex:\($0)" }
            if let conversationId {
                response["conversationId"] = .string(conversationId)
                response["replyWith"] = .string("codex_message")
            }
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

    private static func returnBridgeUnavailableEnvelope(
        _ readiness: AgentBridgeRuntime.ReturnPathReadiness
    ) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string("return_bridge_unavailable"),
            "detail": .string(readiness.reason),
            "return_path_ready": .bool(false),
            "token_present": .bool(readiness.tokenPresent),
            "descriptor_present": .bool(readiness.descriptorPresent),
            "fix": .string("Keep NativeAgent open and retry. The authenticated local return bridge starts automatically; Developer Mode is not required."),
        ])
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
            if let threadId { payload["threadId"] = .string(threadId) }
            if let workingDirectory { payload["workingDirectory"] = .string(workingDirectory) }
            if let executionProfile { payload["executionProfile"] = .string(executionProfile) }
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

    /// One lifecycle owner for the Codex, Claude, and OMP wake helpers. The
    /// shared adapter drains both pipes while the child runs, feeds stdin off
    /// the waiting path, bounds captured output, and owns cancellation plus
    /// process-tree timeout escalation. Builder-specific wrappers only supply
    /// environment and deadline policy.
    private static func runBuilderWakeupHelper(
        node: URL,
        helper: URL,
        inputData: Data,
        cwd: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        successfulNoJSONStatus: String
    ) async -> JSONValue {
        let result: ProcessRunResult
        do {
            result = try await SystemProcessAdapter().run(
                executable: node.path,
                arguments: [helper.path],
                currentDirectory: cwd,
                environment: environment,
                standardInput: inputData,
                timeoutSeconds: timeoutSeconds,
                outputByteLimit: 8 * 1024 * 1024
            )
        } catch is CancellationError {
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_cancelled"),
                "helper": .string(helper.path),
            ])
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_spawn_failed"),
                "helper": .string(helper.path),
                "error": .string(String(describing: error)),
            ])
        }

        let stderrText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut {
            var envelope: [String: JSONValue] = [
                "status": .string("failed"),
                "reason": .string("helper_timeout"),
                "helper": .string(helper.path),
            ]
            if !stderrText.isEmpty {
                envelope["stderrPreview"] = .string(String(stderrText.prefix(500)))
            }
            return .object(envelope)
        }

        let stdoutText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = stdoutText.split(separator: "\n").last.map(String.init) ?? ""
        let parsed = [stdoutText, lastLine]
            .lazy
            .filter { !$0.isEmpty }
            .compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONValue.parse($0) }
            .first
        if let parsed {
            if case .object(var object) = parsed {
                object["helper"] = .string(helper.path)
                object["exitCode"] = .int(Int64(result.exitCode))
                if !stderrText.isEmpty {
                    object["stderrPreview"] = .string(String(stderrText.prefix(500)))
                }
                return .object(object)
            }
            return parsed
        }

        return .object([
            "status": .string(result.exitCode == 0 ? successfulNoJSONStatus : "failed"),
            "reason": .string(result.stdoutTruncated ? "helper_output_truncated" : "helper_returned_no_json"),
            "helper": .string(helper.path),
            "exitCode": .int(Int64(result.exitCode)),
            "stderrPreview": .string(String(stderrText.prefix(500))),
        ])
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
            timeoutSeconds: codexWakeupHelperTimeoutSeconds(),
            successfulNoJSONStatus: "completed"
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
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let claude = AgentBridgeRuntime.executableURL(named: "claude", environment: environment) else {
            heartbeat.cancel()
            return .object([
                "status": .string("failed"),
                "reason": .string("claude_cli_not_found"),
                "fix": .string("Install and sign in to Claude Code, then restart NativeAgent."),
            ])
        }
        let process = Process()
        process.executableURL = claude
        process.arguments = sessionArgs + ["-p", fullPrompt]
        process.currentDirectoryURL = URL(fileURLWithPath: sessionCwd)
        process.environment = environment

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

// MARK: - Stale-wakeup replay guard (W2b, upgrade campaign 2026-08 Track A)
//
// L1#14, in User's words: "the bridge is still replaying old wakeups as if they
// are new." The shape of that failure is narrow and identifiable — the SAME
// message text, on the SAME topic, fired again at a runner that already ran it
// to completion and already handed the answer back. Each replay costs a real
// spawned session, real tokens, and produces a second copy of an answer nobody
// asked for twice.
//
// This guard reads the target store BEFORE the wakeup spawn and returns a
// receipt instead of enqueuing, when and only when all four hold:
//
//   1. Same topic slug (slugged through the dispatcher's own
//      `builderTopicSlug`, never a second implementation).
//   2. Byte-identical payload text. Same topic with DIFFERENT text is normal
//      follow-up work and must always go through — this is the single most
//      important non-suppression, because getting it wrong silently strands
//      real work.
//   3. The prior job is TERMINAL: it carries a completion stamp or a terminal
//      status word. An in-flight job is not a replay; the bridges already
//      serialize per topic and have their own in-flight handling.
//   4. The prior job's answer was CONFIRMED DELIVERED. A job whose delivery was
//      lost or unconfirmed is deliberately NOT suppressed — re-asking after an
//      answer went missing is the correct human action, and blocking it would
//      strand the work permanently. This is why the guard cannot be "is there a
//      terminal job with this topic".
//
// Plus a recency window (default 24h): an identical request made weeks later is
// a deliberate re-run, not a replay.
//
// WIRE FENCE: nothing here writes, and no script/*.js is touched. The store
// paths mirror the JS writers' own resolution order (env override, then
// ~/.config) so the guard can never read a different directory than the writer.
enum WakeupReplayGuard {

    enum Store {
        case claude
        case omp
        case codex
    }

    /// Everything the receipt needs to say WHICH prior job matched. Every field
    /// is read off the record — nothing is inferred.
    struct Match: Equatable {
        let jobId: String
        let topicSlug: String
        let completedAt: String?
        let statusWord: String?
        let storeLabel: String
    }

    /// How long an identical completed request keeps suppressing a re-fire.
    static let defaultWindow: TimeInterval = 24 * 60 * 60

    /// Escape hatch. Set to 1/true/yes to force every wakeup through, e.g. when
    /// deliberately re-running an identical delegated job.
    static let disableEnvironmentKey = "NATIVE_AGENT_WAKEUP_REPLAY_GUARD_DISABLED"

    static func isDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = environment[disableEnvironmentKey]?.lowercased() ?? ""
        return ["1", "true", "yes"].contains(raw)
    }

    /// Resolve the jobs directory for a store, mirroring the JS writer's own
    /// order: an explicit override (tests / `agentBridgeConfigRoot`) wins, then
    /// the writer's env var, then `~/.config`.
    static func jobsDirectory(
        for store: Store,
        configRoot: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        func home(_ bridge: String) -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent(bridge, isDirectory: true)
        }
        switch store {
        case .claude:
            let base = configRoot?.appendingPathComponent("claude-bridge", isDirectory: true)
                ?? environment["NATIVE_AGENT_CLAUDE_BRIDGE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home("claude-bridge")
            return base.appendingPathComponent("wake-jobs", isDirectory: true)
        case .omp:
            let base = configRoot?.appendingPathComponent("omp-bridge", isDirectory: true)
                ?? environment["NATIVE_AGENT_OMP_BRIDGE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home("omp-bridge")
            return base.appendingPathComponent("wake-jobs", isDirectory: true)
        case .codex:
            if let configRoot {
                return configRoot
                    .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
                    .appendingPathComponent("reply-jobs", isDirectory: true)
            }
            if let override = environment["NATIVE_AGENT_CODEX_REPLY_JOBS_DIR"] {
                return URL(fileURLWithPath: override)
            }
            return home("codex-nativeagent-bridge")
                .appendingPathComponent("reply-jobs", isDirectory: true)
        }
    }

    /// The prior terminal, delivered, identical job — or nil, meaning "post the
    /// wakeup". Every failure to read is nil: the guard NEVER blocks work
    /// because a directory was unreadable.
    static func terminalDuplicate(
        store: Store,
        jobsDirectory: URL,
        topic: String?,
        text: String,
        now: Date,
        window: TimeInterval = defaultWindow
    ) -> Match? {
        let wanted = SwiftToolDispatcher.builderTopicSlugForReplayGuard(topic ?? "")
        guard !text.isEmpty else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)) ?? []
        var best: (Match, Date)?
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = jobsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONValue.parse(data),
                  case .object(let record) = parsed else { continue }
            guard let candidate = match(
                store: store, record: record, url: url,
                wantedSlug: wanted, text: text, now: now, window: window
            ) else { continue }
            // Newest match wins, so the receipt names the most recent run.
            let stamp = parseISO(candidate.completedAt) ?? .distantPast
            if best == nil || stamp > best!.1 { best = (candidate, stamp) }
        }
        return best?.0
    }

    private static func match(
        store: Store,
        record: [String: JSONValue],
        url: URL,
        wantedSlug: String,
        text: String,
        now: Date,
        window: TimeInterval
    ) -> Match? {
        switch store {
        case .claude, .omp:
            // Both wake-job writers persist the whole request under `payload`.
            guard case .object(let payload)? = record["payload"],
                  string(payload, "text") == text else { return nil }
            // `topicSlug` is written by the claude runner; the OMP record only
            // carries the raw topic in its payload, so slug that instead. Both
            // go through the dispatcher's slug function, so both agree.
            let slug = string(record, "topicSlug")
                ?? SwiftToolDispatcher.builderTopicSlugForReplayGuard(string(payload, "topic") ?? "")
            guard slug == wantedSlug else { return nil }
            let completedAt = string(record, "completedAt")
            let statusWord = (string(record, "runStatus") ?? string(record, "status"))?.lowercased()
            guard isTerminal(completedAt: completedAt, statusWord: statusWord) else { return nil }
            guard succeeded(statusWord: statusWord) else { return nil }
            guard deliveryConfirmed(record) else { return nil }
            guard withinWindow(completedAt, now: now, window: window) else { return nil }
            return Match(
                jobId: string(record, "messageId") ?? url.deletingPathExtension().lastPathComponent,
                topicSlug: slug,
                completedAt: completedAt,
                statusWord: statusWord,
                storeLabel: store == .claude ? "claude" : "omp"
            )

        case .codex:
            // A DELIVERED codex reply-job is unlinked by the bridge, so a
            // terminal record still sitting in reply-jobs/ is one whose handoff
            // is pending recovery — the WORK is done, and re-firing duplicates
            // it. Records preserved under `undelivered/` are never scanned (the
            // caller does not descend into it), which is the point: an
            // undeliverable job must stay re-askable.
            guard case .array(let entries)? = record["entries"] else { return nil }
            var matched = false
            for entry in entries {
                guard case .object(let e) = entry,
                      case .object(let payload)? = e["payload"],
                      string(payload, "text") == text else { continue }
                let slug = SwiftToolDispatcher.builderTopicSlugForReplayGuard(
                    string(payload, "topic") ?? "")
                if slug == wantedSlug { matched = true; break }
            }
            guard matched else { return nil }
            guard case .object(let execution)? = record["completedExecution"],
                  case .object(let turnResult)? = execution["turnResult"] else { return nil }
            let completedAt = string(turnResult, "completedAt")
            let statusWord = string(turnResult, "status")?.lowercased()
            guard isTerminal(completedAt: completedAt, statusWord: statusWord) else { return nil }
            guard succeeded(statusWord: statusWord) else { return nil }
            guard withinWindow(completedAt, now: now, window: window) else { return nil }
            return Match(
                jobId: string(record, "id") ?? url.deletingPathExtension().lastPathComponent,
                topicSlug: wantedSlug,
                completedAt: completedAt,
                statusWord: statusWord,
                storeLabel: "codex"
            )
        }
    }

    static let terminalStatusWords: Set<String> = [
        "completed", "complete", "succeeded", "success",
        "failed", "failure", "error", "errored",
        "timeout", "timed_out", "cancelled", "canceled", "aborted", "spawn_failed",
    ]

    static let successStatusWords: Set<String> = [
        "completed", "complete", "succeeded", "success",
    ]

    static func isTerminal(completedAt: String?, statusWord: String?) -> Bool {
        if completedAt != nil { return true }
        if let statusWord, terminalStatusWords.contains(statusWord) { return true }
        return false
    }

    /// A FAILED prior run is not a replay to suppress — retrying failed work is
    /// exactly what a re-send is for.
    static func succeeded(statusWord: String?) -> Bool {
        guard let statusWord else { return false }
        return successStatusWords.contains(statusWord)
    }

    /// Claude writes `bridgeStatus`; OMP writes a `bridge` object with a
    /// `status`. Only an explicit "delivered" counts — `deliveryLost` true, an
    /// unknown bridge status, or no bridge record at all all mean the answer is
    /// not known to have arrived, so the re-send goes through.
    static func deliveryConfirmed(_ record: [String: JSONValue]) -> Bool {
        if case .bool(true)? = record["deliveryLost"] { return false }
        if let status = string(record, "bridgeStatus") { return status == "delivered" }
        if case .object(let bridge)? = record["bridge"] {
            return string(bridge, "status") == "delivered"
        }
        return false
    }

    static func withinWindow(_ completedAt: String?, now: Date, window: TimeInterval) -> Bool {
        // No completion stamp means we cannot prove recency. Terminal-by-status
        // with no timestamp is a legacy/hand-edited shape; treat it as OUT of
        // the window so the wakeup proceeds rather than being blocked by a
        // record we cannot date.
        guard let date = parseISO(completedAt) else { return false }
        return now.timeIntervalSince(date) <= window && date <= now.addingTimeInterval(window)
    }

    /// The receipt that replaces the wakeup envelope. `status: "skipped"` keeps
    /// it in the same vocabulary the other non-spawn outcomes already use
    /// (`disabled_by_environment`, `helper_not_found`, `deduplicated`), so no
    /// caller needs a new branch to understand it.
    static func receipt(_ match: Match) -> JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string("skipped"),
            "reason": .string("already_completed"),
            "jobId": .string(match.jobId),
            "topicSlug": .string(match.topicSlug),
            "store": .string(match.storeLabel),
            "detail": .string("This exact request already ran to completion on this topic and "
                + "its answer was delivered. The durable inbox row was still written; only the "
                + "duplicate wake was skipped."),
            "fix": .string("Change the message text to send new work on this topic, or set "
                + "\(disableEnvironmentKey)=1 to force an identical re-run."),
        ]
        if let completedAt = match.completedAt { obj["completedAt"] = .string(completedAt) }
        if let statusWord = match.statusWord { obj["priorRunStatus"] = .string(statusWord) }
        return .object(obj)
    }

    // MARK: - Local readers (deliberately not shared with the projector: this
    // guard must keep working if that file changes shape, and the two answer
    // different questions).

    private static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s.isEmpty ? nil : s }
        return nil
    }

    static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso)
    }
}
