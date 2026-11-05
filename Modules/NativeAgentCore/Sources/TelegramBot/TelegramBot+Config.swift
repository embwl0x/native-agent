import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import TrustCenter
import NativeAgentShared
// Blueprint: | `TelegramBot+Config.swift` | `voice_max_bytes`, `ownerUserId`, `readConfigurationStatus`: locked grants and revisions |

/// Credential-free configuration for management surfaces. Runtime configuration remains authoritative; a surface may supply its resolved routing selection.
public struct TelegramConfigurationSummary: Sendable, Equatable {
    public let tokenConfigured: Bool
    public let allowedChatIds: [String]
    public let allowedUserIds: [String]
    public let requireMention: Bool
    public let enabled: Bool
    public let model: String?
    public let reasoningEffort: String?

    public init(config: TelegramConfig?, model: String?, reasoningEffort: String?) {
        tokenConfigured = config?.tokenConfigured ?? false
        allowedChatIds = config?.allowedChatIds.sorted().map(String.init) ?? []
        allowedUserIds = config?.allowedUserIds.sorted().map(String.init) ?? []
        requireMention = config?.requireMention ?? false
        enabled = config?.enabled ?? false
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: - TelegramConfig
// Back up configuration locally, exclude it from export, and sync no credentials to the phone (PrivacyMap: telegram).

public struct TelegramConfig: Sendable, Equatable {
    public struct SavedRevision: Sendable, Equatable {
        fileprivate let bytes: Data?
    }

    public static func savedRevision(dataRoot: URL) throws -> SavedRevision {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        return try CredentialFileLock.withLock(path) {
            do { return SavedRevision(bytes: try Data(contentsOf: path)) }
            catch CocoaError.fileReadNoSuchFile { return SavedRevision(bytes: nil) }
        }
    }

    private static let tokenReferenceField = "bot_token_keychain_ref"
    private static let tokenService = "NativeAgent.telegram-bot"
    public static let defaultVoiceTranscriptionEnabled = true
    public static let defaultVoiceMaxBytes = 24 * 1024 * 1024

    public let botToken: String
    public let tokenConfigured: Bool
    public let allowedChatIds: Set<Int64>
    public let allowedUserIds: Set<Int64>
    /// A private chat id is its user's id. Chat-only setups may identify the owner too, provided there is exactly one private destination.
    public var ownerUserId: Int64? {
        let owners = allowedUserIds.isEmpty ? Set(allowedChatIds.filter { $0 > 0 }) : allowedUserIds
        guard owners.count == 1, let owner = owners.first, owner > 0 else { return nil }
        return owner
    }
    public let requireMention: Bool
    public let enabled: Bool
    public let voiceTranscriptionEnabled: Bool
    public let voiceMaxBytes: Int

    public init(
        botToken: String,
        allowedChatIds: Set<Int64>,
        allowedUserIds: Set<Int64> = [],
        requireMention: Bool = false,
        enabled: Bool,
        voiceTranscriptionEnabled: Bool = TelegramConfig.defaultVoiceTranscriptionEnabled,
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes,
        tokenConfigured: Bool? = nil
    ) {
        self.botToken = botToken
        self.tokenConfigured = tokenConfigured ?? !botToken.isEmpty
        self.allowedChatIds = allowedChatIds
        self.allowedUserIds = allowedUserIds
        self.requireMention = requireMention
        self.enabled = enabled
        self.voiceTranscriptionEnabled = voiceTranscriptionEnabled
        self.voiceMaxBytes = max(1, voiceMaxBytes)
    }

    /// One locked read separates metadata from credential failure; a bad grant must not trigger another config read.
    public static func readConfigurationStatus(dataRoot: URL) ->
        (configuration: Result<TelegramConfig?, Error>, credentialError: Error?) {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        do {
            return try CredentialFileLock.withLock(path) {
                guard let fields = try validateSavedConfiguration(dataRoot: dataRoot) else { return (.success(nil), nil) }
                let metadata = try parseFlat(fields, at: path, includeDisconnected: true, resolveCredential: false)
                do {
                    let resolved = try parseFlat(fields, at: path, includeDisconnected: true, resolveCredential: true)
                    return (.success(resolved), nil)
                } catch { return (.success(metadata), error) }
            }
        } catch { return (.failure(error), nil) }
    }

    /// Replacement and disconnect need validated metadata even when the selected credential is unavailable.
    public static func loadSavedConfiguration(
        dataRoot: URL,
        includeDisconnected: Bool = true,
        resolveCredential: Bool = true
    ) throws -> TelegramConfig? {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        return try CredentialFileLock.withLock(path) {
            guard let fields = try validateSavedConfiguration(dataRoot: dataRoot) else { return nil }
            return try parseFlat(fields, at: path, includeDisconnected: includeDisconnected, resolveCredential: resolveCredential)
        }
    }

    public static func saveToDisk(
        _ cfg: TelegramConfig,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        expectedRevision: SavedRevision? = nil,
        keepExistingToken: Bool = false
    ) throws {
        let dir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try CredentialFileLock.withLock(url) {
            try validateSavedConfiguration(dataRoot: dataRoot)
            if let expectedRevision, try savedRevision(dataRoot: dataRoot) != expectedRevision {
                throw PersistenceCoreError.ioFailure("Telegram settings changed while saving. The token was not saved.")
            }
            // Resolve a blank draft only after the revision check, while the same lock excludes disconnect and every other config writer.
            let token = keepExistingToken
                ? (try loadSavedConfiguration(dataRoot: dataRoot)?.botToken ?? "") : cfg.botToken
            var payload: [String: JSONValue] = [
                "configuration_revision": .string(UUID().uuidString),
                "allowed_chat_ids": .array(cfg.allowedChatIds.sorted().map(JSONValue.int)),
                "allowed_user_ids": .array(cfg.allowedUserIds.sorted().map(JSONValue.int)),
                "require_mention": .bool(cfg.requireMention),
                "enabled": .bool(cfg.enabled && !token.isEmpty),
            ]
            payload["voice_transcription_enabled"] = .bool(cfg.voiceTranscriptionEnabled)
            payload["voice_max_bytes"] = .int(Int64(cfg.voiceMaxBytes))
            try writePayload(payload, token: token, to: url)
        }
    }

    // MARK: parsing helpers

    /// Missing settings may bootstrap; present settings retain their declared types.
    @discardableResult
    public static func validateSavedConfiguration(dataRoot: URL) throws -> [String: JSONValue]? {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        return try CredentialFileLock.withLock(path) {
            var info = stat()
            if lstat(path.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw PersistenceCoreError.ioFailure("Saved Telegram settings are unreadable")
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw PersistenceCoreError.ioFailure("Saved Telegram settings must be a regular file")
            }
            guard case .object(let fields) = try JSONValue.parse(Data(contentsOf: path)) else {
                throw PersistenceCoreError.ioFailure("Saved Telegram settings must be a JSON object")
            }
            if let value = fields[tokenReferenceField] {
                guard case .string(let reference) = value, UUID(uuidString: reference) != nil else {
                    throw PersistenceCoreError.ioFailure("Saved Telegram Keychain reference must be a UUID string")
                }
            }
            guard fields["enabled"] == .bool(false) || fields[tokenReferenceField] != nil else {
                throw PersistenceCoreError.ioFailure("""
                    Enabled Telegram settings have no Keychain credential reference. Save the bot token again in Connectors → Telegram; \
                    existing settings were preserved.
                    """)
            }
            for field in ["configuration_revision"] {
                guard let value = fields[field] else { continue }
                guard case .string = value else {
                    throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a string")
                }
            }
            for field in ["enabled", "require_mention", "voice_transcription_enabled"] {
                guard let value = fields[field] else { continue }
                guard case .bool = value else {
                    throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a boolean")
                }
            }
            _ = try TransportAllowlist.telegram(fields: fields)
            if let value = fields["voice_max_bytes"] {
                guard case .int(let bytes) = value, bytes > 0, Int(exactly: bytes) != nil else {
                    throw PersistenceCoreError.ioFailure("Saved Telegram field voice_max_bytes must be a positive integer byte count")
                }
            }
            return fields
        }
    }

    private static func parseFlat(_ obj: [String: JSONValue], at url: URL, includeDisconnected: Bool, resolveCredential: Bool) throws -> TelegramConfig? {
        let token: String
        if resolveCredential, let reference = obj[tokenReferenceField]?.stringValue {
            guard let bytes = try DeviceSecretKeychain.read(service: tokenService, account: reference),
                  let saved = String(data: bytes, encoding: .utf8), !saved.isEmpty else {
                throw DeviceSecretKeychain.Failure.unavailable
            }
            token = saved
        } else { token = "" }
        // Preserve enabled=false on readback so the saved disabled toggle survives a restart.
        if token.isEmpty && !includeDisconnected { return nil }
        let enabled = obj["enabled"] != .bool(false)
        let allowed = try TransportAllowlist.telegram(fields: obj)
        let requireMention = obj["require_mention"] == .bool(true)
        let voice = parseVoiceOptions(obj)
        return TelegramConfig(
            botToken: token,
            allowedChatIds: Set(allowed.chatIds.compactMap(Int64.init)),
            allowedUserIds: Set(allowed.userIds.compactMap(Int64.init)),
            requireMention: requireMention,
            enabled: enabled,
            voiceTranscriptionEnabled: voice.enabled,
            voiceMaxBytes: voice.maxBytes,
            tokenConfigured: !token.isEmpty || obj[tokenReferenceField] != nil
        )
    }

    private static func writePayload(_ object: [String: JSONValue], token: String, to url: URL) throws {
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let previousObject = try previous.map { try JSONValue.parse($0) }
        let oldReference = previousObject?.objectValue?[tokenReferenceField]?.stringValue
        let reuseReference = oldReference.map {
            (try? DeviceSecretKeychain.read(service: tokenService, account: $0)) == Data(token.utf8)
        } ?? false
        let reference = token.isEmpty ? nil : (reuseReference ? oldReference : UUID().uuidString)
        if let reference, !reuseReference {
            try DeviceSecretKeychain.insert(Data(token.utf8), service: tokenService, account: reference)
        }
        var payload = object
        payload.removeValue(forKey: "bot_token")
        payload.removeValue(forKey: "token")
        payload[tokenReferenceField] = reference.map(JSONValue.string)
        do {
            let data = try JSONValue.object(payload).serializedData(pretty: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
            guard try Data(contentsOf: url) == data else { throw DeviceSecretKeychain.Failure.unavailable }
        } catch {
            // Publication may have committed: retain both grants until readback identifies the selected reference; never restore uncertain bytes.
            throw PersistenceCoreError.ioFailure("""
                Telegram settings publication could not be confirmed at \(url.path): \(error.localizedDescription). Read that file \
                and its selected Keychain reference before saving again; the credentials were retained.
                """)
        }
        if let oldReference, oldReference != reference {
            do { try DeviceSecretKeychain.delete(service: tokenService, account: oldReference) }
            catch { nativeLog("[Telegram] Settings saved; previous Keychain item cleanup failed: %@", error.localizedDescription) }
        }
    }

    /// Carry a readable current grant (including disconnect); return the source failure for the restore receipt, while installation write failures throw.
    public static func preserveCredential(safetyRoot: URL, destinationRoot: URL) throws -> String? {
        let destination = destinationRoot.appendingPathComponent("telegram/config.json")
        return try CredentialFileLock.withLock(destination) {
            let current: [String: JSONValue]?
            do {
                current = try validateSavedConfiguration(dataRoot: safetyRoot)
                if let reference = current?[tokenReferenceField]?.stringValue {
                    guard let bytes = try DeviceSecretKeychain.read(service: tokenService, account: reference),
                          let token = String(data: bytes, encoding: .utf8), !token.isEmpty else {
                        throw DeviceSecretKeychain.Failure.unavailable
                    }
                }
            } catch { return error.localizedDescription }
            let restored = try validateSavedConfiguration(dataRoot: destinationRoot) ?? current
            guard var payload = restored else { return nil }
            payload.removeValue(forKey: "bot_token")
            payload.removeValue(forKey: "token")
            payload[tokenReferenceField] = current?[tokenReferenceField]
            let bytes = try JSONValue.object(payload).serializedData(pretty: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: destination)
            guard try Data(contentsOf: destination) == bytes else { throw DeviceSecretKeychain.Failure.unavailable }
            _ = try loadSavedConfiguration(dataRoot: destinationRoot, resolveCredential: false)
            return nil
        }
    }

    private static func parseVoiceOptions(_ obj: [String: JSONValue]) -> (enabled: Bool, maxBytes: Int) {
        let enabled = obj["voice_transcription_enabled"] != .bool(false)
        let bytes = obj["voice_max_bytes"]?.integerValue.flatMap(Int.init(exactly:))
        return (enabled, bytes ?? defaultVoiceMaxBytes)
    }
}
