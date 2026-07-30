import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import ProviderRouting

// MARK: - SwiftNative impl

public actor SwiftNativeTelegramBot: TelegramBotProtocol {
    private let dataRoot: URL
    private let backgroundLoopsManager: BackgroundLoopsManager
    let completenessDeps: TelegramBotCompletenessDeps?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        backgroundLoopsManager: BackgroundLoopsManager = .shared,
        completenessDeps: TelegramBotCompletenessDeps? = nil
    ) {
        self.dataRoot = dataRoot
        self.backgroundLoopsManager = backgroundLoopsManager
        self.completenessDeps = completenessDeps
    }

    public func getStatus() async throws -> TelegramStatus {
        let cfg = TelegramConfig.loadFromDisk(dataRoot: dataRoot)
        let pollerRunning = await backgroundLoopsManager.isRunning(loopId: "telegram_poll")
        let persistence = SwiftNativePersistenceCore()
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        let stateURL = telegramDir.appendingPathComponent("state.json")
        let state = await persistence.readJSON(stateURL, defaultValue: .object([:]))
        let stateObj: [String: JSONValue]
        if case .object(let obj) = state {
            stateObj = obj
        } else {
            stateObj = [:]
        }
        let receipts = (try? await persistence.tailJSONL(
            telegramDir.appendingPathComponent("receipts.jsonl"),
            limit: 25,
            maxBytes: 1_048_576
        )) ?? []
        let blocked = (try? await persistence.tailJSONL(
            telegramDir.appendingPathComponent("blocked.jsonl"),
            limit: 25,
            maxBytes: 1_048_576
        )) ?? []
        let errors = (try? await persistence.tailJSONL(
            telegramDir.appendingPathComponent("errors.jsonl"),
            limit: 25,
            maxBytes: 1_048_576
        )) ?? []
        let commandMenu = stateObj["commandMenu"] ?? .object([
            "commandCount": .int(Int64(TelegramCommandRegistry.commands.count)),
            "registryVersion": .string(TelegramCommandRegistry.version),
            "synced": .bool(false),
        ])
        let voiceEnabled = cfg?.voiceTranscriptionEnabled ?? TelegramConfig.defaultVoiceTranscriptionEnabled
        let voiceBackend = cfg?.voiceTranscriptionBackend ?? TelegramConfig.defaultVoiceTranscriptionBackend
        let voiceModel = cfg?.voiceTranscriptionModel ?? TelegramConfig.defaultVoiceTranscriptionModel
        let voiceMaxBytes = cfg?.voiceMaxBytes ?? TelegramConfig.defaultVoiceMaxBytes
        let voiceBackendSupported = TelegramVoiceTranscriptionBackends.isSupported(voiceBackend)
        let voiceRequiresAPIKey = TelegramVoiceTranscriptionBackends.requiresAPIKey(voiceBackend)
        let voiceKeyConfigured: Bool = {
            guard voiceBackendSupported else { return false }
            guard voiceRequiresAPIKey else { return true }
            return LLMCredentialResolver.resolveAPIKey(
                envVar: "OPENAI_API_KEY",
                providerConfigFile: "openai.json",
                dataRoot: dataRoot
            ) != nil
        }()
        let extras: [String: JSONValue] = [
            "allowedChatIds": .array((cfg?.allowedChatIds.sorted() ?? []).map { .string(String($0)) }),
            "allowedUserIds": .array((cfg?.allowedUserIds.sorted() ?? []).map { .string(String($0)) }),
            "requireMention": .bool(cfg?.requireMention ?? false),
            "model": cfg?.model.map { .string($0) } ?? .null,
            "reasoningEffort": cfg?.reasoningEffort.map { .string($0) } ?? .null,
            "lastPollAt": stateObj["lastPollAt"] ?? .null,
            "commandMenu": commandMenu,
            "voiceTranscription": .object([
                "enabled": .bool(voiceEnabled),
                "backend": .string(voiceBackend),
                "model": .string(voiceModel),
                "maxBytes": .int(Int64(voiceMaxBytes)),
                "backendSupported": .bool(voiceBackendSupported),
                "keyConfigured": .bool(voiceKeyConfigured),
                "requiresAPIKey": .bool(voiceRequiresAPIKey),
            ]),
            "receipts": .array(receipts),
            "blocked": .array(blocked),
            "errors": .array(errors),
        ]
        return TelegramStatus(
            enabled: cfg?.enabled ?? false,
            tokenConfigured: cfg?.botToken.isEmpty == false,
            pollerEnabled: pollerRunning,
            lastSeenUpdateId: _tgJSONInt(stateObj["lastSeenUpdateId"]) ?? _tgJSONInt(stateObj["lastUpdateId"]),
            lastSeenAt: _tgJSONString(stateObj["lastSeenAt"]),
            lastReplyAt: _tgJSONString(stateObj["lastReplyAt"]),
            lastError: _tgJSONString(stateObj["lastError"])
                ?? (cfg == nil ? "No bot token saved - paste one to enable." : nil),
            extras: .object(extras)
        )
    }

    public func sendTestMessage(message: String?, chatId: String?) async throws -> TelegramTestResult {
        guard let cfg = TelegramConfig.loadFromDisk(dataRoot: dataRoot),
              !cfg.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TelegramBotError.notConfigured
        }
        let target: String = {
            if let chatId, !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return chatId.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let first = cfg.allowedChatIds.sorted().first {
                return String(first)
            }
            return ""
        }()
        guard !target.isEmpty else {
            throw TelegramBotError.notConfigured
        }
        guard let url = _tgBuildBotURL(token: cfg.botToken, method: "sendMessage") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "chat_id": target,
            "text": text?.isEmpty == false ? text! : "NativeAgent Telegram test reply: online.",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw TelegramBotError.underlying(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = data.isEmpty ? JSONValue.null : (try? JSONValue.parse(data)) ?? .null
        if (200..<300).contains(status) {
            if case .object(let obj) = parsed,
               case .bool(false)? = obj["ok"],
               case .string(let description)? = obj["description"] {
                throw TelegramBotError.underlying(description)
            }
            return TelegramTestResult(rawResponse: parsed)
        }
        if status == 400 || status == 401 {
            throw TelegramBotError.notConfigured
        }
        throw TelegramBotError.invalidResponse(status: status)
    }

    public func clearLogs() async throws {
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: telegramDir, withIntermediateDirectories: true)
        let persistence = SwiftNativePersistenceCore()
        // "errors.jsonl.1" is the rotation backup (U5 W-D, TelegramErrorLog)
        // — a manual clear means wipe, so the backup goes with the live file.
        // It is removed inside errors.jsonl's flock section: rotation moves
        // the live file to the backup under that same lock, so clearing both
        // under it closes the clear-then-rotate race.
        for name in ["logs.jsonl", "receipts.jsonl", "blocked.jsonl", "errors.jsonl"] {
            let path = telegramDir.appendingPathComponent(name)
            try await persistence.withFileLock(path) {
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                }
                if name == "errors.jsonl" {
                    let backup = path.appendingPathExtension("1")
                    if FileManager.default.fileExists(atPath: backup.path) {
                        try FileManager.default.removeItem(at: backup)
                    }
                }
            }
        }
    }
}

