import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Security

public protocol GitHubCredentialVault: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ token: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public enum GitHubCredentialVaultError: Error, Sendable, LocalizedError {
    case keychain(OSStatus)
    case invalidStoredValue
    case verificationFailed
    case malformedMetadata

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "GitHub credential Keychain access failed: \(detail)."
        case .invalidStoredValue:
            return "The GitHub credential in Keychain is invalid."
        case .verificationFailed:
            return "GitHub credential Keychain verification failed."
        case .malformedMetadata:
            return "GitHub credential metadata is malformed."
        }
    }
}

public struct SystemGitHubCredentialVault: GitHubCredentialVault {
    public init() {}

    public func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GitHubCredentialVaultError.keychain(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            throw GitHubCredentialVaultError.invalidStoredValue
        }
        return token
    }

    public func write(_ token: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw GitHubCredentialVaultError.keychain(status)
        }
    }

    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubCredentialVaultError.keychain(status)
        }
    }
}

public struct GitHubCredentialMetadata: Sendable, Equatable {
    public var savedAt: String
    public var validatedAt: String?
    public var login: String?
    public var name: String?
    public var htmlURL: String?
    public var type: String?
    public var userID: Int64?

    public init(
        savedAt: String,
        validatedAt: String? = nil,
        login: String? = nil,
        name: String? = nil,
        htmlURL: String? = nil,
        type: String? = nil,
        userID: Int64? = nil
    ) {
        self.savedAt = savedAt
        self.validatedAt = validatedAt
        self.login = login
        self.name = name
        self.htmlURL = htmlURL
        self.type = type
        self.userID = userID
    }
}

public actor GitHubCredentialStore {
    public static let shared = GitHubCredentialStore()
    public static let keychainService = "com.nativeagent.connector.github.pat.v1"

    private static let secretKeys = ["access_token", "token", "pat"]
    private let vault: any GitHubCredentialVault
    private let persistence: any PersistenceCoreProtocol

    public init(
        vault: any GitHubCredentialVault = SystemGitHubCredentialVault(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.vault = vault
        self.persistence = persistence
    }

    public nonisolated static func credentialAccount(dataRoot: URL) -> String {
        let canonicalPath = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return "data-root:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func metadataPaths(dataRoot: URL) -> [URL] {
        [
            dataRoot
                .appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent("github", isDirectory: true)
                .appendingPathComponent("auth.json"),
            dataRoot
                .appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("github.json"),
        ]
    }

    public func saveToken(
        _ rawToken: String,
        metadata: GitHubCredentialMetadata,
        dataRoot: URL
    ) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubCredentialVaultError.invalidStoredValue }
        let account = Self.credentialAccount(dataRoot: dataRoot)
        try writeAndVerify(token, account: account)
        try await rewriteMetadata(dataRoot: dataRoot, metadata: metadata, createMissing: true)
    }

    /// Resolves the Keychain token and performs the one-time plaintext migration.
    /// A vault error is terminal: plaintext is never an availability fallback.
    public func resolveToken(dataRoot: URL) async throws -> String? {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        if let stored = try vault.read(service: Self.keychainService, account: account) {
            let token = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw GitHubCredentialVaultError.invalidStoredValue }
            try await rewriteMetadata(dataRoot: dataRoot, metadata: nil, createMissing: false)
            return token
        }

        guard let plaintext = try await firstPlaintextToken(dataRoot: dataRoot) else {
            return nil
        }
        try writeAndVerify(plaintext, account: account)
        try await rewriteMetadata(dataRoot: dataRoot, metadata: nil, createMissing: false)
        return plaintext
    }

    @discardableResult
    public func reconcileAtLaunch(dataRoot: URL) async throws -> Bool {
        try await resolveToken(dataRoot: dataRoot) != nil
    }

    public func deleteCredential(dataRoot: URL) async throws {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        try vault.delete(service: Self.keychainService, account: account)
        var firstError: (any Error)?
        for path in Self.metadataPaths(dataRoot: dataRoot) {
            do {
                try await persistence.withFileLock(path) {
                    guard FileManager.default.fileExists(atPath: path.path) else { return }
                    try FileManager.default.removeItem(at: path)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func writeAndVerify(_ token: String, account: String) throws {
        try vault.write(token, service: Self.keychainService, account: account)
        guard try vault.read(service: Self.keychainService, account: account) == token else {
            throw GitHubCredentialVaultError.verificationFailed
        }
    }

    private func firstPlaintextToken(dataRoot: URL) async throws -> String? {
        for path in Self.metadataPaths(dataRoot: dataRoot) {
            let candidate = try await persistence.withFileLock(path) {
                let object = try Self.readObject(at: path)
                return Self.plaintextToken(in: object)
            }
            if let candidate { return candidate }
        }
        return nil
    }

    private func rewriteMetadata(
        dataRoot: URL,
        metadata: GitHubCredentialMetadata?,
        createMissing: Bool
    ) async throws {
        var firstError: (any Error)?
        for path in Self.metadataPaths(dataRoot: dataRoot) {
            if !createMissing && !FileManager.default.fileExists(atPath: path.path) {
                continue
            }
            do {
                try await persistence.withFileLock(path) {
                    var object = try Self.readObject(at: path)
                    for key in Self.secretKeys { object.removeValue(forKey: key) }
                    object["provider"] = .string("github")
                    object["token_type"] = .string("token")
                    object["auth_mode"] = .string("personal_access_token")
                    object["credential_store"] = .string("macos_keychain")
                    object["credential_version"] = .int(1)
                    if let metadata {
                        object["saved_at"] = .string(metadata.savedAt)
                        if let validatedAt = metadata.validatedAt {
                            object["validated_at"] = .string(validatedAt)
                        } else {
                            object.removeValue(forKey: "validated_at")
                        }
                        Self.setIfPresent(metadata.login, key: "login", in: &object)
                        Self.setIfPresent(metadata.name, key: "name", in: &object)
                        Self.setIfPresent(metadata.htmlURL, key: "html_url", in: &object)
                        Self.setIfPresent(metadata.type, key: "type", in: &object)
                        if let userID = metadata.userID { object["user_id"] = .int(userID) }
                    }
                    try await self.persistence.writeJSON(.object(object), to: path)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private nonisolated static func readObject(at path: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard case .object(let object) = try JSONValue.parse(data) else {
            throw GitHubCredentialVaultError.malformedMetadata
        }
        return object
    }

    private nonisolated static func plaintextToken(in object: [String: JSONValue]) -> String? {
        for key in secretKeys {
            guard case .string(let raw)? = object[key] else { continue }
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }

    private nonisolated static func setIfPresent(
        _ raw: String?,
        key: String,
        in object: inout [String: JSONValue]
    ) {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        object[key] = .string(value)
    }
}
