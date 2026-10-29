import AgentLinkTransport
import Foundation
import NativeAgentCore
import Security
import PersistenceCore
// Blueprint: | `AgentPeerTransport.swift` | `AgentPeerCredentials`: credential uniqueness and availability; bearer comparison delegates to `BridgeCore` |


/// Dedicated per-peer secrets. Never consults generic provider or bridge keys.
public enum AgentPeerCredentials {
    public static let unavailableDetail = "Contact credential is unresolved. agent.connect repairs a confirmed missing key; resolve Keychain access errors before reconnecting."

    /// Inbound doors and current contact projections share this check.
    public static func resolve(_ token: String, peers: [AgentPeerContact],
                               readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> AgentPeerContact? {
        guard AgentPeerHTTP.validToken(token) else { return nil }
        let matches = peers.filter { peer in
            guard peer.credentialKey == AgentPeerContact.credentialKey(for: peer.id),
                  let stored = try? readCredential(peer.id) else { return false }
            return BridgeCore.constantTimeEquals(stored, token)
        }
        return matches.count == 1 ? matches.first : nil
    }

    public static func isAvailable(_ peer: AgentPeerContact, peers: [AgentPeerContact],
                                   readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> Bool {
        // Local ACP sessions and desktop routes do not use a contact bearer.
        if peer.credentialKey == nil && (peer.transport == .acp || peer.transport == .desktop || peer.transport == .desktopChat) { return true }
        guard let token = try? readCredential(peer.id) else { return false }
        return resolve(token, peers: peers, readCredential: readCredential)?.id == peer.id
    }

    /// Pre-upgrade credentials remain valid for the same stable contact ID.
    static let legacyService = "com.nativeagent.agent-peer-bearer"

    /// This install's own peer bearers.
    static var service: String {
        guard let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.isEmpty else { return legacyService }
        return "\(legacyService).\(bundleID)"
    }
    public enum CredentialError: Error, LocalizedError, Equatable {
        case invalidPeer, invalidToken
        case unavailable(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .invalidPeer: return "Contact credential identity is invalid."
            case .invalidToken: return "Contact bearer credential is invalid."
            case .unavailable(let status): return "Contact credential access failed in Keychain (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "No system explanation")."
            }
        }
        var failure: ToolFailureError {
            switch self {
            case .invalidPeer, .invalidToken:
                return ToolFailureError(errorDescription!, effects: .none,
                    nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]),
                    code: self == .invalidPeer ? "agent_credential_identity_invalid" : "agent_credential_token_invalid",
                    instruction: "Read contacts; use the contact's exact peer ID and a valid bearer token.", recovery: .inspect)
            case .unavailable:
                return ToolFailureError(errorDescription!, effects: .unknown, owner: "Contact credentials in Keychain",
                    tap: "Keychain Access → login → unlock and review NativeAgent's credential access",
                    code: "agent_credential_access_failed",
                    instruction: "Resolve the reported Keychain error; preserve existing credentials. Reconnect only when the key is confirmed missing.")
            }
        }
    }
    static func query(peerID: String) throws -> [String: Any] {
        try query(peerID: peerID, service: service)
    }
    static func query(peerID: String, service: String) throws -> [String: Any] {
        guard UUID(uuidString: peerID)?.uuidString.lowercased() == peerID else { throw CredentialError.invalidPeer.failure }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: AgentPeerContact.credentialKey(for: peerID),
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    private static func readToken(peerID: String, service: String) throws -> String? {
        let query = try query(peerID: peerID, service: service)
        let invalid = ToolFailureError("Saved credential peer:\(peerID) is not a valid bearer token.", effects: .none,
            owner: "Keychain \(service) / \(AgentPeerContact.credentialKey(for: peerID))",
            tap: "Keychain Access → login → \(service) → \(AgentPeerContact.credentialKey(for: peerID))",
            code: "agent_saved_credential_invalid", instruction: "Repair the named Keychain entry with the contact's valid token; preserve existing credential evidence.")
        guard let data = try readData(query, invalidData: invalid) else { return nil }
        guard let token = String(data: data, encoding: .utf8), AgentPeerHTTP.validToken(token) else { throw invalid }
        return token
    }
    /// Prefer the install-scoped key; retain the legacy form indefinitely.
    /// Revocation removes both forms. Read the Keychain at each credential
    /// use, so external repairs and removal take effect without a restart.
    public static func read(peerID: String) throws -> String? {
        try compatibleToken(service: service) { try readToken(peerID: peerID, service: $0) }
    }
    static func compatibleToken(service: String, read: (String) throws -> String?) throws -> String? {
        if let current = try read(service) { return current }
        return service == legacyService ? nil : try read(legacyService)
    }
    public static func write(_ token: String, peerID: String) throws {
        let query = try query(peerID: peerID)
        guard AgentPeerHTTP.validToken(token) else { throw CredentialError.invalidToken.failure }
        try upsert(Data(token.utf8), query: query)
    }
    /// A peer's other secrets (a callback's credentials) live in this same
    /// dedicated store, each under its own account, never in a data file.
    public static func writeSecret(_ data: Data, account: String) throws {
        try upsert(data, query: secretQuery(account))
    }

    private static func upsert(_ data: Data, query: [String: Any]) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecUseAuthenticationUI as String] = nil
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.unavailable(status).failure }
    }

    public static func readSecret(account: String) throws -> Data? {
        try readData(secretQuery(account), invalidData:
            ToolFailureError("Keychain returned no credential data for \(account).", effects: .none,
                owner: "Keychain \(service) / \(account)", tap: "Keychain Access → login → \(service) → \(account)",
                code: "agent_saved_credential_data_invalid", instruction: "Repair the named credential entry without discarding its existing evidence."))
    }

    private static func readData(_ query: [String: Any], invalidData: @autoclosure () -> ToolFailureError) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.unavailable(status).failure }
        guard let data = item as? Data else { throw invalidData() }
        return data
    }

    public static func deleteSecret(account: String) throws {
        let status = SecItemDelete(secretQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable(status).failure }
    }

    private static func secretQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "secret:" + account,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    public static func delete(peerID: String) throws {
        try revoke(service: service) { service in
            let status = SecItemDelete(try query(peerID: peerID, service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable(status).failure }
        }
    }
    static func revoke(service: String, delete: (String) throws -> Void) throws {
        // Legacy first: a partial failure must never reveal an older secret.
        if service != legacyService { try delete(legacyService) }
        try delete(service)
    }
}
