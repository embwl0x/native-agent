import Foundation
import NativeAgentCore
import PersistenceCore

/// Credential-free configuration for management surfaces. Runtime configuration
/// remains authoritative; a surface may supply its resolved routing selection.
public struct TelegramConfigurationSummary: Sendable, Equatable {
    public let tokenConfigured: Bool
    public let allowedChatIds: [String]
    public let allowedUserIds: [String]
    public let requireMention: Bool
    public let enabled: Bool
    public let model: String?
    public let reasoningEffort: String?

    public init(config: TelegramConfig?, model: String?, reasoningEffort: String?) {
        tokenConfigured = config?.botToken.isEmpty == false
        allowedChatIds = config?.allowedChatIds.sorted().map(String.init) ?? []
        allowedUserIds = config?.allowedUserIds.sorted().map(String.init) ?? []
        requireMention = config?.requireMention ?? false
        enabled = config?.enabled ?? false
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: - TelegramConfig
//
// CANONICAL PATH (fix2/F1): `<dataRoot>/telegram/config.json`. The legacy
// `<dataRoot>/config/config.json["telegram"]` block is dead and is never read
// at runtime. See docs/canonical_data_paths.md.

public struct TelegramConfig: Sendable, Equatable {
    public static let defaultVoiceTranscriptionEnabled = true
    public static let defaultVoiceTranscriptionBackend = TelegramVoiceTranscriptionBackends.appleSpeech
    public static let defaultVoiceTranscriptionModel = TelegramVoiceTranscriptionBackends.appleSpeechModel
    public static let defaultVoiceMaxBytes = 24 * 1024 * 1024

    public let botToken: String
    public let allowedChatIds: Set<Int64>
    public let allowedUserIds: Set<Int64>
    public let requireMention: Bool
    public let enabled: Bool
    /// Optional per-bot model override. When set, the chat-orchestration path
    /// passes this model directly instead of resolving the telegram surface
    /// via the picker. Empty → use surface picker.
    public let model: String?
    public let reasoningEffort: String?
    public let voiceTranscriptionEnabled: Bool
    public let voiceTranscriptionBackend: String
    public let voiceTranscriptionModel: String
    public let voiceMaxBytes: Int

    public init(
        botToken: String,
        allowedChatIds: Set<Int64>,
        allowedUserIds: Set<Int64> = [],
        requireMention: Bool = false,
        enabled: Bool,
        model: String? = nil,
        reasoningEffort: String? = nil,
        voiceTranscriptionEnabled: Bool = TelegramConfig.defaultVoiceTranscriptionEnabled,
        voiceTranscriptionBackend: String = TelegramConfig.defaultVoiceTranscriptionBackend,
        voiceTranscriptionModel: String = TelegramConfig.defaultVoiceTranscriptionModel,
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes
    ) {
        self.botToken = botToken
        self.allowedChatIds = allowedChatIds
        self.allowedUserIds = allowedUserIds
        self.requireMention = requireMention
        self.enabled = enabled
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.voiceTranscriptionEnabled = voiceTranscriptionEnabled
        let canonicalVoiceBackend = TelegramVoiceTranscriptionBackends.canonical(voiceTranscriptionBackend)
        let trimmedVoiceModel = voiceTranscriptionModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceTranscriptionBackend = canonicalVoiceBackend
        self.voiceTranscriptionModel = trimmedVoiceModel.isEmpty
            ? TelegramVoiceTranscriptionBackends.appleSpeechModel
            : trimmedVoiceModel
        self.voiceMaxBytes = max(1, voiceMaxBytes)
    }

    /// Read the on-disk Telegram config only from the canonical Swift-native
    /// location: `<dataRoot>/telegram/config.json`. Returns nil when no config
    /// exists or the token is empty.
    public static func loadFromDisk(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        includeDisconnected: Bool = false
    ) -> TelegramConfig? {
        do { try validateSavedConfiguration(dataRoot: dataRoot) }
        catch { return nil }
        let dir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        let perFeature = dir.appendingPathComponent("config.json")
        // 2026-07-21 audit: one-time permission heal for configs written
        // before saveToDisk locked the bot-token file down (0600 file /
        // 0700 dir, matching the X OAuth token store).
        if FileManager.default.fileExists(atPath: perFeature.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: perFeature.path)
        }
        return parseFlat(perFeature, includeDisconnected: includeDisconnected)
    }

    /// Write the per-feature `<dataRoot>/telegram/config.json` form. Used by
    /// the Telegram settings panel so the user can paste a token without editing
    /// disk by hand.
    public static func saveToDisk(
        _ cfg: TelegramConfig,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws {
        try validateSavedConfiguration(dataRoot: dataRoot)
        let dir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 2026-07-21 audit: this file carries the bot token — lock it down
        // like the X OAuth token store (0700 dir / 0600 file).
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("config.json")
        var payload: [String: Any] = [
            "bot_token": cfg.botToken,
            "allowed_chat_ids": cfg.allowedChatIds.sorted().map { NSNumber(value: $0) },
            "allowed_user_ids": cfg.allowedUserIds.sorted().map { NSNumber(value: $0) },
            "require_mention": cfg.requireMention,
            "enabled": cfg.enabled,
        ]
        if let m = cfg.model, !m.isEmpty { payload["model"] = m }
        if let e = cfg.reasoningEffort, !e.isEmpty { payload["reasoning_effort"] = e }
        payload["voice_transcription_enabled"] = cfg.voiceTranscriptionEnabled
        payload["voice_transcription_backend"] = cfg.voiceTranscriptionBackend
        payload["voice_transcription_model"] = cfg.voiceTranscriptionModel
        payload["voice_max_bytes"] = cfg.voiceMaxBytes
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: parsing helpers

    /// Missing settings may bootstrap; present legacy aliases must retain
    /// their documented scalar types before any reader defaults or writer runs.
    public static func validateSavedConfiguration(dataRoot: URL) throws {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
        guard case .object(let fields) = try JSONValue.parse(Data(contentsOf: path)) else {
            throw PersistenceCoreError.ioFailure("Saved Telegram settings must be a JSON object")
        }
        for field in ["bot_token", "token", "model", "reasoning_effort", "reasoningEffort",
                      "voice_transcription_backend", "voice_backend", "voice_transcription_model", "voice_model"] {
            guard let value = fields[field] else { continue }
            guard case .string = value else {
                throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a string")
            }
        }
        for field in ["enabled", "require_mention", "voice_transcription_enabled", "voice_enabled"] {
            guard let value = fields[field] else { continue }
            guard case .bool = value else {
                throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a boolean")
            }
        }
        for field in ["allowed_chat_ids", "allowed_user_ids"] {
            guard let value = fields[field] else { continue }
            guard case .array(let ids) = value, ids.allSatisfy({ value in
                switch value {
                case .int: return true
                case .string(let raw): return Int64(raw) != nil
                default: return false
                }
            }) else {
                throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must contain integer IDs")
            }
        }
        for field in ["voice_max_bytes", "voice_max_mb"] {
            guard let value = fields[field] else { continue }
            let number: Double?
            switch value {
            case .int(let value): number = Double(value)
            case .double(let value): number = value
            case .string(let value): number = Double(value)
            default: number = nil
            }
            guard let number, number.isFinite, number > 0,
                  Int(exactly: (number * (field == "voice_max_mb" ? 1_048_576 : 1)).rounded(.towardZero)) != nil else {
                throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a positive size")
            }
        }
    }

    private static func parseFlat(_ url: URL, includeDisconnected: Bool) -> TelegramConfig? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let token = (obj["bot_token"] as? String) ?? (obj["token"] as? String) ?? ""
        // Transport callers require a token; settings readback may explicitly
        // include the disconnected state. In either case,
        // enabled=false MUST round-trip — return the config with enabled=false
        // so the UI's saved-disabled toggle survives a restart.
        if token.isEmpty && !includeDisconnected { return nil }
        let enabled = (obj["enabled"] as? Bool) ?? true
        let chatIds = extractChatIds(obj["allowed_chat_ids"])
        let userIds = extractChatIds(obj["allowed_user_ids"])
        let requireMention = (obj["require_mention"] as? Bool) ?? false
        let model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = (obj["reasoning_effort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (obj["reasoningEffort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = parseVoiceOptions(obj)
        return TelegramConfig(
            botToken: token,
            allowedChatIds: chatIds,
            allowedUserIds: userIds,
            requireMention: requireMention,
            enabled: enabled,
            model: (model?.isEmpty == false) ? model : nil,
            reasoningEffort: (effort?.isEmpty == false) ? effort : nil,
            voiceTranscriptionEnabled: voice.enabled,
            voiceTranscriptionBackend: voice.backend,
            voiceTranscriptionModel: voice.model,
            voiceMaxBytes: voice.maxBytes
        )
    }

    private static func extractChatIds(_ raw: Any?) -> Set<Int64> {
        guard let arr = raw as? [Any] else { return [] }
        var out: Set<Int64> = []
        for v in arr {
            if let n = v as? NSNumber { out.insert(n.int64Value); continue }
            if let s = v as? String, let n = Int64(s) { out.insert(n) }
        }
        return out
    }

    private static func parseVoiceOptions(_ obj: [String: Any]) -> (
        enabled: Bool,
        backend: String,
        model: String,
        maxBytes: Int
    ) {
        let enabled = (obj["voice_transcription_enabled"] as? Bool)
            ?? (obj["voice_enabled"] as? Bool)
            ?? defaultVoiceTranscriptionEnabled
        let backendRaw = (obj["voice_transcription_backend"] as? String)
            ?? (obj["voice_backend"] as? String)
            ?? defaultVoiceTranscriptionBackend
        let backend = TelegramVoiceTranscriptionBackends.canonical(backendRaw)
        let modelRaw = (obj["voice_transcription_model"] as? String)
            ?? (obj["voice_model"] as? String)
            ?? defaultVoiceTranscriptionModel
        let model = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxBytes: Int = {
            if let n = obj["voice_max_bytes"] as? NSNumber {
                return max(1, n.intValue)
            }
            if let n = obj["voice_max_mb"] as? NSNumber {
                return Int(exactly: (n.doubleValue * 1024.0 * 1024.0).rounded(.towardZero)).map { max(1, $0) } ?? defaultVoiceMaxBytes
            }
            if let s = obj["voice_max_bytes"] as? String, let n = Int(s) {
                return max(1, n)
            }
            if let s = obj["voice_max_mb"] as? String, let mb = Double(s) {
                return Int(exactly: (mb * 1024.0 * 1024.0).rounded(.towardZero)).map { max(1, $0) } ?? defaultVoiceMaxBytes
            }
            return defaultVoiceMaxBytes
        }()
        return (
            enabled: enabled,
            backend: backend.isEmpty ? defaultVoiceTranscriptionBackend : backend,
            // Apple Speech is the only backend now; a saved OpenAI model name is stale.
            model: TelegramVoiceTranscriptionBackends.appleSpeechModel,
            maxBytes: maxBytes
        )
    }
}
