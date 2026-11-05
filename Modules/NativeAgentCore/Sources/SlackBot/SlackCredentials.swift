import CryptoKit
import Foundation
import PersistenceCore
import Security
// Blueprint: | `SlackCredentials.swift` | Immutable Keychain grants selected by connectors/slack/auth.json; locked metadata save and revocation |

/// Each data root owns a Keychain token pair; auth.json owns metadata and its grant reference. Backup includes metadata, export excludes it, and phone sync
/// carries status only. A missing selected grant requires reconnecting; a command-line miss cannot prove Keychain absence.
public enum SlackCredentials {
    public enum Token: String, Sendable, CaseIterable { case bot, app }
    private static let service = "com.nativeagent.connector.slack.v1"
    public static let referenceField = "credential_keychain_ref"
    public static let generationField = "credential_generation"
    /// Plaintext credential fields forbidden in committed metadata.
    public static let fileKeys: [Token: [String]] = [
        .bot: ["access_token", "oauth_token", "token", "bot_token"],
        .app: ["socket_mode_app_token", "app_token", "slack_app_token"],
    ]

    /// Two data roots on one Mac never share grants.
    private static func rootAccount(dataRoot: URL) -> String {
        let path = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    /// Only an explicit bot-token replacement may omit a missing prior app grant.
    public static func read(_ token: Token, dataRoot: URL, allowMissingGrant: Bool = false) throws -> String? {
        try CredentialFileLock.withLock(ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)) {
            try CredentialFileLock.withLock(TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)) {
                guard !FileManager.default.fileExists(atPath: saveIntent(dataRoot: dataRoot).path) else { throw Failure.unavailable }
                if let reference = try committedReference(dataRoot: dataRoot) {
                    return try grant(reference, dataRoot: dataRoot, allowMissing: allowMissingGrant && token == .app)[token.rawValue]
                }
                _ = try readMetadata(at: TransportAllowlist.slackMetadataPath(dataRoot: dataRoot))
                return try readLegacy(token, dataRoot: dataRoot)
            }
        }
    }

    /// Only installed-app inventory can establish absence in the data-protected Keychain.
    private static func readLegacy(_ token: Token, dataRoot: URL) throws -> String? {
        var request = query()
        request[kSecAttrAccount as String] = rootAccount(dataRoot: dataRoot) + ":" + token.rawValue
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure.unavailable }
        return value
    }

    /// One metadata/token snapshot, using the same lock order as save and revoke.
    public static func withSnapshot<T>(dataRoot: URL, _ body: () throws -> T) throws -> T {
        let authPath = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        return try CredentialFileLock.withLock(ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)) {
            try CredentialFileLock.withLock(authPath) {
                // A save a crash left half-done is finished first (same locks, reentrant).
                try recoverPendingSave(dataRoot: dataRoot)
                return try body()
            }
        }
    }

    /// Disconnecting Slack removes every immutable grant for this root, including references retained by backups or interrupted saves.
    public static func delete(dataRoot: URL) throws {
        try CredentialFileLock.withLock(TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)) {
            guard !FileManager.default.fileExists(atPath: saveIntent(dataRoot: dataRoot).path) else { throw Failure.unavailable }
            // Disconnect must revoke every readable credential namespace.
            for token in Token.allCases {
                try DeviceSecretKeychain.delete(service: service,
                    account: rootAccount(dataRoot: dataRoot) + ":" + token.rawValue)
            }
            var request = query()
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

    public static func metadata(dataRoot: URL) throws -> [String: JSONValue] {
        let path = TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)
        return try CredentialFileLock.withLock(ConnectorOAuthRegistry.connectorRegistryPath(root: dataRoot)) {
            try CredentialFileLock.withLock(path) {
                try readMetadata(at: path) ?? [:]
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
        guard fileKeys.values.joined().allSatisfy({ object[$0] == nil }) else {
            throw PersistenceCoreError.ioFailure(
                """
                Slack metadata contains plaintext credentials. Reconnect Slack to publish a verified Keychain grant; \
                the existing file is preserved.
                """
            )
        }
        for field in ["refresh_token", "token_type", "scope",
                      "client_id", "client_secret", "connector_id", "redirect_uri", "provider",
                      "saved_at", "validated_at", "credential_store", "credential_keychain_ref", "auth_mode",
                      "team", "url", "user", "bot_id", "enterprise_id",
                      "login", "name", "html_url", "type", "account_id", "refresh_token_account_id",
                      "account_sub", "refresh_token_account_sub"] {
            guard let value = object[field] else { continue }
            guard case .string = value else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be a string")
            }
        }
        if let value = object["credential_version"], case .int = value {} else if object["credential_version"] != nil {
            throw PersistenceCoreError.ioFailure("Saved connector credential_version must be an integer")
        }
        for field in ["expires_at", "expires_in"] {
            guard let value = object[field] else { continue }
            switch value {
            case .string, .int, .double: break
            default: throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) has an invalid type")
            }
        }
        _ = try TransportAllowlist.slackPolicy(fields: object)
        return object
    }

    /// The registry lock is held by the caller, then this owner holds metadata through both publications, matching credential saves and snapshots.
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
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
    }

    private static func grantAccount(_ reference: String, dataRoot: URL) -> String {
        rootAccount(dataRoot: dataRoot) + ":bot:grant:" + reference
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

    public static func stageGrant(bot: String, app: String?, dataRoot: URL, allowMissingGrant: Bool) throws -> String {
        var pair = [Token.bot.rawValue: bot]
        pair[Token.app.rawValue] = app
        if let reference = try committedReference(dataRoot: dataRoot),
           try grant(reference, dataRoot: dataRoot, allowMissing: allowMissingGrant) == pair { return reference }
        let reference = UUID().uuidString
        try DeviceSecretKeychain.insert(JSONEncoder().encode(pair), service: service,
                                       account: grantAccount(reference, dataRoot: dataRoot))
        guard try grant(reference, dataRoot: dataRoot) == pair else { throw Failure.unavailable }
        return reference
    }

    private static func saveIntent(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("connectors/slack/save_intent.json")
    }

    /// Caller holds registry and connector locks. The intent contains only metadata and a verified immutable Keychain reference, never tokens.
    public static func commitSave(connector: JSONValue, registry: JSONValue, dataRoot: URL) throws {
        guard case .object(let fields) = connector else { throw Failure.unavailable }
        _ = try TransportAllowlist.slackPolicy(fields: fields)
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
                _ = try TransportAllowlist.slackPolicy(fields: connector)
                _ = try grant(reference, dataRoot: dataRoot)
                // Canonical auth publishes metadata and grant together; the registry is last. A crash keeps the exact intent for retry.
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
        var errorDescription: String? { "Slack's selected Keychain grant could not be read or saved. Reconnect Slack in Connectors to repair its credentials." }
    }
}
