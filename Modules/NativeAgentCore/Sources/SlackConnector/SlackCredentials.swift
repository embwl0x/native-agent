import CryptoKit
import Foundation
import PersistenceCore
import Security

/// Slack's tokens live in this Mac's Keychain (secrets → Keychain), one pair
/// per data root. The two connector files keep only the rest: team,
/// allowlists, socket-mode switches.
public enum SlackCredentials {
    public enum Token: String, Sendable, CaseIterable { case bot, app }
    private static let service = "com.nativeagent.connector.slack.v1"
    public static let referenceField = "credential_keychain_ref"
    /// Where a token sat in the files before 10-07, by kind.
    public static let fileKeys: [Token: [String]] = [
        .bot: SlackConnectorActions.credentialKeys,
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
        try CredentialFileLock.withLock(files(dataRoot: dataRoot)[0]) {
            guard !FileManager.default.fileExists(atPath: saveIntent(dataRoot: dataRoot).path) else { throw Failure.unavailable }
            if let reference = try committedReference(dataRoot: dataRoot) {
                return try grant(reference, dataRoot: dataRoot, allowMissing: allowMissingGrant && token == .app)[token.rawValue]
            }
            return try readLegacy(token, dataRoot: dataRoot)
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
        try CredentialFileLock.withLock(files(dataRoot: dataRoot)[0]) {
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

    /// The connector files: `connectors/slack/auth.json` and `oauth_tokens/slack.json`.
    public static func files(dataRoot: URL) -> [URL] {
        [dataRoot.appendingPathComponent("connectors/slack/auth.json"),
         dataRoot.appendingPathComponent("oauth_tokens/slack.json")]
    }

    /// At launch: a token still written in a connector file moves here, and
    /// leaves both files. Nothing is removed until Keychain holds it; the
    /// connector's own file wins over the older `oauth_tokens` copy.
    public static func migrate(dataRoot: URL) throws {
        // Match connector saves' lock order; retain both locks from selection
        // through cleanup so a save cannot change the winning generation.
        let files = files(dataRoot: dataRoot)
        try CredentialFileLock.withLock(dataRoot.appendingPathComponent("connectors/registry.json")) {
            try recoverPendingSave(dataRoot: dataRoot)
            try CredentialFileLock.withLock(files[1]) {
                try CredentialFileLock.withLock(files[0]) {
                    try migrateLocked(dataRoot: dataRoot)
                }
            }
        }
    }

    private static func migrateLocked(dataRoot: URL) throws {
        // Once a reference is committed, stale plaintext cannot select a new grant.
        if let reference = try committedReference(dataRoot: dataRoot) {
            _ = try grant(reference, dataRoot: dataRoot)
            return
        }
        let paths = files(dataRoot: dataRoot).filter { FileManager.default.fileExists(atPath: $0.path) }
        func load(_ file: URL) throws -> [String: JSONValue] {
            guard case .object(let object) = try JSONValue.parse(Data(contentsOf: file)) else { return [:] }
            return object
        }
        let objects = try paths.map(load)
        for (token, keys) in fileKeys {
            let value = objects.lazy.flatMap { object in keys.lazy.compactMap { key -> String? in
                guard case .string(let raw)? = object[key] else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } }.first
            if let value { try write(value, token, dataRoot: dataRoot) }
        }
        // Remove the lower-priority copy first. After any interruption the
        // winning plaintext remains until every losing copy is gone.
        for file in paths.reversed() {
            try CredentialFileLock.withLock(file) {
                var object = try load(file)
                let keys = fileKeys.values.joined().filter { object[$0] != nil }
                guard !keys.isEmpty else { return }
                for key in keys { object[key] = nil }
                object["credential_store"] = .string("keychain")
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue.object(object).serializedData(pretty: true), to: file)
            }
        }
    }

    private static func grantAccount(_ reference: String, dataRoot: URL) -> String {
        account(.bot, dataRoot: dataRoot) + ":grant:" + reference
    }

    private static func committedReference(dataRoot: URL) throws -> String? {
        let path = files(dataRoot: dataRoot)[0]
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

    /// Caller holds registry, legacy and connector locks. The intent contains
    /// only metadata and a verified immutable Keychain reference, never tokens.
    public static func commitSave(legacy: JSONValue, connector: JSONValue, registry: JSONValue, dataRoot: URL) throws {
        let intent = JSONValue.object(["version": .int(1), "legacy": legacy, "connector": connector, "registry": registry])
        let path = saveIntent(dataRoot: dataRoot)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw Failure.unavailable }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(intent.serializedData(pretty: true), to: path)
        try recoverPendingSave(dataRoot: dataRoot)
    }

    public static func recoverPendingSave(dataRoot: URL) throws {
        let registryPath = dataRoot.appendingPathComponent("connectors/registry.json")
        let paths = files(dataRoot: dataRoot)
        try CredentialFileLock.withLock(registryPath) {
            try CredentialFileLock.withLock(paths[1]) {
                try CredentialFileLock.withLock(paths[0]) {
                    let path = saveIntent(dataRoot: dataRoot)
                    guard FileManager.default.fileExists(atPath: path.path) else { return }
                    guard case .object(let intent) = try JSONValue.parse(Data(contentsOf: path)),
                          intent["version"] == .int(1),
                          case .object(let connector)? = intent["connector"],
                          case .object(let legacy)? = intent["legacy"],
                          case .string(let reference)? = connector[referenceField], UUID(uuidString: reference) != nil,
                          legacy[referenceField] == .string(reference),
                          let registry = intent["registry"],
                          fileKeys.values.joined().allSatisfy({ connector[$0] == nil && legacy[$0] == nil }) else {
                        throw Failure.unavailable
                    }
                    switch registry { case .object, .array: break; default: throw Failure.unavailable }
                    _ = try grant(reference, dataRoot: dataRoot)
                    // Canonical auth publishes metadata and grant together; the
                    // registry is last. A crash keeps the exact intent for retry.
                    for (destination, value) in [(paths[1], JSONValue.object(legacy)), (paths[0], .object(connector)), (registryPath, registry)] {
                        let bytes = try value.serializedData(pretty: true)
                        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: destination)
                        guard try Data(contentsOf: destination) == bytes else { throw Failure.unavailable }
                    }
                    try FileManager.default.removeItem(at: path)
                    try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
                }
            }
        }
    }

    private enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Slack's token could not be read from or saved to Keychain." }
    }
}
