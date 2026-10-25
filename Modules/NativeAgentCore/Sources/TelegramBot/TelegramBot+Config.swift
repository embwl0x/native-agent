import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `TelegramBot+Config.swift` | Saved shape validation, exact positive `voice_max_bytes` and TransportAllowlist's normalized integer IDs. Model/effort fields are legacy routing metadata; voice model metadata does not select recognition. Loads can remove retired credentials and migrate plaintext to Keychain. Conditional saves resolve kept tokens under the config lock and advance revisions, including disconnect |

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
//
// CANONICAL PATH (fix2/F1): `<dataRoot>/telegram/config.json`. The legacy
// `<dataRoot>/config/config.json["telegram"]` block is retired: only its
// plaintext credential fields are removed, never imported or used for routing.
// See docs/canonical_data_paths.md.
// Local backup includes this configuration object; export excludes it. Phone
// sync projects Telegram status/configuration without credentials. PrivacyMap
// lists Telegram as nonexportable.

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
    public static let defaultVoiceTranscriptionBackend = TelegramVoiceTranscriptionBackends.appleSpeech
    public static let defaultVoiceTranscriptionModel = TelegramVoiceTranscriptionBackends.appleSpeechModel
    public static let defaultVoiceMaxBytes = 24 * 1024 * 1024

    public let botToken: String
    public let tokenConfigured: Bool
    public let allowedChatIds: Set<Int64>
    public let allowedUserIds: Set<Int64>
    /// A private chat id is its user's id. Chat-only setups may identify the
    /// owner too, provided there is exactly one private destination.
    public var ownerUserId: Int64? {
        let owners = allowedUserIds.isEmpty ? Set(allowedChatIds.filter { $0 > 0 }) : allowedUserIds
        guard owners.count == 1, let owner = owners.first, owner > 0 else { return nil }
        return owner
    }
    public let requireMention: Bool
    public let enabled: Bool
    /// Legacy routing metadata migrated into ProviderRouting by settings saves; never a turn override.
    public let model: String?
    public let reasoningEffort: String?
    public let voiceTranscriptionEnabled: Bool
    public let voiceTranscriptionBackend: String
    /// Legacy saved metadata; recognition uses Apple Speech and reports `apple-speech`.
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
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes,
        tokenConfigured: Bool? = nil
    ) {
        self.botToken = botToken
        self.tokenConfigured = tokenConfigured ?? !botToken.isEmpty
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

    /// Loads canonical settings, removes retired credentials and migrates plaintext into Keychain.
    /// Returns nil on failure, missing settings or an empty token unless disconnected is included.
    public static func loadFromDisk(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        includeDisconnected: Bool = false
    ) -> TelegramConfig? {
        do {
            return try loadSavedConfiguration(dataRoot: dataRoot, includeDisconnected: includeDisconnected)
        } catch {
            nativeLog("[Telegram] Saved configuration or Keychain credential unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    /// Management callers distinguish missing settings from unavailable grants.
    /// Explicit replacement or disconnect reads validated metadata without
    /// requiring the credential it is replacing; retired credential cleanup still runs.
    public static func loadSavedConfiguration(
        dataRoot: URL,
        includeDisconnected: Bool = true,
        resolveCredential: Bool = true
    ) throws -> TelegramConfig? {
        do {
            try removeRetiredLegacyCredentials(dataRoot: dataRoot)
        } catch {
            // Retired cleanup cannot make canonical settings unavailable.
            NSLog("[Telegram] Retired credential cleanup failed; check legacy settings. Canonical settings will be read independently.")
        }
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        return try CredentialFileLock.withLock(path) {
            try validateSavedConfiguration(dataRoot: dataRoot)
            var info = stat()
            if lstat(path.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw PersistenceCoreError.ioFailure("Saved Telegram settings are unreadable")
            }
            return try parseFlat(path, includeDisconnected: includeDisconnected, resolveCredential: resolveCredential)
        }
    }

    /// Write the per-feature `<dataRoot>/telegram/config.json` form. Used by
    /// the Telegram settings panel so the user can paste a token without editing
    /// disk by hand.
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
            // Resolve a blank draft only after the revision check, while the
            // same lock excludes disconnect and every other config writer.
            let token = keepExistingToken
                ? (try loadSavedConfiguration(dataRoot: dataRoot)?.botToken ?? "") : cfg.botToken
            var payload: [String: Any] = [
                "configuration_revision": UUID().uuidString,
                "allowed_chat_ids": cfg.allowedChatIds.sorted().map { NSNumber(value: $0) },
                "allowed_user_ids": cfg.allowedUserIds.sorted().map { NSNumber(value: $0) },
                "require_mention": cfg.requireMention,
                "enabled": cfg.enabled && !token.isEmpty,
            ]
            if let m = cfg.model, !m.isEmpty { payload["model"] = m }
            if let e = cfg.reasoningEffort, !e.isEmpty { payload["reasoning_effort"] = e }
            payload["voice_transcription_enabled"] = cfg.voiceTranscriptionEnabled
            payload["voice_transcription_backend"] = cfg.voiceTranscriptionBackend
            payload["voice_transcription_model"] = cfg.voiceTranscriptionModel
            payload["voice_max_bytes"] = cfg.voiceMaxBytes
            try writePayload(payload, token: token, to: url)
        }
    }

    // MARK: parsing helpers

    /// Launch loads this even without an active bot. Delete only the retired
    /// credential members and their separators; all other bytes stay verbatim.
    private static func removeRetiredLegacyCredentials(dataRoot: URL) throws {
        let path = dataRoot.appendingPathComponent("config/config.json")
        let failure = PersistenceCoreError.ioFailure("Retired Telegram credential cleanup failed; check legacy settings")
        func isPresent() throws -> Bool {
            var info = stat()
            if lstat(path.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw failure
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw failure }
            return true
        }
        do {
            guard try isPresent() else { return }
            try CredentialFileLock.withLock(path) {
                guard try isPresent() else { return }
                let original = try Data(contentsOf: path)
                guard try JSONSerialization.jsonObject(with: original) is [String: Any],
                      String(data: original, encoding: .utf8) != nil else { throw failure }
                let bytes = Array(original)
                let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
                func skipWhitespace(_ index: inout Int) {
                    while index < bytes.count, whitespace.contains(bytes[index]) { index += 1 }
                }
                func skipString(_ index: inout Int) throws {
                    guard index < bytes.count, bytes[index] == 0x22 else { throw failure }
                    index += 1
                    while index < bytes.count {
                        let byte = bytes[index]
                        index += 1
                        if byte == 0x22 { return }
                        if byte == 0x5C { index += 1 }
                    }
                    throw failure
                }
                // JSON validity is checked above; this scan only locates byte
                // ranges, including escaped keys and nested unrelated values.
                func members(at start: Int) throws -> [(key: String, start: Int, value: Int, end: Int, comma: Int?)] {
                    guard start < bytes.count, bytes[start] == 0x7B else { throw failure }
                    var result: [(key: String, start: Int, value: Int, end: Int, comma: Int?)] = []
                    var index = start + 1
                    skipWhitespace(&index)
                    while index < bytes.count, bytes[index] != 0x7D {
                        let keyStart = index
                        try skipString(&index)
                        guard let key = try JSONSerialization.jsonObject(
                            with: Data(bytes[keyStart..<index]), options: [.fragmentsAllowed]
                        ) as? String else { throw failure }
                        skipWhitespace(&index)
                        guard index < bytes.count, bytes[index] == 0x3A else { throw failure }
                        index += 1
                        skipWhitespace(&index)
                        let valueStart = index
                        var depth = 0
                        while index < bytes.count {
                            let byte = bytes[index]
                            if byte == 0x22 { try skipString(&index); continue }
                            if depth == 0, byte == 0x2C || byte == 0x7D { break }
                            if byte == 0x7B || byte == 0x5B { depth += 1 }
                            if byte == 0x7D || byte == 0x5D { depth -= 1 }
                            index += 1
                        }
                        guard index < bytes.count else { throw failure }
                        var valueEnd = index
                        while valueEnd > valueStart, whitespace.contains(bytes[valueEnd - 1]) { valueEnd -= 1 }
                        let comma = bytes[index] == 0x2C ? index : nil
                        result.append((key, keyStart, valueStart, valueEnd, comma))
                        if comma == nil { break }
                        index += 1
                        skipWhitespace(&index)
                    }
                    return result
                }
                var root = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
                skipWhitespace(&root)
                var removals: [Range<Int>] = []
                for block in try members(at: root) where block.key == "telegram" {
                    guard bytes[block.value] == 0x7B else { continue }
                    let fields = try members(at: block.value)
                    var index = 0
                    while index < fields.count {
                        guard fields[index].key == "token" || fields[index].key == "bot_token" else {
                            index += 1
                            continue
                        }
                        let first = index
                        repeat { index += 1 } while index < fields.count
                            && (fields[index].key == "token" || fields[index].key == "bot_token")
                        let last = index - 1
                        if let comma = fields[last].comma {
                            removals.append(fields[first].start..<(comma + 1))
                        } else if first > 0, let comma = fields[first - 1].comma {
                            removals.append(comma..<fields[last].end)
                        } else {
                            removals.append(fields[first].start..<fields[last].end)
                        }
                    }
                }
                guard !removals.isEmpty else { return }
                var cleaned = original
                for range in removals.reversed() { cleaned.removeSubrange(range) }
                guard try JSONSerialization.jsonObject(with: cleaned) is [String: Any],
                      try Data(contentsOf: path) == original else { throw failure }
                try SwiftNativePersistenceCore.writeDataAtomicDurable(cleaned, to: path)
                guard try Data(contentsOf: path) == cleaned else { throw failure }
            }
        } catch {
            // Never expose a parser diagnostic that could include the token.
            throw failure
        }
    }

    /// Missing settings may bootstrap; present legacy aliases must retain
    /// their documented scalar types before any reader defaults or writer runs.
    public static func validateSavedConfiguration(dataRoot: URL) throws {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        var info = stat()
        if lstat(path.path, &info) != 0 {
            if errno == ENOENT { return }
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
        for field in ["configuration_revision", "bot_token", "token", "model", "reasoning_effort", "reasoningEffort",
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
        _ = try TransportAllowlist.telegram(fields: fields)
        for field in ["voice_max_bytes", "voice_max_mb"] {
            guard let value = fields[field] else { continue }
            if field == "voice_max_bytes" {
                switch value {
                case .int(let bytes) where bytes > 0: continue
                case .double(let bytes) where Int(exactly: bytes).map({ $0 > 0 }) == true: continue
                case .string(let bytes) where Int(bytes).map({ $0 > 0 }) == true: continue
                default: throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a positive size")
                }
            }
            let number: Double?
            switch value {
            case .int(let value): number = Double(value)
            case .double(let value): number = value
            case .string(let value): number = Double(value)
            default: number = nil
            }
            guard let number, number.isFinite, number > 0,
                  Int(exactly: (number * 1_048_576).rounded(.towardZero)).map({ $0 > 0 }) == true else {
                throw PersistenceCoreError.ioFailure("Saved Telegram field \(field) must be a positive size")
            }
        }
    }

    private static func parseFlat(_ url: URL, includeDisconnected: Bool, resolveCredential: Bool) throws -> TelegramConfig? {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let token: String
        if obj["bot_token"] != nil || obj["token"] != nil {
            token = (obj["bot_token"] as? String) ?? (obj["token"] as? String) ?? ""
            if resolveCredential { try writePayload(obj, token: token, to: url) }
        } else if resolveCredential, let reference = obj[tokenReferenceField] as? String {
            guard let bytes = try DeviceSecretKeychain.read(service: tokenService, account: reference),
                  let saved = String(data: bytes, encoding: .utf8), !saved.isEmpty else {
                throw DeviceSecretKeychain.Failure.unavailable
            }
            token = saved
        } else { token = "" }
        // Transport callers require a token; settings readback may explicitly
        // include the disconnected state. In either case,
        // enabled=false MUST round-trip — return the config with enabled=false
        // so the UI's saved-disabled toggle survives a restart.
        if token.isEmpty && !includeDisconnected { return nil }
        let enabled = (obj["enabled"] as? Bool) ?? true
        let allowed = try TransportAllowlist.telegram(fields: obj.mapValues { JSONValue(fromFoundation: $0) })
        let requireMention = (obj["require_mention"] as? Bool) ?? false
        let model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = (obj["reasoning_effort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (obj["reasoningEffort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = parseVoiceOptions(obj)
        return TelegramConfig(
            botToken: token,
            allowedChatIds: Set(allowed.chatIds.compactMap(Int64.init)),
            allowedUserIds: Set(allowed.userIds.compactMap(Int64.init)),
            requireMention: requireMention,
            enabled: enabled,
            model: (model?.isEmpty == false) ? model : nil,
            reasoningEffort: (effort?.isEmpty == false) ? effort : nil,
            voiceTranscriptionEnabled: voice.enabled,
            voiceTranscriptionBackend: voice.backend,
            voiceTranscriptionModel: voice.model,
            voiceMaxBytes: voice.maxBytes,
            tokenConfigured: !token.isEmpty || obj[tokenReferenceField] != nil
        )
    }

    private static func writePayload(_ object: [String: Any], token: String, to url: URL) throws {
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let previousObject = previous.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let oldReference = previousObject?[tokenReferenceField] as? String
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
        payload[tokenReferenceField] = reference
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
            guard try Data(contentsOf: url) == data else { throw DeviceSecretKeychain.Failure.unavailable }
        } catch {
            if let previous { try SwiftNativePersistenceCore.writeDataAtomicDurable(previous, to: url) }
            else {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try SwiftNativePersistenceCore.syncDirectory(url.deletingLastPathComponent())
            }
            if let reference, !reuseReference { try? DeviceSecretKeychain.delete(service: tokenService, account: reference) }
            throw error
        }
        if let oldReference, oldReference != reference {
            do { try DeviceSecretKeychain.delete(service: tokenService, account: oldReference) }
            catch { nativeLog("[Telegram] Settings saved; previous Keychain item cleanup failed: %@", error.localizedDescription) }
        }
    }

    /// Carry a readable current grant (including disconnect); return the source
    /// failure for the restore receipt, while installation write failures throw.
    public static func preserveCredential(safetyRoot: URL, destinationRoot: URL) throws -> String? {
        let source = safetyRoot.appendingPathComponent("telegram/config.json")
        let destination = destinationRoot.appendingPathComponent("telegram/config.json")
        return try CredentialFileLock.withLock(destination) {
            let current: [String: Any]?
            do {
                try validateSavedConfiguration(dataRoot: safetyRoot)
                current = FileManager.default.fileExists(atPath: source.path)
                    ? try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any] : nil
                if let reference = current?[tokenReferenceField] as? String {
                    guard let bytes = try DeviceSecretKeychain.read(service: tokenService, account: reference),
                          let token = String(data: bytes, encoding: .utf8), !token.isEmpty else {
                        throw DeviceSecretKeychain.Failure.unavailable
                    }
                }
            } catch { return error.localizedDescription }
            try validateSavedConfiguration(dataRoot: destinationRoot)
            let restored = FileManager.default.fileExists(atPath: destination.path)
                ? try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any] : current
            guard var payload = restored else { return nil }
            payload.removeValue(forKey: "bot_token")
            payload.removeValue(forKey: "token")
            payload[tokenReferenceField] = current?[tokenReferenceField]
            if !(current?[tokenReferenceField] is String),
               let token = (current?["bot_token"] as? String) ?? (current?["token"] as? String), !token.isEmpty {
                // Legacy safety snapshots keep their bytes; migrate only the destination.
                try writePayload(payload, token: token, to: destination)
                _ = try parseFlat(destination, includeDisconnected: true, resolveCredential: false)
                return nil
            }
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: destination)
            guard try Data(contentsOf: destination) == bytes else { throw DeviceSecretKeychain.Failure.unavailable }
            _ = try parseFlat(destination, includeDisconnected: true, resolveCredential: false)
            return nil
        }
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
