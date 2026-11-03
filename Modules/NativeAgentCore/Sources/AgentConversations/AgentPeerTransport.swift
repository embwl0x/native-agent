import AgentLinkTransport
import Foundation
import NativeAgentCore
import Security
import PersistenceCore
// Blueprint: | `AgentPeerTransport.swift` | `AgentPeerCredentials`: per-contact checked credential reads and unique resolution among readable keys; an unreadable contact retains its own failure without denying readable siblings; inbound doors disclose no Keychain details; bearer comparison delegates to `BridgeCore` |


/// Dedicated per-peer secrets. Never consults generic provider or bridge keys.
public enum AgentPeerCredentials {
    public static let unavailableDetail = "Contact credential is unresolved. agent.connect repairs a confirmed missing key; resolve Keychain access errors before reconnecting."

    /// Inbound doors disclose no local credential-read failure to the caller.
    /// A failed row cannot authenticate, but does not veto readable siblings.
    public static func resolve(_ token: String, peers: [AgentPeerContact],
                               readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> AgentPeerContact? {
        guard AgentPeerHTTP.validToken(token) else { return nil }
        return resolve(token, reads: credentialReads(peers, readCredential: readCredential))
    }

    private struct CredentialRead {
        let peer: AgentPeerContact
        let result: Result<String?, ToolFailureError>
    }

    /// Call-scoped evidence only; the next use reads the credential owner again.
    /// Keep failure distinct from confirmed absence, and attribute it to its row.
    private static func credentialReads(_ peers: [AgentPeerContact],
                                        readCredential: (String) throws -> String?) -> [CredentialRead] {
        peers.filter { $0.credentialKey == AgentPeerContact.credentialKey(for: $0.id) }.map { peer in
            let result: Result<String?, ToolFailureError>
            do {
                let token = try readCredential(peer.id)
                if let token, !AgentPeerHTTP.validToken(token) { throw CredentialError.invalidToken.failure }
                result = .success(token)
            } catch {
                let cause = error as? ToolFailureError
                result = .failure(ToolFailureError("Contact \(peer.name) (peer:\(peer.id)) credential access failed: \(error.localizedDescription)",
                    argumentPath: cause?.argumentPath, accepted: cause?.accepted,
                    effects: .none, owner: "Keychain peer:" + peer.id, nextCall: cause?.nextCall,
                    tap: cause?.tap ?? "Keychain Access → login → review NativeAgent's credential access for peer:" + peer.id,
                    personDecides: cause?.personDecides ?? false,
                    code: cause?.code ?? "agent_credential_access_failed",
                    status: cause?.status ?? .failed,
                    instruction: cause?.instruction ?? "Resolve this contact's credential read error before reconnecting; preserve existing keys.",
                    recovery: cause?.recovery))
            }
            return CredentialRead(peer: peer, result: result)
        }
    }

    private static func resolve(_ token: String, reads: [CredentialRead]) -> AgentPeerContact? {
        let matches = reads.filter { read in
            switch read.result {
            case .success(let stored?): return BridgeCore.constantTimeEquals(stored, token)
            case .success(nil), .failure: return false
            }
        }
        return matches.count == 1 ? matches.first?.peer : nil
    }

    public static func availability(_ peer: AgentPeerContact, peers: [AgentPeerContact],
                                    readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> Result<Bool, ToolFailureError> {
        // Local ACP sessions and desktop routes do not use a contact bearer.
        if peer.credentialKey == nil && (peer.transport == .acp || peer.transport == .desktop || peer.transport == .desktopChat) { return .success(true) }
        guard peer.credentialKey == AgentPeerContact.credentialKey(for: peer.id) else { return .success(false) }
        let reads = credentialReads(peers, readCredential: readCredential)
        guard let selected = reads.first(where: { $0.peer.id == peer.id }) else { return .success(false) }
        switch selected.result {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .success(false)
        case .success(let token?): return .success(resolve(token, reads: reads)?.id == peer.id)
        }
    }

    /// Authority checks deny on unreadable credentials. Local projections use
    /// `availability` so the same failure remains visible with its remedy.
    public static func isAvailable(_ peer: AgentPeerContact, peers: [AgentPeerContact]) -> Bool {
        switch availability(peer, peers: peers) {
        case .success(let available): return available
        case .failure: return false
        }
    }

    // Retained only until an entitled installed-app read establishes old-key
    // coverage. An unentitled command-line absence cannot prove it empty.
    static let legacyService = "com.nativeagent.agent-peer-bearer"
    static var service: String {
        get throws {
            guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
                throw ToolFailureError("This install has no bundle identity, so its contact credential namespace cannot be resolved.",
                    effects: .none, owner: "NativeAgent app bundle", tap: "Open the installed, signed NativeAgent app and repair its bundle identity.",
                    code: "agent_credential_install_identity_unavailable")
            }
            return legacyService + "." + bundleID
        }
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
    /// Read this install's Keychain at each credential
    /// use, so external repairs and removal take effect without a restart.
    public static func read(peerID: String) throws -> String? {
        let service = try Self.service
        if let current = try readToken(peerID: peerID, service: service) { return current }
        return try readToken(peerID: peerID, service: legacyService)
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
        let service = try Self.service
        return try readData(secretQuery(account), invalidData:
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
        let status = SecItemDelete(try secretQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable(status).failure }
    }

    private static func secretQuery(_ account: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: try service,
         kSecAttrAccount as String: "secret:" + account,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    public static func delete(peerID: String) throws {
        let service = try Self.service
        for namespace in [legacyService, service] {
            let status = SecItemDelete(try query(peerID: peerID, service: namespace) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable(status).failure }
        }
    }
}