// MARK: - Factory

public func makeTelegramBot() -> any TelegramBotProtocol {
    return SwiftNativeTelegramBot()
}

extension SwiftNativeTelegramBot {
    public func longPoll(
        token: String,
        offset: Int,
        timeoutSeconds: Int = 25,
        session: URLSession = .shared
    ) async throws -> TelegramPollResult {
        guard let url = _tgBuildBotURL(
            token: token,
            method: "getUpdates",
            queryItems: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "timeout", value: String(timeoutSeconds)),
            ]
        ) else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = max(TimeInterval(timeoutSeconds + 10), 35)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TelegramBotError.unavailable
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw TelegramBotError.notConfigured }
        if (500..<600).contains(status) {
            throw TelegramBotError.underlying("server status \(status)")
        }
        if !(200..<300).contains(status) {
            throw TelegramBotError.invalidResponse(status: status)
        }
        let parsed: JSONValue = data.isEmpty ? .null : (try JSONValue.parse(data))
        guard case .object(let obj) = parsed else {
            throw TelegramBotError.underlying("telegram: non-object body")
        }
        let okFlag: Bool = {
            if case .bool(let b)? = obj["ok"] { return b }
            return false
        }()
        if !okFlag {
            var desc = "telegram api error"
            if case .string(let d)? = obj["description"] { desc = d }
            throw TelegramBotError.underlying(desc)
        }
        let resultsValue = obj["result"] ?? .array([])
        var updates: [TelegramUpdate] = []
        if case .array(let arr) = resultsValue {
            for item in arr {
                let itemData = try JSONEncoder().encode(item)
                if let u = try? JSONDecoder().decode(TelegramUpdate.self, from: itemData) {
                    updates.append(u)
                }
            }
        }
        let nextOffset: Int
        if updates.isEmpty {
            nextOffset = offset
        } else {
            nextOffset = (updates.map { $0.updateId }.max() ?? (offset - 1)) + 1
        }
        return TelegramPollResult(updates: updates, nextOffset: nextOffset)
    }

    /// Single-string convenience wrapper. Callers that own the transport
    /// (TelegramPollLoop) use `dispatchSwiftSlashCommandDetailed` so the
    /// post-reply followup (/restart's terminate arm) runs AFTER the reply
    /// send; this wrapper can't sequence that, so it runs the followup
    /// immediately — same behavior as before the detailed split.
    public func dispatchSwiftSlashCommand(
        _ command: String,
        args: [String],
        chatId: Int,
        fromUserId: Int? = nil,
        chatType: String? = nil
    ) async throws -> String? {
        let outcome = try await dispatchSwiftSlashCommandDetailed(
            command, args: args, chatId: chatId,
            fromUserId: fromUserId, chatType: chatType
        )
        outcome.afterReplySent?()
        return outcome.reply
    }

    /// Full dispatch: returns the reply text plus an optional followup the
    /// transport MUST invoke after the reply send attempt completes.
    /// `fromUserId`/`chatType` ride along for owner-gated commands
    /// (/restart): the gate requires a PRIVATE chat and a sender id matching
    /// the allowlisted chat id; nil (legacy callers) fails those closed.
    public func dispatchSwiftSlashCommandDetailed(
        _ command: String,
        args: [String],
        chatId: Int,
        fromUserId: Int? = nil,
        chatType: String? = nil
    ) async throws -> TelegramSlashDispatchOutcome {
        var cmd = command
        if cmd.hasPrefix("/") { cmd.removeFirst() }
        // Strip @botname suffix if present (Telegram appends it in groups).
        if let atIdx = cmd.firstIndex(of: "@") { cmd = String(cmd[..<atIdx]) }
        let lower = TelegramCommandRegistry.canonicalName(for: cmd) ?? cmd.lowercased()
        if let baseReply = try await dispatchBaseSlashCommand(lower, args: args, chatId: chatId) {
            return TelegramSlashDispatchOutcome(reply: baseReply)
        }
        // chatId/fromUserId/chatType ride along for owner-gated completeness
        // commands (/restart); the poll loop only hands us allowlisted
        // updates, but owner-gating re-checks against the on-disk allowlist
        // so a future multi-chat allowlist can't silently widen restart.
        return await dispatchCompletenessCommandDetailed(
            lower, args: args, depsOverride: completenessDeps,
            chatId: chatId, fromUserId: fromUserId, chatType: chatType
        )
    }

    /// The pre-completeness command set. Returns nil for commands owned by
    /// the completeness dispatcher (or unknown ones).
    private func dispatchBaseSlashCommand(
        _ lower: String,
        args: [String],
        chatId: Int
    ) async throws -> String? {
        switch lower {
        case "status":
            let s = try await self.getStatus()
            let enabled = s.enabled ?? false
            let tokenConf = s.tokenConfigured ?? false
            let poller = s.pollerEnabled ?? false
            let seen = s.lastSeenAt ?? "never"
            let session = try? await TelegramSessionStore(dataRoot: dataRoot).status(chatId: chatId)
            var lines = [
                "Telegram: enabled=\(enabled) tokenConfigured=\(tokenConf) lastSeenAt=\(seen)",
                "Runtime: enabled=\(enabled) poller=\(poller) token=\(tokenConf)",
                "Last seen: \(seen)",
            ]
            if let routing = completenessDeps?.routing,
               let info = await routing.modelForSurface("telegram") {
                lines.append("Model: \(info.model) @ \(info.provider)")
            } else {
                lines.append("Model: not configured")
            }
            if let session {
                lines.append("Session: \(session.sessionId) (\(session.messageCount) message(s), persona \(session.persona))")
            } else {
                lines.append("Session: unavailable")
            }
            lines.append("Task: see live Telegram poll loop")
            return lines.joined(separator: "\n")
        case "new":
            let sessionId = try await TelegramSessionStore(dataRoot: dataRoot).startNewSession(chatId: chatId)
            return "Started new Telegram session: \(sessionId)"
        case "reset":
            let result = try await TelegramSessionStore(dataRoot: dataRoot).resetSession(chatId: chatId)
            return "Reset Telegram session \(result.sessionId) (\(result.messagesBefore) message(s) cleared)."
        case "session":
            return try await dispatchSessionCommand(args: args, chatId: chatId)
        case "clear":
            let result = try await TelegramSessionStore(dataRoot: dataRoot).clearSession(chatId: chatId)
            return "Cleared Telegram session \(result.sessionId) (\(result.messagesBefore) message(s) removed)."
        case "compact":
            let result = try await TelegramSessionStore(dataRoot: dataRoot).compactSession(chatId: chatId, force: true)
            if result.compacted {
                return "Compacted Telegram session \(result.sessionId): \(result.messagesBefore) -> \(result.messagesAfter) messages."
            }
            return "Telegram session \(result.sessionId) not compacted: \(result.reason)."
        case "stop":
            return "No Telegram turn is running for this chat."
        case "retry":
            return "Retry is handled by the live Telegram poll loop."
        case "sessions":
            let sessions = try await TelegramSessionStore(dataRoot: dataRoot).recentSessions(limit: 8)
            if sessions.isEmpty {
                return "No chat sessions found."
            }
            let lines = sessions.map { session -> String in
                let updated = session.updatedAt.map { ", updated \($0)" } ?? ""
                return "\(session.id) - \(session.title) (\(session.source), \(session.messageCount) message(s)\(updated))"
            }
            return (["Recent sessions:"] + lines + ["Use /resume <id> to bind this Telegram chat."])
                .joined(separator: "\n")
        case "resume":
            let requested = args.first ?? ""
            let status = try await TelegramSessionStore(dataRoot: dataRoot)
                .bindSession(chatId: chatId, requestedSessionId: requested)
            return """
            Resumed Telegram session: \(status.sessionId)
            Persona: \(status.persona)
            Messages: \(status.messageCount)
            """
        case "persona":
            let store = TelegramSessionStore(dataRoot: dataRoot)
            let persona = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if persona.isEmpty {
                let current = try await store.persona(chatId: chatId) ?? "NativeAgent"
                return "Telegram persona: \(current)"
            }
            let saved = try await store.setPersona(chatId: chatId, persona: persona)
            return "Telegram persona set to \(saved)"
        case "remember":
            let text = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "/remember requires text" }
            guard let memory = completenessDeps?.memory else {
                return "Memory writer is not configured in this Swift build."
            }
            do {
                let id = try await memory.remember(text: text, source: "telegram:/remember")
                return "Remembered: \(id)"
            } catch {
                return "Failed to remember: \(error.localizedDescription)"
            }
        case "note":
            let text = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "/note requires text" }
            do {
                if let memory = completenessDeps?.memory {
                    let id = try await memory.note(text: text, kind: "telegram_note", source: "telegram:/note")
                    return "Saved note: \(id)"
                }
                let id = try await TelegramSessionStore(dataRoot: dataRoot)
                    .appendNote(text: text, kind: "telegram_note", source: "telegram:/note")
                return "Saved note: \(id)"
            } catch {
                return "Failed to save note: \(error.localizedDescription)"
            }
        case "scratch":
            guard let key = args.first else { return "/scratch requires <key> <value>" }
            let value = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "/scratch requires <key> <value>" }
            let sessionId = try await TelegramSessionStore(dataRoot: dataRoot)
                .writeScratch(chatId: chatId, key: key, value: value)
            return "Wrote scratch \(key) for Telegram session \(sessionId)"
        case "tools":
            return """
            Telegram tools use the same Swift chat tool loop and app-wide permissions as the Mac app.
            Tool and skill progress is surfaced in Telegram while the assistant works.
            Available controls: /status /new /reset /session /clear /compact /provider /model /think /brain /persona /remember /note /scratch /help
            """
        default:
            // Not a base command — the caller falls through to the
            // completeness dispatcher (see dispatchSwiftSlashCommandDetailed).
            return nil
        }
    }

    private func dispatchSessionCommand(args: [String], chatId: Int) async throws -> String {
        let store = TelegramSessionStore(dataRoot: dataRoot)
        let subcommand = args.first?.lowercased() ?? "status"
        switch subcommand {
        case "new":
            let sessionId = try await store.startNewSession(chatId: chatId)
            return "Started new Telegram session: \(sessionId)"
        case "reset", "clear":
            let result = try await store.resetSession(chatId: chatId)
            return "Reset Telegram session \(result.sessionId) (\(result.messagesBefore) message(s) cleared)."
        case "status", "current":
            let status = try await store.status(chatId: chatId)
            return """
            Telegram session: \(status.sessionId)
            Persona: \(status.persona)
            Messages: \(status.messageCount)
            """
        default:
            return "/session supports status|new|reset"
        }
    }
}
