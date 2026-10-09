import Foundation
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import BackgroundLoops
import TelegramBot

/// A Telegram settings mutation was rejected before it could make the saved
/// inbound authorization narrower, wider, or unreadable by accident. Keeping
/// this distinct from transport errors lets a mounted settings surface report
/// a configuration failure without claiming that its save took effect.
enum TelegramConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidAllowedChatID(String)
    case invalidAllowedUserID(String)
    case existingConfigurationUnreadable
    case persistenceFailed(String)
    case destinationRequired

    var errorDescription: String? {
        switch self {
        case .invalidAllowedChatID(let value):
            return "Telegram allowed chat ID is not numeric: \(value)"
        case .invalidAllowedUserID(let value):
            return "Telegram allowed user ID is not numeric: \(value)"
        case .existingConfigurationUnreadable:
            return "saved Telegram settings are unreadable; refusing to overwrite them"
        case .persistenceFailed(let detail):
            return "Telegram settings could not be saved: \(detail)"
        case .destinationRequired:
            return "Add an allowed chat or user ID before turning Telegram on. Send your bot a message, then use Check sender in Telegram setup to find your ID."
        }
    }
}

extension NativeClient {
    /// The Settings action accepts an explicit root only for hermetic callers.
    /// The mounted app keeps using the canonical root and restarts the live
    /// poll loop after every successful authority change.
    func configureTelegram(
        token: String,
        allowedChatIds: [String],
        allowedUserIds: [String],
        requireMention: Bool,
        model: String,
        reasoningEffort: String,
        enabled: Bool,
        clearToken: Bool = false,
        dataRoot: URL? = nil,
        restartPollLoop: Bool = true
    ) async throws {
        // DAEMON KILLED 2026-06-02. Persist to <dataRoot>/telegram/config.json.
        // If `token` arrives empty (UI cleared after a successful save), keep
        // the existing on-disk token so the IDs the user just edited don't
        // wipe out the stored token. Clear is still explicit via clearToken.
        let root = dataRoot ?? dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try TelegramBot.TelegramConfig.loadSavedConfiguration(
            dataRoot: root, resolveCredential: !clearToken && trimmedToken.isEmpty
        )
        let effectiveToken: String = {
            if clearToken { return "" }
            if !trimmedToken.isEmpty { return trimmedToken }
            return existing?.botToken ?? ""
        }()
        let chatIds = try Self.telegramIDs(
            allowedChatIds,
            invalid: TelegramConfigurationError.invalidAllowedChatID
        )
        let userIds = try Self.telegramIDs(
            allowedUserIds,
            invalid: TelegramConfigurationError.invalidAllowedUserID
        )
        // Enabled is now explicit: a saved-disabled token must round-trip so
        // the user can toggle the poller off without wiping the token. clearToken
        // and an empty effectiveToken both force enabled=false; otherwise the
        // caller's explicit `enabled` arg wins.
        let effectiveEnabled = !clearToken && !effectiveToken.isEmpty && enabled
        guard !effectiveEnabled || !chatIds.isEmpty || !userIds.isEmpty else {
            throw TelegramConfigurationError.destinationRequired
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedModel = trimmedModel.isEmpty ? existing?.model : trimmedModel
        let migratedEffort = trimmedEffort.isEmpty ? existing?.reasoningEffort : trimmedEffort
        if migratedModel?.isEmpty == false || migratedEffort?.isEmpty == false {
            var body: [String: JSONValue] = ["surface": .string("telegram")]
            if let migratedModel, !migratedModel.isEmpty {
                // S12a: the model only; Telegram keeps its chosen route.
                body["model"] = .string(migratedModel)
            }
            if let migratedEffort, !migratedEffort.isEmpty {
                body["reasoningEffort"] = .string(migratedEffort)
            }
            _ = try await SwiftNativeProviderRouting(dataRoot: root).saveModelConfig(.object(body))
        }
        let cfg = TelegramBot.TelegramConfig(
            botToken: effectiveToken,
            allowedChatIds: chatIds,
            allowedUserIds: userIds,
            requireMention: requireMention,
            enabled: effectiveEnabled,
            model: nil,
            reasoningEffort: nil,
            voiceTranscriptionEnabled: existing?.voiceTranscriptionEnabled ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionEnabled,
            voiceTranscriptionBackend: existing?.voiceTranscriptionBackend ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionBackend,
            voiceTranscriptionModel: existing?.voiceTranscriptionModel ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionModel,
            voiceMaxBytes: existing?.voiceMaxBytes ?? TelegramBot.TelegramConfig.defaultVoiceMaxBytes
        )
        do {
            try TelegramBot.TelegramConfig.saveToDisk(cfg, dataRoot: root)
        } catch {
            throw TelegramConfigurationError.persistenceFailed(error.localizedDescription)
        }
        // F4 fix-3: kick the background loops manager to re-read the file on
        // disk and bring up / tear down the TelegramPollLoop. Without this,
        // the save lands but the previously-running poller keeps the OLD
        // token/allowlist until the next app restart.
        if restartPollLoop {
            _ = await backgroundLoopsManager.restartLoop(id: "telegram_poll")
        }
    }

    /// One owner-requested read, with no command dispatch or sender admission.
    func discoverTelegramSenders(token: String) async throws -> Int {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let saved = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: root)
        guard saved?.enabled != true else {
            throw TelegramConfigurationError.persistenceFailed("Turn Telegram off and save before checking senders; the active poller already records blocked senders.")
        }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = typed.isEmpty ? (saved?.botToken ?? "") : typed
        guard !effective.isEmpty else { throw TelegramConfigurationError.persistenceFailed("Enter or save your bot token first.") }
        return try await TelegramPollLoop.discoverSenders(token: effective, dataRoot: root)
    }

