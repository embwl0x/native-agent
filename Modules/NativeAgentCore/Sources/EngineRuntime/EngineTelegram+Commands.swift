import Foundation
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import BackgroundLoops
import TelegramBot
// Blueprint: | `EngineTelegram+Commands.swift` | Checked token/configuration mutations and diagnostic receipts |

public struct TelegramDiagnosticsClearReceipt: Equatable, Sendable {
    public let clearedAt: String
    public let removedFileCount: Int
    public let removedRowCount: Int
    public let status: TelegramPresentationSnapshot
}

extension TelegramFacade {
    /// Local token syntax cannot prove credentials work; Telegram remains authoritative.
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
        // Empty UI token fields preserve saved credentials while ids are edited; only explicit clear removes them.
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
        // Preserve saved-disabled credentials without resolving them; clear or missing tokens force disabled, otherwise respect explicit enabled state.
        let effectiveEnabled = !clearToken && (!effectiveToken.isEmpty || existing?.tokenConfigured == true) && enabled
        guard !effectiveEnabled || !chatIds.isEmpty || !userIds.isEmpty else {
            throw TelegramConfigurationError.destinationRequired
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty || !trimmedEffort.isEmpty {
            var body: [String: JSONValue] = ["surface": .string("telegram")]
            if !trimmedModel.isEmpty {
                // Change only the model so Telegram retains its chosen route.
                body["model"] = .string(trimmedModel)
            }
            if !trimmedEffort.isEmpty {
                body["reasoningEffort"] = .string(trimmedEffort)
            }
            _ = try await SwiftNativeProviderRouting(dataRoot: root).saveModelConfig(.object(body))
        }
        let cfg = TelegramBot.TelegramConfig(
            botToken: effectiveToken,
            allowedChatIds: chatIds,
            allowedUserIds: userIds,
            requireMention: requireMention,
            enabled: effectiveEnabled,
            voiceTranscriptionEnabled: existing?.voiceTranscriptionEnabled ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionEnabled,
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

    /// Explicit diagnostic reads must not dispatch commands or admit senders.
    public nonisolated func discoverTelegramSenders(token: String) async throws -> Int {
        let root = dataRoot
        let saved = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: root)
        guard saved?.enabled != true else {
            throw TelegramConfigurationError.persistenceFailed(
                "Turn Telegram off and save before checking senders; the active poller already records blocked senders.")
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

    public nonisolated func sendTelegramTestReply(chatId: String?, manager: BackgroundLoopLifetimes) async throws -> TelegramTestResponse {
        let testMessage = "NativeAgent Telegram test reply: online."
        let root = dataRoot
        guard let configuration = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: root),
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
        let impl = SwiftNativeTelegramBot(dataRoot: root)
        let result: TelegramTestResult
        do {
            result = try await impl.sendTestMessage(message: testMessage, chatId: target)
        } catch {
            try? await recordTelegramTestStatus(root: root, error: "Telegram test reply failed: \(error.localizedDescription)")
            throw error
        }
        try await recordTelegramTestSuccess(root: root)
        var response = TelegramTestResponse(result: result)
        let loopStatus = await manager.status()
            .first { $0.name == "telegram_poll" }
        response.tokenConfigured = !configuration.botToken.isEmpty
        response.pollerRegistered = loopStatus != nil
        response.pollerTicking = loopStatus?.running == true
            && (loopStatus?.runCount ?? 0) > 0
            && loopStatus?.lastRun != nil
        return response
    }

    public nonisolated func clearTelegramDiagnostics(manager: BackgroundLoopLifetimes) async throws -> TelegramDiagnosticsClearReceipt {
        // Count receipts before deletion so a completed no-op remains distinguishable from removed diagnostic evidence.
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

    public nonisolated func disconnectTelegram(restartPollLoop: (@Sendable () async -> Bool)? = nil) async throws {
        let root = dataRoot
        try await SwiftNativePersistenceCore.withFileLock(root.appendingPathComponent("telegram/config.json")) {
            let existing = try TelegramConfig.loadSavedConfiguration(dataRoot: root, resolveCredential: false)
            // Validate readback before replacing config, even on disconnect.
            _ = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
            try TelegramConfig.saveToDisk(TelegramConfig(
                botToken: "",
                allowedChatIds: existing?.allowedChatIds ?? [],
                allowedUserIds: existing?.allowedUserIds ?? [],
                requireMention: existing?.requireMention ?? false,
                enabled: false,
                voiceTranscriptionEnabled: existing?.voiceTranscriptionEnabled ?? TelegramConfig.defaultVoiceTranscriptionEnabled,
                voiceMaxBytes: existing?.voiceMaxBytes ?? TelegramConfig.defaultVoiceMaxBytes
            ), dataRoot: root)
        }
        // A draining turn must not hold the settings lock; reload from latest disk state.
        if let restartPollLoop {
            try await SwiftNativePersistenceCore.withFileLock(root.appendingPathComponent("telegram/poll_reload")) {
                guard await restartPollLoop() else {
                    throw TelegramReloadError.pollerUnavailable
                }
            }
        }
    }

    public nonisolated func mobileTelegramSnapshot(manager: BackgroundLoopLifetimes) async throws -> MobileTelegramSnapshot {
        let root = dataRoot
        let url = root.appendingPathComponent("telegram/config.json")
        return try await SwiftNativePersistenceCore.withFileLock(url) {
            let observedAt = Date().timeIntervalSince1970
            // Validate before publishing metadata so malformed settings cannot appear as saved defaults.
            try TelegramConfig.validateMobileConfiguration(at: root)
            let routing = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
            let status = try await TelegramFacade(dataRoot: root).loadStatus(
                manager: manager, routingSnapshot: routing
            )
            if let issue = status.routingIssue {
                throw ProviderRoutingError.configurationFailed(issue)
            }
            guard let model = status.model else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
            let enabled = status.tokenConfigured && status.enabled
            return MobileTelegramSnapshot(
                observedAt: observedAt,
                tokenConfigured: status.tokenConfigured,
                enabled: enabled, requireMention: status.requireMention,
                allowedChatIDs: status.allowedChatIds,
                allowedUserIDs: status.allowedUserIds,
                model: model,
                pollerRunning: enabled && status.pollerEnabled,
                pollStatusMessage: status.pollStatusMessage,
                lastSuccessfulPollAt: status.lastPollAt
            )
        }
    }
}
