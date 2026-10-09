import CryptoKit
import Foundation
import LocalAuthentication
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
    case accountChanged
    case replacementRollbackFailed

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
        case .accountChanged:
            return "GitHub account changed — retry the request."
        case .replacementRollbackFailed:
            return "GitHub connection failed, and the prior credentials could not be restored."
        }
    }
}

public struct SystemGitHubCredentialVault: GitHubCredentialVault {
    public init() {}

    static func nonInteractiveIdentityQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // A background agent must never summon a login
            // password dialog. If an item's ACL requires interaction, surface
            // errSecInteractionNotAllowed and let the caller report degraded
            // readiness instead of blocking the production chain.
            kSecUseAuthenticationContext as String: context,
        ]
    }

    public func read(service: String, account: String) throws -> String? {
        var query = Self.nonInteractiveIdentityQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
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
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let query = Self.nonInteractiveIdentityQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
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
        let query = Self.nonInteractiveIdentityQuery(service: service, account: account)
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
    /// The OAuth device-flow credential (JSON). It wins over the PAT when present.
    public static let oauthKeychainService = "com.nativeagent.connector.github.oauth.v1"

    private static let secretKeys = ["access_token", "token", "pat"]
    private let vault: any GitHubCredentialVault
    private let persistence: any PersistenceCoreProtocol
    /// One refresh at a time per data root: GitHub rotates the refresh token,
    /// so a second concurrent refresh would spend a dead one.
    private var refreshInFlight: [String: Task<GitHubOAuthDeviceFlow.Token?, any Error>] = [:]
    private var lastRefresh: [String: (original: String, token: GitHubOAuthDeviceFlow.Token)] = [:]
    /// A Doctor waiter protects the shared exchange even if a runtime caller started it.
    private var nonDestructiveRefreshes: Set<String> = []
    /// Bumped by every save and delete, per data root. A refresh that
    /// finishes after one of those must not write or clear anything.
    private var generation: [String: Int] = [:]

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
        dataRoot: URL,
        persistConnection: @Sendable () async throws -> Void = {}
    ) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubCredentialVaultError.invalidStoredValue }
        let account = Self.credentialAccount(dataRoot: dataRoot)
        let prior = try replacementSnapshot(dataRoot: dataRoot, account: account)
        generation[account, default: 0] += 1
        let started = generation[account, default: 0]
        lastRefresh[account] = nil
        do {
            try writeAndVerify(token, account: account)
            // A pasted token replaces the sign-in that would otherwise win.
            try vault.delete(service: Self.oauthKeychainService, account: account)
            try await rewriteMetadata(dataRoot: dataRoot, metadata: metadata, createMissing: true,
                                      authMode: "personal_access_token")
            guard generation[account] == started else { throw GitHubCredentialVaultError.accountChanged }
            try await persistConnection()
        } catch {
            try rollbackReplacement(prior, account: account, generation: started)
            throw error
        }
    }

    /// Saves a device-flow sign-in. Any saved PAT stays as the fallback.
    public func saveOAuthToken(
        _ token: GitHubOAuthDeviceFlow.Token,
        metadata: GitHubCredentialMetadata,
        dataRoot: URL,
        persistConnection: @Sendable () async throws -> Void = {}
    ) async throws {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        var token = token
        token.accountID = metadata.userID
        token.refreshTokenAccountID = token.refreshToken == nil ? nil : metadata.userID
        let prior = try replacementSnapshot(dataRoot: dataRoot, account: account)
        generation[account, default: 0] += 1
        let started = generation[account, default: 0]
        lastRefresh[account] = nil
        do {
            try writeOAuth(token, account: account)
            try await rewriteMetadata(dataRoot: dataRoot, metadata: metadata, createMissing: true,
                                      authMode: "oauth_device")
            guard generation[account] == started else { throw GitHubCredentialVaultError.accountChanged }
            try await persistConnection()
        } catch {
            try rollbackReplacement(prior, account: account, generation: started)
            throw error
        }
    }

    private struct ReplacementSnapshot {
        let credentials: [(service: String, value: String?)]
        let metadata: [(path: URL, bytes: Data?)]
    }

    private func replacementSnapshot(dataRoot: URL, account: String) throws -> ReplacementSnapshot {
        let metadata = try Self.metadataPaths(dataRoot: dataRoot).map { path in
            _ = try Self.readObject(at: path)
            let bytes = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
            return (path: path, bytes: bytes)
        }
        let credentials = try [Self.keychainService, Self.oauthKeychainService].map {
            (service: $0, value: try vault.read(service: $0, account: account))
        }
        return ReplacementSnapshot(credentials: credentials, metadata: metadata)
    }

    private func rollbackReplacement(_ prior: ReplacementSnapshot, account: String, generation started: Int) throws {
        guard generation[account] == started else { return }
        // A refresh begun on the rejected replacement must not resurrect it.
        generation[account, default: 0] += 1
        lastRefresh[account] = nil
        do {
            try restoreReplacement(prior, account: account)
        } catch {
            throw GitHubCredentialVaultError.replacementRollbackFailed
        }
    }

    private func restoreReplacement(_ prior: ReplacementSnapshot, account: String) throws {
        for credential in prior.credentials {
            if let value = credential.value {
                try vault.write(value, service: credential.service, account: account)
            } else {
                try vault.delete(service: credential.service, account: account)
            }
            guard try vault.read(service: credential.service, account: account) == credential.value else {
                throw GitHubCredentialVaultError.verificationFailed
            }
        }
        for metadata in prior.metadata {
            if let bytes = metadata.bytes {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: metadata.path)
            } else if FileManager.default.fileExists(atPath: metadata.path.path) {
                try FileManager.default.removeItem(at: metadata.path)
            }
        }
    }

    /// After GitHub answered 401 to `rejected`: refresh the sign-in once and
    /// return the new access token, or nil when there is no sign-in to refresh.
    public func refreshAfterRejection(_ rejected: String, dataRoot: URL) async throws -> String? {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        guard let stored = try readOAuth(account: account) else { return nil }
        // Only this owner's completed exchange proves that a changed token
        // continues the rejected request's account, rather than a new sign-in.
        if stored.accessToken != rejected {
            guard let previous = lastRefresh[account],
                  previous.original == rejected,
                  let accountID = previous.token.accountID,
                  accountID == stored.accountID,
                  previous.token.accessToken == stored.accessToken,
                  previous.token.refreshToken == stored.refreshToken else {
                throw GitHubCredentialVaultError.accountChanged
            }
            return stored.accessToken
        }
        guard stored.refreshToken != nil else { return nil }
        return try await refreshedOAuth(stored, account: account, dataRoot: dataRoot)?.accessToken
    }

    /// Doctor reads the Keychain owner's metadata, never the non-secret mirror's expiry.
    public func credentialStatus(dataRoot: URL, requiringOAuth: Bool = false) throws -> (configured: Bool, expiresAt: Date?, canRefresh: Bool) {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        if let token = try readOAuth(account: account) {
            let hasRefresh = token.refreshToken?.isEmpty == false
            var canRefresh = hasRefresh && token.hasRefreshBinding
            if hasRefresh && token.refreshTokenAccountID == nil {
                canRefresh = try expectedAccountID(for: token, dataRoot: dataRoot) != nil
            }
            return (true, token.expiresAt, canRefresh)
        }
        if requiringOAuth { return (false, nil, false) }
        let pat = try vault.read(service: Self.keychainService, account: account)
        return (pat?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, nil, false)
    }

    public func refreshCredential(dataRoot: URL) async throws {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        guard let stored = try readOAuth(account: account), stored.refreshToken?.isEmpty == false else {
            throw GitHubCredentialVaultError.invalidStoredValue
        }
        // Doctor must neither migrate/fall back to a PAT nor clear a rejected sign-in.
        guard try await refreshedOAuth(stored, account: account, dataRoot: dataRoot, preserveOnRejection: true) != nil else {
            throw GitHubCredentialVaultError.invalidStoredValue
        }
    }

    private func readOAuth(account: String) throws -> GitHubOAuthDeviceFlow.Token? {
        guard let raw = try vault.read(service: Self.oauthKeychainService, account: account) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let token = try? decoder.decode(GitHubOAuthDeviceFlow.Token.self, from: Data(raw.utf8)),
              !token.accessToken.isEmpty
        else { throw GitHubCredentialVaultError.invalidStoredValue }
        return token
    }

    private func writeOAuth(_ token: GitHubOAuthDeviceFlow.Token, account: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let raw = String(decoding: try encoder.encode(token), as: UTF8.self)
        try vault.write(raw, service: Self.oauthKeychainService, account: account)
        guard try vault.read(service: Self.oauthKeychainService, account: account) == raw else {
            throw GitHubCredentialVaultError.verificationFailed
        }
    }

    private func expectedAccountID(for token: GitHubOAuthDeviceFlow.Token, dataRoot: URL) throws -> Int64? {
        if let accountID = token.accountID { return accountID }
        var expected: Int64?
        for path in Self.metadataPaths(dataRoot: dataRoot) {
            let object = try Self.readObject(at: path)
            guard let value = object["user_id"] else { continue }
            guard case .int(let userID) = value, userID > 0 else { return nil }
            if let expected, expected != userID { return nil }
            expected = userID
        }
        return expected
    }

    /// Refreshes, coalesced. A rejected bound grant clears the sign-in and
    /// returns nil. Doctor and legacy grants preserve the credential on rejection.
    /// The request cannot fall through to a PAT from another account.
    private func refreshedOAuth(
        _ stored: GitHubOAuthDeviceFlow.Token, account: String, dataRoot: URL,
        preserveOnRejection: Bool = false
    ) async throws -> GitHubOAuthDeviceFlow.Token? {
        guard let refreshToken = stored.refreshToken else { return stored }
        let expectedAccountID = try expectedAccountID(for: stored, dataRoot: dataRoot)
        let legacy = stored.refreshTokenAccountID == nil && expectedAccountID != nil
        // Only an absent binding can migrate; a mismatched binding must not rotate.
        guard stored.hasRefreshBinding || legacy else {
            throw GitHubOAuthDeviceFlow.FlowError.refreshRejected("account_mismatch")
        }
        if preserveOnRejection || legacy { nonDestructiveRefreshes.insert(account) }
        if let inFlight = refreshInFlight[account] {
            let fresh = try await inFlight.value
            guard fresh?.accountID == expectedAccountID,
                  try readOAuth(account: account)?.accountID == expectedAccountID else {
                throw GitHubCredentialVaultError.accountChanged
            }
            return fresh
        }
        let started = generation[account, default: 0]
        // Runs on this actor; it writes before any waiter resumes.
        let task = Task { () throws -> GitHubOAuthDeviceFlow.Token? in
            defer {
                self.refreshInFlight[account] = nil
                self.nonDestructiveRefreshes.remove(account)
            }
            do {
                var fresh = try await GitHubOAuthDeviceFlow.refresh(refreshToken)
                if legacy {
                    let user = try? await GitHubConnectorActions.validateToken(fresh.accessToken)
                    let accountID = (user?["id"] as? NSNumber)?.int64Value
                    guard accountID == expectedAccountID,
                          fresh.refreshToken?.isEmpty == false else {
                        throw GitHubOAuthDeviceFlow.FlowError.refreshRejected("account_mismatch")
                    }
                }
                fresh.accountID = expectedAccountID
                fresh.refreshTokenAccountID = fresh.refreshToken == nil ? nil : expectedAccountID
                // Saved or disconnected meanwhile: that choice stands.
                guard self.generation[account, default: 0] == started else {
                    throw GitHubCredentialVaultError.accountChanged
                }
                try self.writeOAuth(fresh, account: account)
                self.lastRefresh[account] = (stored.accessToken, fresh)
                return fresh
            } catch GitHubOAuthDeviceFlow.FlowError.refreshRejected(let code) {
                if self.nonDestructiveRefreshes.contains(account) {
                    throw GitHubOAuthDeviceFlow.FlowError.refreshRejected(code)
                }
                guard self.generation[account, default: 0] == started else {
                    throw GitHubCredentialVaultError.accountChanged
                }
                nativeLog("[github] OAuth refresh rejected (%@); clearing the sign-in", code)
                try self.vault.delete(service: Self.oauthKeychainService, account: account)
                return nil
            }
        }
        refreshInFlight[account] = task
        return try await task.value
    }

    /// Resolves the Keychain token and performs the one-time plaintext migration.
    /// A vault error is terminal: plaintext is never an availability fallback.
    public func resolveToken(dataRoot: URL) async throws -> String? {
        try await resolveToken(dataRoot: dataRoot, reconcileMetadata: false)
    }

    @discardableResult
    public func reconcileAtLaunch(dataRoot: URL) async throws -> Bool {
        try await resolveToken(dataRoot: dataRoot, reconcileMetadata: true) != nil
    }

    private func resolveToken(dataRoot: URL, reconcileMetadata: Bool) async throws -> String? {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        if let oauth = try readOAuth(account: account) {
            if !oauth.needsRefresh() { return oauth.accessToken }
            do {
                if let fresh = try await refreshedOAuth(oauth, account: account, dataRoot: dataRoot) {
                    return fresh.accessToken
                }
            } catch GitHubCredentialVaultError.accountChanged {
                throw GitHubCredentialVaultError.accountChanged
            } catch {
                // Transient (offline, 5xx): the old token may still have minutes left.
                if let expiresAt = oauth.expiresAt, expiresAt > Date() { return oauth.accessToken }
                throw error
            }
            return nil
        }
        if let stored = try vault.read(service: Self.keychainService, account: account) {
            let token = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw GitHubCredentialVaultError.invalidStoredValue }
            // 2026-09-23: the no-op rewrite ran under a file lock on every token
            // read (~4,200/day). Rewrite at launch, or when plaintext is present.
            var plaintextPresent = false
            for path in Self.metadataPaths(dataRoot: dataRoot) {
                let object = try Self.readObject(at: path)
                plaintextPresent = plaintextPresent || Self.secretKeys.contains { object[$0] != nil }
            }
            if reconcileMetadata || plaintextPresent {
                try await rewriteMetadata(dataRoot: dataRoot, metadata: nil, createMissing: false)
            }
            return token
        }

        guard let plaintext = try await firstPlaintextToken(dataRoot: dataRoot) else {
            return nil
        }
        try writeAndVerify(plaintext, account: account)
        try await rewriteMetadata(dataRoot: dataRoot, metadata: nil, createMissing: false)
        return plaintext
    }

    public func deleteCredential(dataRoot: URL) async throws {
        let account = Self.credentialAccount(dataRoot: dataRoot)
        generation[account, default: 0] += 1
        lastRefresh[account] = nil
        try vault.delete(service: Self.keychainService, account: account)
        try vault.delete(service: Self.oauthKeychainService, account: account)
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
        createMissing: Bool,
        authMode: String? = nil
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
                    if let authMode {
                        object["auth_mode"] = .string(authMode)
                    } else if object["auth_mode"] == nil {
                        object["auth_mode"] = .string("personal_access_token")
                    }
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