    private static func telegramIDs(
        _ rawIDs: [String],
        invalid: (String) -> TelegramConfigurationError
    ) throws -> Set<Int64> {
        var ids = Set<Int64>()
        for rawID in rawIDs {
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = Int64(trimmed), !trimmed.isEmpty else {
                throw invalid(rawID)
            }
            ids.insert(id)
        }
        return ids
    }

    func testTelegram(
        chatId: String?,
        dataRoot: URL? = nil,
        telegramBot: (any TelegramBotProtocol)? = nil
    ) async throws -> TelegramTestResponse {
        let testMessage = "NativeAgent Telegram test reply: online."
        let root = dataRoot ?? dataRootOverride ?? PersistenceCore.defaultDataRoot()
        guard let configuration = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: root),
              configuration.enabled,
              !configuration.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let reason = "Telegram test reply needs saved, enabled bot credentials."
            try await recordTelegramTestStatus(root: root, error: reason)
            throw TelegramBotError.underlying(reason)
        }
        guard configuration.botToken.contains(":") else {
            let reason = "Telegram test reply was not sent: the saved bot token is malformed."
            try await recordTelegramTestStatus(root: root, error: reason)
            throw TelegramBotError.underlying(reason)
        }
        let allowlist = Set(configuration.allowedChatIds.map(String.init))
            .union(configuration.allowedUserIds.map(String.init))
        guard !allowlist.isEmpty else {
            let reason = "Telegram test reply was not sent: save at least one allowed chat or user ID."
            try await recordTelegramTestStatus(root: root, error: reason)
            throw TelegramBotError.underlying(reason)
        }
        let target = chatId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !target.isEmpty, allowlist.contains(target) else {
            let reason = "Telegram test reply was not sent: its target is not in the saved allowlist."
            try await recordTelegramTestStatus(root: root, error: reason)
            throw TelegramBotError.underlying(reason)
        }
        // SwiftNative Telegram test path. The module reads the saved config and
        // calls Telegram directly; no daemon URL is required.
        let impl = telegramBot ?? SwiftNativeTelegramBot(
            dataRoot: root
        )
        let result: TelegramTestResult
        do {
            result = try await impl.sendTestMessage(message: testMessage, chatId: target)
        } catch {
            try? await recordTelegramTestStatus(root: root, error: "Telegram test reply failed: \(error.localizedDescription)")
            throw error
        }
        try await recordTelegramTestSuccess(root: root)
        var response = try TelegramTestResponse(result: result)
        let loopStatus = await backgroundLoopsManager.status()
            .first { $0.loopId == "telegram_poll" }
        response.tokenConfigured = !configuration.botToken.isEmpty
        response.pollerRegistered = loopStatus != nil
        response.pollerTicking = loopStatus?.running == true
            && (loopStatus?.runCount ?? 0) > 0
            && loopStatus?.lastRun != nil
        return response
    }

    func clearTelegramLogs(
        dataRoot: URL? = nil
    ) async throws -> TelegramDiagnosticsClearReceipt {
        // SwiftNative clear + refreshed status. Take the receipt count before
        // deletion, so the UI can distinguish a completed no-op from a clear
        // that removed diagnostic evidence.
        let root = dataRoot ?? dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let before = try Self.telegramDiagnosticsEvidence(in: root)
        let impl = SwiftNativeTelegramBot(
            dataRoot: root
        )
        try await impl.clearLogs()
        let clearedAt = try await recordTelegramDiagnosticsCleared(root: root)
        // Read the same complete mounted-root status the settings panel uses.
        // The facade combines core transport status with the bounded feeds.
        var status = try await TelegramFacade(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ).load(manager: backgroundLoopsManager.coreManager)
        status.lastDiagnosticsClearedAt = clearedAt
        return TelegramDiagnosticsClearReceipt(
            clearedAt: clearedAt,
            removedFileCount: before.fileCount,
            removedRowCount: before.rowCount,
            status: status
        )
    }

    private static func telegramDiagnosticsEvidence(in root: URL) throws -> (fileCount: Int, rowCount: Int) {
        let directory = root.appendingPathComponent("telegram", isDirectory: true)
        let names = ["logs.jsonl", "receipts.jsonl", "blocked.jsonl", "errors.jsonl", "errors.jsonl.1"]
        var fileCount = 0
        var rowCount = 0
        for name in names {
            let path = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let data = try Data(contentsOf: path)
            fileCount += 1
            rowCount += data.split(separator: 0x0A, omittingEmptySubsequences: true).count
        }
        return (fileCount, rowCount)
    }

    private func recordTelegramTestStatus(root: URL, error: String) async throws {
        try await mutateTelegramDiagnosticsState(root: root) { object in
            object["lastError"] = error
            object["lastTestReplyAt"] = ISO8601DateFormatter().string(from: Date())
        }
    }

    private func recordTelegramDiagnosticsCleared(root: URL) async throws -> String {
        try await mutateTelegramDiagnosticsState(root: root) { object in
            let marker = ISO8601DateFormatter().string(from: Date())
            object["lastDiagnosticsClearedAt"] = marker
            return marker
        }
    }

    private func recordTelegramTestSuccess(root: URL) async throws {
        try await mutateTelegramDiagnosticsState(root: root) { object in
            object.removeValue(forKey: "lastError")
            object["lastReplyAt"] = ISO8601DateFormatter().string(from: Date())
            object["lastTestReplyStatus"] = "sent"
        }
    }

    private func mutateTelegramDiagnosticsState<Result: Sendable>(
        root: URL,
        _ update: @Sendable (inout [String: Any]) -> Result
    ) async throws -> Result {
        let path = root.appendingPathComponent("telegram/state.json")
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(path) {
            var object: [String: Any] = [:]
            if let data = try? Data(contentsOf: path),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = decoded
            }
            let result = update(&object)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path, options: .atomic)
            return result
        }
    }
}
