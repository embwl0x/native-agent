import CryptoKit
import Foundation
import PersistenceCore
import Security
// Blueprint: | `SlackCredentials.swift` | Slack tokens/grants in Keychain; canonical connectors/slack/auth.json validation, save/recovery, toggle and revoke; metadata import and token migration share registry → canonical locks and PersistenceCore's connectionDecision field. Connected or undecided may migrate; only a recorded person-disconnect retires oauth_tokens/slack.json without importing metadata or tokens, until explicit reconnect. Seeds, first reads and migrations are undecided; enabled/authState never record a choice. Eligible absent canonical auth imports checked legacy metadata with verified publication before source removal; runtime policy reads canonical metadata only. File tokens migrate through verified Keychain writes, canonical fields winning over legacy input; a committed grant stays authoritative. Retained connectors/slack/oauth_app.json has no reader; coverage decisions live here |

/// Slack's tokens live in this Mac's Keychain (secrets → Keychain), one pair
/// per data root. `connectors/slack/auth.json` owns metadata and the grant
/// reference: team, allowlists, socket-mode switches. Local backup includes
/// that file through connectors; export excludes it; phone sync carries status
/// only; PrivacyMap lists it under connectors. The checked registry decides
/// whether metadata/token migration is allowed, using only connectionDecision:
/// connected or undecided qualify; only a recorded person-disconnect retires
/// legacy files without import, until an explicit reconnect. Seeds, first reads
/// and migrations are undecided; enabled/authState never record a choice. When canonical
/// auth is absent, this owner imports checked `oauth_tokens/slack.json` once,
/// verifies publication, then removes the imported source. Unimported legacy
/// files are excluded from local backup/export/sync and remain in the OAuth
/// Tokens inventory. Before credential reads, file-backed bot/app tokens move
/// to Keychain with verified writes before plaintext removal; canonical tokens
/// win over the legacy import source, and a committed grant remains authority.
/// Disconnect also removes that source. Retained connectors/slack/oauth_app.json has no
/// reader; the connectors backup/privacy scope still carries it, not export/sync.
public enum SlackCredentials {
    public enum Token: String, Sendable, CaseIterable { case bot, app }
    private static let service = "com.nativeagent.connector.slack.v1"
    public static let referenceField = "credential_keychain_ref"
    public static let generationField = "credential_generation"
    /// File-backed token aliases, by kind.
    public static let fileKeys: [Token: [String]] = [
        .bot: ["access_token", "oauth_token", "token", "bot_token"],
        .app: ["socket_mode_app_token", "app_token", "slack_app_token"],
    ]

    /// "<data-root hash>:bot": two data roots on one Mac never share a token.
    static func account(_ token: Token, dataRoot: URL) -> String {
        let path = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ":" + token.rawValue
    }

