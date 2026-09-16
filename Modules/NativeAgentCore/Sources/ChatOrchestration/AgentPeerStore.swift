import Darwin
import Foundation
import PersistenceCore

public enum AgentPeerTransport: String, Codable, Sendable {
    case a2a
    case nativeAgent
    case desktop
}

/// Configuration only: neither presence, trust, nor permission to send a message.
public struct AgentPeerContact: Codable, Sendable, Equatable {
    /// Stable, canonical lowercase UUID. Names are presentation, never identity.
    public var id: String
    public var name: String
    /// A2A card URL, NativeAgent bridge base URL, or desktop app://bundle ID.
    public var endpoint: URL
    public var transport: AgentPeerTransport
    /// Reference only. Credential values must never enter this document.
    public var credentialKey: String?
    /// Desktop target data only, never a script or verified conversation ID.
    public var conversationLabel: String?
    /// THE PERSON'S OWN GRANT, and the only thing that can raise an inbound
    /// peer turn off the restricted `agent-bridge` surface. Absent means no —
    /// the default for every peer, including one this agent configured or
    /// discovered for itself. Optional rather than `Bool = false` so an
    /// existing peers.json round-trips byte-identically until the person sets
    /// it in Trust Center.
    public var allowElevation: Bool?
    /// Fail-closed reading of the grant above.
    public var elevationAllowed: Bool { allowElevation == true }

    public init(id: String = UUID().uuidString.lowercased(), name: String, endpoint: URL,
                transport: AgentPeerTransport, credentialKey: String? = nil, conversationLabel: String? = nil,
                allowElevation: Bool? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.transport = transport
        self.credentialKey = credentialKey
        self.conversationLabel = conversationLabel
        self.allowElevation = allowElevation
    }

    public static func credentialKey(for id: String) -> String { "agent-peer:\(id)" }
}

public enum AgentPeerStoreError: String, Error, LocalizedError, Sendable {
    case invalidContact, invalidEndpoint, invalidCredentialReference, invalidConfiguration
    case tooManyContacts, configurationTooLarge, unreadableConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidContact: return "Peer identity or name is invalid."
        case .invalidEndpoint: return "Network peer endpoint must be HTTPS or explicit loopback HTTP without credentials, query, or fragment; desktop requires an exact app bundle identifier."
        case .invalidCredentialReference: return "Peer credential reference must belong to this peer's dedicated namespace."
        case .invalidConfiguration: return "Peer configuration is invalid; existing bytes have been preserved."
        case .tooManyContacts: return "Peer contact limit reached."
        case .configurationTooLarge: return "Peer configuration exceeds its bounded size."
        case .unreadableConfiguration: return "Peer configuration cannot be read safely; existing bytes have been preserved."
        }
    }
}

/// The sole configured external-peer address book: agents/peers.json is a JSON
/// array. Unknown fields and invalid rows fail closed rather than being erased
/// by a subsequent mutation. All mutations share the canonical sidecar lock.
public struct AgentPeerStore: Sendable {
    public static let maximumContacts = 128
    public static let maximumNameLength = 120
    public static let maximumEndpointLength = 2048
    public static let maximumConfigurationBytes = 1_048_576
    public let fileURL: URL

    public init(dataRoot: URL) {
        fileURL = dataRoot.appendingPathComponent("agents/peers.json")
    }

