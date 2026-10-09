import Foundation
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TelegramBot
import NativeAgentCore

extension AppDeviceSyncHost {
    func telegramSnapshot() async throws -> MobileTelegramSnapshot {
        try await NativeClient().mobileTelegramSnapshot()
    }

    func changeTelegram(_ change: MobileTelegramChange) async throws -> MobileTelegramSnapshot {
        let client = NativeClient()
        try await client.changeTelegramSettings(change)
        return try await client.mobileTelegramSnapshot()
    }
}

extension NativeClient {
    private enum TelegramReloadError: Error { case pollerUnavailable }

    func changeTelegramSettings(_ change: MobileTelegramChange) async throws {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(root.appendingPathComponent("telegram/config.json")) {
            try Self.validateMobileTelegramConfiguration(at: root)
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
            guard await backgroundLoopsManager.restartLoop(id: "telegram_poll").didRestart else {
                throw TelegramReloadError.pollerUnavailable
            }
        }
    }

    private static func validateMobileTelegramConfiguration(at root: URL) throws {
        let url = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        } catch CocoaError.fileReadNoSuchFile { return }
        catch { throw TelegramConfigurationError.existingConfigurationUnreadable }
        try TelegramConfig.validateSavedConfiguration(dataRoot: root)
        guard TelegramConfig.loadFromDisk(dataRoot: root, includeDisconnected: true) != nil else {
            throw TelegramConfigurationError.existingConfigurationUnreadable
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else {
            throw TelegramConfigurationError.existingConfigurationUnreadable
        }
        for key in ["enabled", "require_mention", "voice_transcription_enabled", "voice_enabled"] {
            // Missing fields retain legacy defaults; present authority must
            // be a JSON boolean, never a coerced number or decoder fallback.
            guard let raw = fields[key] else { continue }
            guard let value = raw as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        }
        // Validate every spelling the codec consumes, even when a canonical
        // spelling shadows it. A fallback must never erase damaged settings.
        for key in ["bot_token", "token", "model", "reasoning_effort", "reasoningEffort",
                    "voice_transcription_backend", "voice_backend", "voice_transcription_model", "voice_model"] {
            if let value = fields[key], !(value is String) {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        }
        for key in ["voice_max_bytes", "voice_max_mb"] {
            guard let value = fields[key] else { continue }
            if key == "voice_max_bytes" {
                if let number = value as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.int64Value > 0,
                   number.compare(NSNumber(value: number.int64Value)) == .orderedSame { continue }
                if let string = value as? String, let bytes = Int(string), bytes > 0 { continue }
            } else {
                let megabytes: Double?
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    megabytes = number.doubleValue
                } else if let string = value as? String {
                    megabytes = Double(string)
                } else { megabytes = nil }
                if let megabytes, megabytes.isFinite,
                   let bytes = Int(exactly: (megabytes * 1024 * 1024).rounded(.towardZero)), bytes > 0 { continue }
            }
            throw TelegramConfigurationError.existingConfigurationUnreadable
        }
        for key in ["allowed_chat_ids", "allowed_user_ids"] {
            // Missing lists are valid legacy deny-all defaults; present lists
            // must decode completely before any setting can be rewritten.
            guard let raw = fields[key] else { continue }
            guard let values = raw as? [Any] else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
            for value in values {
                if let number = value as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.compare(NSNumber(value: number.int64Value)) == .orderedSame {
                    continue
                }
                if let string = value as? String, Int64(string) != nil { continue }
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        }
    }

    func mobileTelegramSnapshot() async throws -> MobileTelegramSnapshot {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let url = root.appendingPathComponent("telegram/config.json")
        return try await SwiftNativePersistenceCore().withFileLock(url) {
            let observedAt = Date().timeIntervalSince1970
            // Validate before decoding legacy spellings or a disconnected state,
            // so malformed settings never appear as saved defaults.
            try Self.validateMobileTelegramConfiguration(at: root)
            let routing = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
            guard let preference = routing.preferences["telegram"] else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
            let status = try await TelegramFacade(dataRoot: root).loadStatus(
                manager: backgroundLoopsManager.coreManager, routingSnapshot: routing
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