    private static func query(_ token: Token, dataRoot: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(token, dataRoot: dataRoot),
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    /// Only an explicit bot-token replacement may omit a missing prior app grant.
    public static func read(_ token: Token, dataRoot: URL, allowMissingGrant: Bool = false) throws -> String? {
        try CredentialFileLock.withLock(ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)) {
            try CredentialFileLock.withLock(TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)) {
                guard !FileManager.default.fileExists(atPath: saveIntent(dataRoot: dataRoot).path) else { throw Failure.unavailable }
                try migrateFileTokens(dataRoot: dataRoot)
                if let reference = try committedReference(dataRoot: dataRoot) {
                    return try grant(reference, dataRoot: dataRoot, allowMissing: allowMissingGrant && token == .app)[token.rawValue]
                }
                return try readLegacy(token, dataRoot: dataRoot)
            }
        }
    }

    /// One metadata/token snapshot, using the same lock order as save and revoke.
    public static func withSnapshot<T>(dataRoot: URL, _ body: () throws -> T) throws -> T {
        let authPath = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        return try CredentialFileLock.withLock(ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)) {
            try CredentialFileLock.withLock(authPath) {
                // A save a crash left half-done is finished first (same locks, reentrant).
                try recoverPendingSave(dataRoot: dataRoot)
                try migrateFileTokens(dataRoot: dataRoot)
                return try body()
            }
        }
    }

    private static func readLegacy(_ token: Token, dataRoot: URL) throws -> String? {
        var request = query(token, dataRoot: dataRoot)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure.unavailable }
        return value
    }

    /// Replaces the saved token (nil removes it), and reads it back before saying so.
    public static func write(_ value: String?, _ token: Token, dataRoot: URL) throws {
        guard let value else {
            let status = SecItemDelete(query(token, dataRoot: dataRoot) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(token, dataRoot: dataRoot) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(token, dataRoot: dataRoot).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess, try readLegacy(token, dataRoot: dataRoot) == value else { throw Failure.unavailable }
    }

    /// Disconnecting Slack removes both tokens and every grant for this root,
    /// including references retained by older backups or interrupted saves.
    public static func delete(dataRoot: URL) throws {
        try CredentialFileLock.withLock(TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)) {
            guard !FileManager.default.fileExists(atPath: saveIntent(dataRoot: dataRoot).path) else { throw Failure.unavailable }
            for token in Token.allCases { try write(nil, token, dataRoot: dataRoot) }
            var request = query(.bot, dataRoot: dataRoot)
            request[kSecAttrAccount as String] = nil
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw Failure.unavailable }
            let prefix = grantAccount("", dataRoot: dataRoot)
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { throw Failure.unavailable }
                if account.hasPrefix(prefix) {
                    try DeviceSecretKeychain.delete(service: service, account: account)
                }
            }
        }
    }

    /// Caller holds registry then canonical auth's lock. File fields are migration input,
    /// never a runtime credential source; all selected writes verify first.
    private static func migrateFileTokens(dataRoot: URL) throws {
        guard try permitsFileMigration(dataRoot: dataRoot) else { return }
        var object = try metadata(dataRoot: dataRoot)
        // A committed grant cannot be replaced by stale file credentials.
        if try committedReference(dataRoot: dataRoot) != nil { return }
        let legacyPath = dataRoot.appendingPathComponent("oauth_tokens/slack.json")
        let legacy = try readMetadata(at: legacyPath)
        var sources = [object]
        if let legacy { sources.append(legacy) }
        for (token, keys) in fileKeys {
            let value = sources.lazy.flatMap { source in
                keys.lazy.compactMap { key -> String? in
                    guard case .string(let raw)? = source[key] else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }.first
            if let value { try write(value, token, dataRoot: dataRoot) }
        }
        // Retire the lower-priority source first: an interruption leaves any
        // canonical plaintext in place until the complete pair is in Keychain.
        if legacy != nil {
            try retireLegacyMetadata(dataRoot: dataRoot)
        }
        let tokenKeys = fileKeys.values.joined().filter { object[$0] != nil }
        if !tokenKeys.isEmpty {
            for key in tokenKeys { object[key] = nil }
            object["credential_store"] = .string("keychain")
            let path = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
            let bytes = try JSONValue.object(object).serializedData(pretty: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: path)
            guard try Data(contentsOf: path) == bytes else { throw Failure.unavailable }
        }
    }

    /// The registry's connection decision governs both file migration paths.
    /// Caller holds registry then canonical auth's lock, including retirement.
    private static func permitsFileMigration(dataRoot: URL) throws -> Bool {
        if try ConnectorOAuthRegistry.permitsCredentialMigration(root: dataRoot, provider: "slack") { return true }
        try retireLegacyMetadata(dataRoot: dataRoot)
        return false
    }

    private static func retireLegacyMetadata(dataRoot: URL) throws {
        let legacy = dataRoot.appendingPathComponent("oauth_tokens/slack.json")
        do {
            try FileManager.default.removeItem(at: legacy)
        } catch CocoaError.fileNoSuchFile { return }
        try SwiftNativePersistenceCore.syncDirectory(legacy.deletingLastPathComponent())
    }

    /// Registry permission and canonical absence permit a checked, one-time import.
    public static func metadata(dataRoot: URL) throws -> [String: JSONValue] {
        let path = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        return try CredentialFileLock.withLock(ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)) {
            try CredentialFileLock.withLock(path) {
                let mayImport = try permitsFileMigration(dataRoot: dataRoot)
                if let object = try readMetadata(at: path) { return object }
                guard mayImport,
                      let object = try readMetadata(at: dataRoot.appendingPathComponent("oauth_tokens/slack.json")) else { return [:] }
                let bytes = try JSONValue.object(object).serializedData(pretty: true)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: path)
                guard try Data(contentsOf: path) == bytes else { throw Failure.unavailable }
                // Preserve every field, including any not-yet-migrated token,
                // before retiring the source. Runtime policy reads canonical auth.
                try retireLegacyMetadata(dataRoot: dataRoot)
                return object
            }
        }
    }

    private static func readMetadata(at path: URL) throws -> [String: JSONValue]? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PersistenceCoreError.ioFailure("Saved connector credentials must be a regular file")
            }
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let data = try Data(contentsOf: path)
        guard case .object(let object) = JSONValue(fromFoundation: try JSONSerialization.jsonObject(with: data)) else {
            throw PersistenceCoreError.ioFailure("Saved connector credentials must be a JSON object")
        }
        for field in ["access_token", "refresh_token", "oauth_token", "token", "token_type", "scope",
                      "client_id", "client_secret", "connector_id", "redirect_uri", "provider",
                      "saved_at", "validated_at", "credential_store", "credential_keychain_ref", "auth_mode", "bot_token", "app_token",
                      "socket_mode_app_token", "slack_app_token", "team_id", "team", "url", "user", "bot_id", "enterprise_id",
                      "login", "name", "html_url", "type", "account_id", "refresh_token_account_id",
                      "account_sub", "refresh_token_account_sub"] {
            guard let value = object[field] else { continue }
            guard case .string = value else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be a string")
            }
        }
        if let value = object["user_id"] {
            switch value {
            case .string, .int: break
            default: throw PersistenceCoreError.ioFailure("Saved connector user_id must be a string or integer")
            }
        }
        if let value = object["credential_version"], case .int = value {} else if object["credential_version"] != nil {
            throw PersistenceCoreError.ioFailure("Saved connector credential_version must be an integer")
        }
        for field in ["socket_mode_enabled", "require_mention"] {
            guard let value = object[field] else { continue }
            guard case .bool = value else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be a boolean")
            }
        }
        for field in ["allowed_channel_ids", "allowed_user_ids"] {
            guard let value = object[field] else { continue }
            guard case .array(let ids) = value,
                  ids.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be an array of strings")
            }
        }
        for field in ["expires_at", "expires_in"] {
            guard let value = object[field] else { continue }
            switch value {
            case .string, .int, .double: break
            default: throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) has an invalid type")
            }
        }
        _ = try TransportAllowlist.slack(fields: object)
        return object
    }

    /// The registry lock is held by the caller, then this owner holds metadata
    /// through both publications, matching credential saves and snapshots.
    public static func setSocketModeEnabled(
        _ enabled: Bool, dataRoot: URL,
        publishRegistry: @Sendable () async throws -> Void
    ) async throws {
        let path = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var config = try metadata(dataRoot: dataRoot)
            try await publishRegistry()
            config["socket_mode_enabled"] = .bool(enabled)
            try await SwiftNativePersistenceCore.writeJSON(.object(config), to: path)
        }
    }

    public static func revoke(
        dataRoot: URL, publishRegistry: @Sendable () async throws -> Void
    ) async throws {
        let path = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            _ = try metadata(dataRoot: dataRoot)
            try await publishRegistry()
            // Keep the reference locked until its Keychain grant is removed.
            try delete(dataRoot: dataRoot)
            // Retire the import source before canonical removal, so disconnect
            // cannot make an old file eligible for import again.
            try retireLegacyMetadata(dataRoot: dataRoot)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
    }

    private static func grantAccount(_ reference: String, dataRoot: URL) -> String {
        account(.bot, dataRoot: dataRoot) + ":grant:" + reference
    }

    private static func committedReference(dataRoot: URL) throws -> String? {
        let path = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard case .object(let object) = try JSONValue.parse(Data(contentsOf: path)) else { throw Failure.unavailable }
        guard let value = object[referenceField] else { return nil }
        guard case .string(let reference) = value, UUID(uuidString: reference) != nil else { throw Failure.unavailable }
        return reference
    }

    private static func grant(_ reference: String, dataRoot: URL, allowMissing: Bool = false) throws -> [String: String] {
        guard let bytes = try DeviceSecretKeychain.read(service: service, account: grantAccount(reference, dataRoot: dataRoot)) else {
            if allowMissing { return [:] }
            throw Failure.unavailable
        }
        let pair = try JSONDecoder().decode([String: String].self, from: bytes)
        guard pair[Token.bot.rawValue]?.isEmpty == false,
              pair[Token.app.rawValue]?.isEmpty != true else { throw Failure.unavailable }
        return pair
    }

    public static func stageGrant(bot: String, app: String?, dataRoot: URL) throws -> String {
        var pair = [Token.bot.rawValue: bot]
        pair[Token.app.rawValue] = app
        if let reference = try committedReference(dataRoot: dataRoot),
           (try? grant(reference, dataRoot: dataRoot)) == pair { return reference }
        let reference = UUID().uuidString
        try DeviceSecretKeychain.insert(JSONEncoder().encode(pair), service: service,
                                       account: grantAccount(reference, dataRoot: dataRoot))
        guard try grant(reference, dataRoot: dataRoot) == pair else { throw Failure.unavailable }
        return reference
    }

    private static func saveIntent(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("connectors/slack/save_intent.json")
    }

    /// Caller holds registry and connector locks. The intent contains
    /// only metadata and a verified immutable Keychain reference, never tokens.
    public static func commitSave(connector: JSONValue, registry: JSONValue, dataRoot: URL) throws {
        let intent = JSONValue.object(["version": .int(1), "connector": connector, "registry": registry])
        let path = saveIntent(dataRoot: dataRoot)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw Failure.unavailable }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(intent.serializedData(pretty: true), to: path)
        try recoverPendingSave(dataRoot: dataRoot)
    }

    public static func recoverPendingSave(dataRoot: URL) throws {
        let registryPath = ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)
        let authPath = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        let path = saveIntent(dataRoot: dataRoot)
        try CredentialFileLock.withLock(registryPath) {
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            try CredentialFileLock.withLock(authPath) {
                guard case .object(let intent) = try JSONValue.parse(Data(contentsOf: path)),
                      intent["version"] == .int(1),
                      case .object(let connector)? = intent["connector"],
                      case .string(let reference)? = connector[referenceField], UUID(uuidString: reference) != nil,
                      let savedRegistry = intent["registry"],
                      fileKeys.values.joined().allSatisfy({ connector[$0] == nil }) else {
                    throw Failure.unavailable
                }
                let registry = JSONValue.array(try ConnectorOAuthRegistry.checkedConnectorRows(from: savedRegistry).map(JSONValue.object))
                _ = try grant(reference, dataRoot: dataRoot)
                // Canonical auth publishes metadata and grant together; the
                // registry is last. A crash keeps the exact intent for retry.
                let bytes = try JSONValue.object(connector).serializedData(pretty: true)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: authPath)
                guard try Data(contentsOf: authPath) == bytes else { throw Failure.unavailable }
                try ConnectorOAuthRegistry.writeRegistry(registry, at: registryPath)
                guard try Data(contentsOf: registryPath) == registry.serializedData(pretty: true) else { throw Failure.unavailable }
                try FileManager.default.removeItem(at: path)
                try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
            }
        }
    }

    private enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Slack's token could not be read from or saved to Keychain." }
    }
}
