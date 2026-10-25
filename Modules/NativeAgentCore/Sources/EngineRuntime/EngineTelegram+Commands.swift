import Foundation
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import BackgroundLoops
import TelegramBot
// Blueprint: | `EngineTelegram+Commands.swift` | Telegram configuration and mobile commands; Telegram token admission, settings and delivery commands, typed diagnostic-clear receipt; diagnostic state edits delegate to TelegramPollLoop.mutateState |

public struct TelegramDiagnosticsClearReceipt: Equatable, Sendable {
    public let clearedAt: String
    public let removedFileCount: Int
    public let removedRowCount: Int
    public let status: TelegramPresentationSnapshot
}

extension TelegramFacade {
    /// A Telegram token is a numeric bot identifier followed by an opaque,
    /// URL-safe secret.  This is intentionally local syntax validation only:
    /// Telegram remains the authority that can prove a credential works.
    public nonisolated static func tokenValidationMessage(for draft: String) -> String? {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              !pieces[0].isEmpty,
              !pieces[1].isEmpty,
              pieces[0].allSatisfy(\.isNumber),
              pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else {
            return "Enter a BotFather token in numeric-bot-ID:secret form. The token was not saved."
        }
        return nil
    }


    public nonisolated func configureTelegram(
        token: String,
        allowedChatIds: [String],
        allowedUserIds: [String],
        requireMention: Bool,
        model: String,
        reasoningEffort: String,
        enabled: Bool,
        clearToken: Bool = false,
        restartPollLoop: (@Sendable () async -> Void)? = nil
    ) async throws {
        // If `token` arrives empty (UI cleared after a successful save), keep
        // the existing on-disk token so the IDs the user just edited don't
        // wipe out the stored token. Clear is still explicit via clearToken.
        let root = dataRoot
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = try CredentialFileLock.withLock(root.appendingPathComponent("telegram/config.json")) {
            let configuration = try TelegramConfig.loadSavedConfiguration(dataRoot: root, resolveCredential: false)
            return (configuration: configuration, revision: try TelegramConfig.savedRevision(dataRoot: root))
        }
        let existing = snapshot.configuration
        let effectiveToken = clearToken ? "" : trimmedToken
        let chatIds = try Self.telegramIDs(
            allowedChatIds,
            invalid: TelegramConfigurationError.invalidAllowedChatID
        )
        let userIds = try Self.telegramIDs(
            allowedUserIds,
            invalid: TelegramConfigurationError.invalidAllowedUserID
        )
        // A saved-disabled token round-trips without being resolved before the
        // routing await. Clear and missing credentials force enabled=false;
        // otherwise the caller's explicit `enabled` arg wins.
        let effectiveEnabled = !clearToken && (!effectiveToken.isEmpty || existing?.tokenConfigured == true) && enabled
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
            try TelegramBot.TelegramConfig.saveToDisk(cfg, dataRoot: root,
                expectedRevision: clearToken ? nil : snapshot.revision,
                keepExistingToken: !clearToken && trimmedToken.isEmpty)
        } catch {
            throw TelegramConfigurationError.persistenceFailed(error.localizedDescription)
        }
        // Reload after persistence so the poller cannot retain old authority.
        if let restartPollLoop { await restartPollLoop() }
    }

    /// One owner-requested read, with no command dispatch or sender admission.
    public nonisolated func discoverTelegramSenders(token: String) async throws -> Int {
        let root = dataRoot
        let saved = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: root)
        guard saved?.enabled != true else {
            throw TelegramConfigurationError.persistenceFailed("Turn Telegram off and save before checking senders; the active poller already records blocked senders.")
        }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = typed.isEmpty ? (saved?.botToken ?? "") : typed
        guard !effective.isEmpty else { throw TelegramConfigurationError.persistenceFailed("Enter or save your bot token first.") }
        return try await TelegramPollLoop.discoverSenders(token: effective, dataRoot: root)
    }

    private nonisolated static func telegramIDs(
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

    public nonisolated func sendTelegramTestReply(chatId: String?, manager: BackgroundLoopsManager) async throws -> TelegramTestResponse {
        let testMessage = "NativeAgent Telegram test reply: online."
        let root = dataRoot
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
        let impl = SwiftNativeTelegramBot(dataRoot: root)
        let result: TelegramTestResult
        do {
            result = try await impl.sendTestMessage(message: testMessage, chatId: target)
        } catch {
            try? await recordTelegramTestStatus(root: root, error: "Telegram test reply failed: \(error.localizedDescription)")
            throw error
        }
        try await recordTelegramTestSuccess(root: root)
        var response = try TelegramTestResponse(result: result)
        let loopStatus = await manager.status()
            .first { $0.name == "telegram_poll" }
        response.tokenConfigured = !configuration.botToken.isEmpty
        response.pollerRegistered = loopStatus != nil
        response.pollerTicking = loopStatus?.running == true
            && (loopStatus?.runCount ?? 0) > 0
            && loopStatus?.lastRun != nil
        return response
    }

    public nonisolated func clearTelegramDiagnostics(manager: BackgroundLoopsManager) async throws -> TelegramDiagnosticsClearReceipt {
        // SwiftNative clear + refreshed status. Take the receipt count before
        // deletion, so the UI can distinguish a completed no-op from a clear
        // that removed diagnostic evidence.
        let root = dataRoot
        let before = try Self.telegramDiagnosticsEvidence(in: root)
        let impl = SwiftNativeTelegramBot(
            dataRoot: root
        )
        try await impl.clearLogs()
        let clearedAt = try await recordTelegramDiagnosticsCleared(root: root)
        let status = try await refresh(manager: manager)
        return TelegramDiagnosticsClearReceipt(
            clearedAt: clearedAt,
            removedFileCount: before.fileCount,
            removedRowCount: before.rowCount,
            status: status
        )
    }

    private nonisolated static func telegramDiagnosticsEvidence(in root: URL) throws -> (fileCount: Int, rowCount: Int) {
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

    private nonisolated func recordTelegramTestStatus(root: URL, error: String) async throws {
        try await TelegramPollLoop.mutateState(dataRoot: root) { object in
            object["lastError"] = .string(error)
        }
    }

    private nonisolated func recordTelegramDiagnosticsCleared(root: URL) async throws -> String {
        try await TelegramPollLoop.mutateState(dataRoot: root) { object in
            let marker = ISO8601DateFormatter().string(from: Date())
            object["lastDiagnosticsClearedAt"] = .string(marker)
            return marker
        }
    }

    private nonisolated func recordTelegramTestSuccess(root: URL) async throws {
        try await TelegramPollLoop.mutateState(dataRoot: root) { object in
            object.removeValue(forKey: "lastError")
            object["lastReplyAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        }
    }
}

extension TelegramFacade {
    private enum TelegramReloadError: Error { case pollerUnavailable }

    public nonisolated func changeTelegramSettings(_ change: MobileTelegramChange, restartPollLoop: @Sendable () async -> Bool) async throws {
        let root = dataRoot
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(root.appendingPathComponent("telegram/config.json")) {
            try TelegramConfig.validateMobileConfiguration(at: root)
            let existing = TelegramConfig.loadFromDisk(dataRoot: root, includeDisconnected: true)
            var token = existing?.botToken ?? ""
            var enabled = existing?.enabled ?? false
            let requireMention = existing?.requireMention ?? false
            switch change {
            case .disconnect:
                token = ""
                enabled = false
            }
            // Validate readback before replacing config, including on disconnect.
            _ = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
            try TelegramConfig.saveToDisk(TelegramConfig(
                botToken: token,
                allowedChatIds: existing?.allowedChatIds ?? [],
                allowedUserIds: existing?.allowedUserIds ?? [],
                requireMention: requireMention,
                enabled: enabled,
                model: existing?.model,
                reasoningEffort: existing?.reasoningEffort,
                voiceTranscriptionEnabled: existing?.voiceTranscriptionEnabled ?? TelegramConfig.defaultVoiceTranscriptionEnabled,
                voiceTranscriptionBackend: existing?.voiceTranscriptionBackend ?? TelegramConfig.defaultVoiceTranscriptionBackend,
                voiceTranscriptionModel: existing?.voiceTranscriptionModel ?? TelegramConfig.defaultVoiceTranscriptionModel,
                voiceMaxBytes: existing?.voiceMaxBytes ?? TelegramConfig.defaultVoiceMaxBytes
            ), dataRoot: root)
        }
        // A draining turn must not hold the settings lock; reload from latest disk state.
        try await persistence.withFileLock(root.appendingPathComponent("telegram/poll_reload")) {
            guard await restartPollLoop() else {
                throw TelegramReloadError.pollerUnavailable
            }
        }
    }

    public nonisolated func mobileTelegramSnapshot(manager: BackgroundLoopsManager) async throws -> MobileTelegramSnapshot {
        let root = dataRoot
        let url = root.appendingPathComponent("telegram/config.json")
        return try await SwiftNativePersistenceCore().withFileLock(url) {
            let observedAt = Date().timeIntervalSince1970
            // Validate before decoding legacy spellings or a disconnected state,
            // so malformed settings never appear as saved defaults.
            try TelegramConfig.validateMobileConfiguration(at: root)
            let routing = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
            guard let preference = routing.preferences["telegram"] else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
            let status = try await TelegramFacade(dataRoot: root).loadStatus(
                manager: manager, routingSnapshot: routing
            )
            let enabled = status.tokenConfigured && status.enabled
            return MobileTelegramSnapshot(
                observedAt: observedAt,
                tokenConfigured: status.tokenConfigured,
                enabled: enabled, requireMention: status.requireMention,
                allowedChatIDs: status.allowedChatIds,
                allowedUserIDs: status.allowedUserIds,
                model: preference.model,
                pollerRunning: enabled && status.pollerEnabled,
                pollStatusMessage: status.pollStatusMessage,
                lastSuccessfulPollAt: status.lastPollAt
            )
        }
    }
}
