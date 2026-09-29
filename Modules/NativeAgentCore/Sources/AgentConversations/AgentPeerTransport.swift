import AgentLinkTransport
import Foundation
import Security
import PersistenceCore


/// Dedicated per-peer secrets. Never consults generic provider or bridge keys.
public enum AgentPeerCredentials {
    public static let unavailableDetail = "unavailable now - its key is missing; reconnect"

    /// The bearer-only door and current contact projections share this check.
    public static func resolve(_ token: String, peers: [AgentPeerContact],
                               readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> AgentPeerContact? {
        guard AgentPeerHTTP.validToken(token) else { return nil }
        let matches = peers.filter { peer in
            guard peer.credentialKey == AgentPeerContact.credentialKey(for: peer.id),
                  let stored = try? readCredential(peer.id) else { return false }
            let a = Array(stored.utf8), b = Array(token.utf8)
            guard a.count == b.count else { return false }
            return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
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
        case invalidPeer, invalidToken, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidPeer: return "Peer credential identity is invalid."
            case .invalidToken: return "Peer bearer credential is invalid."
            case .unavailable: return "Peer credential could not be accessed in the dedicated Keychain store."
            }
        }
    }
    static func query(peerID: String) throws -> [String: Any] {
        try query(peerID: peerID, service: service)
    }
    static func query(peerID: String, service: String) throws -> [String: Any] {
        guard UUID(uuidString: peerID)?.uuidString.lowercased() == peerID else { throw CredentialError.invalidPeer }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: AgentPeerContact.credentialKey(for: peerID),
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    private static func readToken(peerID: String, service: String) throws -> String? {
        var query = try query(peerID: peerID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), AgentPeerHTTP.validToken(token) else { throw CredentialError.unavailable }
        return token
    }
    /// Prefer the install-scoped key; retain the legacy form indefinitely.
    /// Revocation removes both forms, so fallback cannot resurrect a key.
    public static func read(peerID: String) throws -> String? {
        let (cached, generation) = cache.withLock { ($0.tokens[peerID], $0.generations[peerID, default: 0]) }
        if let cached { return cached }
        let token = try compatibleToken(service: service) { try readToken(peerID: peerID, service: $0) }
        // A write or delete that landed during the read wins; hold nothing.
        cache.withLock { if $0.generations[peerID, default: 0] == generation { $0.tokens[peerID] = .some(token) } }
        return token
    }
    /// 2026-09-25: every contact projection checks every peer's key, so one
    /// people list read the Keychain ~120 times (5.5k SecItemCopyMatching in
    /// 6h). Reads (a missing key too) are held in memory; this process is the
    /// only writer, and write/delete drop the entry and bump its generation
    /// so a read already in flight cannot put the old key back. Failures are
    /// not held.
    private static let cache = LockedPeerTokens()
    private final class LockedPeerTokens: @unchecked Sendable {
        private let lock = NSLock()
        struct State {
            var tokens: [String: String?] = [:]
            var generations: [String: Int] = [:]
        }
        private var state = State()
        func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&state)
        }
        func forget(_ peerID: String) {
            withLock { $0.tokens[peerID] = nil; $0.generations[peerID, default: 0] += 1 }
        }
    }
    static func compatibleToken(service: String, read: (String) throws -> String?) throws -> String? {
        if let current = try read(service) { return current }
        return service == legacyService ? nil : try read(legacyService)
    }
    public static func write(_ token: String, peerID: String) throws {
        let query = try query(peerID: peerID)
        defer { cache.forget(peerID) }
        guard AgentPeerHTTP.validToken(token) else { throw CredentialError.invalidToken }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecUseAuthenticationUI as String] = nil
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.unavailable }
    }
    public static func delete(peerID: String) throws {
        defer { cache.forget(peerID) }
        try revoke(service: service) { service in
            let status = SecItemDelete(try query(peerID: peerID, service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
        }
    }
    static func revoke(service: String, delete: (String) throws -> Void) throws {
        // Legacy first: a partial failure must never reveal an older secret.
        if service != legacyService { try delete(legacyService) }
        try delete(service)
    }
}