    public func list() throws -> [AgentPeerContact] {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) { try read() }
    }

    @discardableResult public func upsert(_ contact: AgentPeerContact) throws -> AgentPeerContact {
        try Self.validate(contact)
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            // The person's elevation grant is NOT configuration a caller may
            // carry in a contact body — `setElevation` is its only writer, so
            // an agent-driven configure can neither grant it nor silently
            // clear one the person already gave.
            var merged = contact
            if let index = peers.firstIndex(where: { $0.id == contact.id }) {
                merged.allowElevation = peers[index].allowElevation
                peers[index] = merged
            } else {
                merged.allowElevation = nil
                guard peers.count < Self.maximumContacts else { throw AgentPeerStoreError.tooManyContacts }
                peers.append(merged)
            }
            try write(peers)
            return merged
        }
    }

    /// The ONLY writer of the person's per-peer elevation grant. Callable from
    /// Trust Center; never from a chat tool.
    @discardableResult public func setElevation(peerID: String, allowed: Bool) throws -> AgentPeerContact? {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return nil }
            peers[index].allowElevation = allowed ? true : nil
            try write(peers)
            return peers[index]
        }
    }

    /// Discovery cannot replace an existing identity or its credentials. Exact
    /// routes reuse identity under the store lock; desktop labels scope routes.
    @discardableResult public func insertDiscovered(_ contact: AgentPeerContact) throws -> AgentPeerContact {
        try Self.validate(contact)
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            let matches = peers.filter { Self.sameRoute($0, contact) }
            guard matches.count <= 1 else { throw AgentPeerStoreError.invalidConfiguration }
            if let existing = matches.first { return existing }
            guard !peers.contains(where: { $0.id == contact.id }) else { throw AgentPeerStoreError.invalidContact }
            guard peers.count < Self.maximumContacts else { throw AgentPeerStoreError.tooManyContacts }
            // A discovered peer is never elevated. See `setElevation`.
            var fresh = contact
            fresh.allowElevation = nil
            peers.append(fresh)
            try write(peers)
            return fresh
        }
    }

    public static func sameRoute(_ lhs: AgentPeerContact, _ rhs: AgentPeerContact) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.transport == rhs.transport &&
            (lhs.transport != .desktop || lhs.conversationLabel == rhs.conversationLabel)
    }

    public static func desktopBundleID(_ endpoint: URL) -> String? {
        guard let host = endpoint.host, endpoint.absoluteString == "app://" + host,
              host.utf8.count <= 255 else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }

    @discardableResult public func remove(_ id: String) throws -> Bool {
        guard Self.validID(id) else { throw AgentPeerStoreError.invalidContact }
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == id }) else { return false }
            peers.remove(at: index)
            try write(peers)
            return true
        }
    }

    public static func validate(_ contact: AgentPeerContact) throws {
        guard validID(contact.id), !contact.name.isEmpty,
              contact.name.count <= maximumNameLength,
              contact.name.utf8.count <= maximumNameLength * 4,
              contact.name == contact.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !contact.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AgentPeerStoreError.invalidContact }
        if contact.transport == .desktop {
            guard desktopBundleID(contact.endpoint) != nil else { throw AgentPeerStoreError.invalidEndpoint }
            guard contact.credentialKey == nil else { throw AgentPeerStoreError.invalidCredentialReference }
            if let label = contact.conversationLabel {
                guard !label.isEmpty, label.utf8.count <= 480,
                      label == label.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw AgentPeerStoreError.invalidContact
                }
            }
            return
        }
        guard contact.conversationLabel == nil else { throw AgentPeerStoreError.invalidContact }
        guard contact.endpoint.absoluteString.utf8.count <= maximumEndpointLength,
              let parts = URLComponents(url: contact.endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw AgentPeerStoreError.invalidEndpoint }
        if let key = contact.credentialKey, key != AgentPeerContact.credentialKey(for: contact.id) {
            throw AgentPeerStoreError.invalidCredentialReference
        }
    }

    private static func validID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw AgentPeerStoreError.unreadableConfiguration }
        } else {
            guard errno == ENOENT else { throw AgentPeerStoreError.unreadableConfiguration }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard chmod(directory.path, 0o700) == 0 else { throw AgentPeerStoreError.unreadableConfiguration }
    }

    private func read() throws -> [AgentPeerContact] {
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw AgentPeerStoreError.unreadableConfiguration
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentPeerStoreError.unreadableConfiguration
        }
        guard info.st_size <= Self.maximumConfigurationBytes else { throw AgentPeerStoreError.configurationTooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, Self.maximumConfigurationBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumConfigurationBytes else { throw AgentPeerStoreError.configurationTooLarge }
        }
        do {
            let allowed = Set(["id", "name", "endpoint", "transport", "credentialKey", "conversationLabel", "allowElevation"])
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  rows.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else {
                throw AgentPeerStoreError.invalidConfiguration
            }
            let peers = try JSONDecoder().decode([AgentPeerContact].self, from: data)
            guard peers.count <= Self.maximumContacts, Set(peers.map(\.id)).count == peers.count else {
                throw AgentPeerStoreError.invalidConfiguration
            }
            for peer in peers { try Self.validate(peer) }
            return peers
        } catch { throw AgentPeerStoreError.invalidConfiguration }
    }

    private func write(_ peers: [AgentPeerContact]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(peers)
        guard data.count <= Self.maximumConfigurationBytes else { throw AgentPeerStoreError.configurationTooLarge }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
    }
}
