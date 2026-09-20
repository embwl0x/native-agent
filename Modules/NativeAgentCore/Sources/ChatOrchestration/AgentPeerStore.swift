import Darwin
import Foundation
import PersistenceCore

public enum AgentPeerTransport: String, Codable, Sendable {
    case a2a
    case nativeAgent
    case desktop
    /// An agent host ON THIS MAC that this app set itself up inside: that
    /// host's own MCP configuration now carries one entry running
    /// `nativeagent-link mcp` with this connection's key in it. The host CALLS
    /// IN, so the endpoint is an identity (`mcp://<host row id>`), never an
    /// address to send to.
    case mcpHost
    case acp
    case grokBot
}

/// Historical evidence, not a promise that the route is currently available.
public struct AgentRoundTripProof: Codable, Sendable, Equatable {
    public let at: String
    public let endpoint: URL
    public let executable: String?
    public let version: String?
    public let workspace: String
    public let credentialKey: String?
}

struct AgentConnectionProbe: Codable, Sendable, Equatable {
    let nonce: String
    let endpoint: URL
    let credentialKey: String?
    let expiresAt: Date
    var receivedAt: String?
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
    /// Exact resolved executable disclosed and approved when connecting this named host.
    public var approvedExecutablePath: String? = nil
    /// Desktop target data only, never a script or verified conversation ID.
    public var conversationLabel: String?
    /// Explicitly disclosed ACP starting directory; absent on older contacts.
    public var acpWorkingDirectory: String?
    /// Identity receipt for approvedExecutablePath, never a second launch binding.
    public var acpExecutable: AgentACPExecutable?
    /// The explicitly selected folder for a workspace-scoped host connection.
    public var hostWorkspace: String?
    /// Nonsecret setup state. The routine URL and key live only in Keychain.
    public var grokSetup: String?
    public var grokConversation: String?
    public var grokBootstrapConfirmed: Bool?
    /// THE PERSON'S OWN GRANT, and the only thing that can raise an inbound
    /// peer turn off the restricted `agent-bridge` surface. Absent means no —
    /// the default for every peer, including one this agent configured or
    /// discovered for itself. Optional rather than `Bool = false` so an
    /// existing peers.json round-trips byte-identically until the person sets
    /// it in Trust Center.
    public var allowElevation: Bool?
    /// Fail-closed reading of the grant above.
    public var elevationAllowed: Bool { allowElevation == true }
    /// THE WHOLE PROOF, and the minimum that can carry it: when a real message
    /// last came IN through this connection, and when one last went OUT. Two
    /// timestamps, written only by `recordProof`. Configuration is not
    /// evidence — an entry that exists proves it was written, and nothing
    /// else. Optional so an existing peers.json round-trips byte-identically.
    public var provenInboundAt: String?
    public var provenOutboundAt: String?
    public var roundTripProof: AgentRoundTripProof?
    public var mcpReturnProof: AgentRoundTripProof?
    var connectionProbe: AgentConnectionProbe?
    public var unavailableAt: String?

    public var isReady: Bool {
        if transport == .acp && !canStartTurn { return false }
        guard let proof = roundTripProof ?? mcpReturnProof else { return false }
        return unavailableAt == nil && proof.endpoint == endpoint && proof.credentialKey == credentialKey
    }

    public init(id: String = UUID().uuidString.lowercased(), name: String, endpoint: URL,
                transport: AgentPeerTransport, credentialKey: String? = nil, conversationLabel: String? = nil,
                allowElevation: Bool? = nil, provenInboundAt: String? = nil, provenOutboundAt: String? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.transport = transport
        self.credentialKey = credentialKey
        self.conversationLabel = conversationLabel
        self.allowElevation = allowElevation
        self.provenInboundAt = provenInboundAt
        self.provenOutboundAt = provenOutboundAt
    }

    public static func credentialKey(for id: String) -> String { "agent-peer:\(id)" }

    /// HONEST STATES, in the words the agent can act on without knowing what a
    /// transport is. A handshake, an entry, a saved endpoint: all of them are
    /// `setUp`. Only a reply that actually arrived makes a contact `connected`.
    public var state: AgentPeerContactState {
        // Inbound credentials prove a contact's return path. Local command
        // and ACP routes still need their own completed round-trip proof.
        let inboundContact = transport != .acp && transport != .desktop
            && credentialKey == Self.credentialKey(for: id) && provenInboundAt != nil
        if unavailableAt == nil && (isReady || inboundContact) { return .connected }
        if transport == .desktop { return .sendOnly }
        return .setUp
    }

    public var approvedACPExecutable: AgentACPExecutable? {
        guard let receipt = acpExecutable, receipt.path == approvedExecutablePath else { return nil }
        return receipt
    }

    public var canStartTurn: Bool {
        if transport == .acp { return approvedACPExecutable?.isCurrent == true }
        if transport == .mcpHost {
            return AgentPeerStore.hostRowID(endpoint).flatMap { AgentHostDirectory.row(named: $0)?.commandLine } != nil
        }
        return true
    }
    public var canAnswerBack: Bool { transport != .desktop }
}

/// The four words `agent_contacts`, `agent_connect`, `agent_message` and
/// `agent_read` all speak. `listed` belongs to a known-agent row with no
/// contact behind it yet, so it has no contact to hang off.
public enum AgentPeerContactState: String, Sendable {
    case listed
    case setUp = "set up"
    case connected
    case unavailable
    case sendOnly = "can send; replies aren't connected"

    public var detail: String {
        switch self {
        case .listed:
            return "Known, nothing set up yet."
        case .setUp:
            return "The entry is written, but nothing has crossed this connection yet. Set up is not connected."
        case .connected:
            return "A real message has arrived through this connection, or a message and reply have crossed it."
        case .unavailable:
            return AgentPeerCredentials.unavailableDetail
        case .sendOnly:
            return "Messages go out; there is no route back. A reply arrives, if it arrives, as an ordinary inbound message."
        }
    }
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

    func namesMentioned(in text: String) throws -> [String] {
        try list().map(\.name).filter { name in
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name)
                + "(?![\\p{L}\\p{N}_])"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    @discardableResult public func upsert(_ contact: AgentPeerContact, resetProof: Bool = false) throws -> AgentPeerContact {
        try Self.validate(contact)
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            // The person's elevation grant is NOT configuration a caller may
            // carry in a contact body — `setElevation` is its only writer, so
            // an agent-driven configure can neither grant it nor silently
            // clear one the person already gave.
            // The proof timestamps are evidence, not configuration, for the
            // same reason: `recordProof` is their only writer, so a configure
            // cannot claim a round trip. An explicit reconnect retires proof
            // from the prior consent under this same lock.
            var merged = contact
            if let index = peers.firstIndex(where: { $0.id == contact.id }) {
                // A key belongs to the route it was minted for. Changing a
                // workspace or endpoint requires a new contact and key.
                if peers[index].credentialKey != nil,
                   (!Self.sameRoute(peers[index], contact) || peers[index].credentialKey != contact.credentialKey) {
                    throw AgentPeerStoreError.invalidContact
                }
                merged.allowElevation = peers[index].allowElevation
                merged.provenInboundAt = resetProof ? nil : peers[index].provenInboundAt
                merged.provenOutboundAt = resetProof ? nil : peers[index].provenOutboundAt
                merged.roundTripProof = resetProof ? nil : peers[index].roundTripProof
                merged.mcpReturnProof = resetProof ? nil : peers[index].mcpReturnProof
                merged.connectionProbe = resetProof ? nil : peers[index].connectionProbe
                merged.unavailableAt = resetProof ? nil : peers[index].unavailableAt
                peers[index] = merged
            } else {
                merged.allowElevation = nil
                merged.provenInboundAt = nil
                merged.provenOutboundAt = nil
                merged.roundTripProof = nil
                merged.mcpReturnProof = nil
                merged.connectionProbe = nil
                merged.unavailableAt = nil
                guard peers.count < Self.maximumContacts else { throw AgentPeerStoreError.tooManyContacts }
                peers.append(merged)
            }
            try write(peers)
            return merged
        }
    }

    /// Serializes Grok setup/import/revocation, including Keychain effects,
    /// against this contact's removal. An old card cannot recreate a contact.
    @discardableResult public func updateGrok(_ id: String, allowDisconnected: Bool = false,
                                             _ edit: (inout AgentPeerContact) throws -> Void) throws -> AgentPeerContact {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == id && $0.transport == .grokBot }),
                  allowDisconnected || peers[index].grokSetup != "disconnected" else { throw AgentPeerStoreError.invalidContact }
            try edit(&peers[index])
            try Self.validate(peers[index])
            try write(peers)
            return peers[index]
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

    /// THE ONLY WRITER OF PROOF. A round trip is recorded where it actually
    /// happens — an inbound request that carried this connection's key, an
    /// outbound message that really left — and nowhere else. Unknown ids and
    /// unreadable configuration are silent: evidence that cannot be written is
    /// never an error the caller can turn into a claim.
    public func recordProof(peerID: String, inbound: Bool = false, outbound: Bool = false,
                            message: String? = nil) {
        guard inbound || outbound, Self.validID(peerID) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? prepareDirectory()
        try? CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
            if inbound { peers[index].provenInboundAt = stamp }
            if inbound, var probe = peers[index].connectionProbe,
               probe.receivedAt == nil, probe.expiresAt > Date(),
               probe.endpoint == peers[index].endpoint, probe.credentialKey == peers[index].credentialKey,
               message?.trimmingCharacters(in: .whitespacesAndNewlines) == probe.nonce {
                probe.receivedAt = stamp
                peers[index].connectionProbe = probe
            }
            if outbound { peers[index].provenOutboundAt = stamp }
            try write(peers)
        }
    }

    /// One outstanding challenge per contact, bound to its current return route.
    func beginConnectionProbe(peerID: String, timeout: TimeInterval) throws -> String {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID && $0.transport == .mcpHost }) else {
                throw AgentPeerStoreError.invalidContact
            }
            let nonce = AgentHostDirectory.probeToken + ":" + UUID().uuidString.lowercased()
            peers[index].connectionProbe = AgentConnectionProbe(nonce: nonce, endpoint: peers[index].endpoint,
                credentialKey: peers[index].credentialKey, expiresAt: Date().addingTimeInterval(timeout))
            try write(peers)
            return nonce
        }
    }

    /// Consume this exact challenge once; unrelated, stale and replayed traffic cannot prove it.
    func finishConnectionProbe(peerID: String, nonce: String, ran: Bool, workspace: String) -> Bool {
        (try? CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }),
                  let probe = peers[index].connectionProbe, probe.nonce == nonce else { return false }
            peers[index].connectionProbe = nil
            let peer = peers[index]
            let arrived = ran && probe.receivedAt != nil && probe.endpoint == peer.endpoint
                && probe.credentialKey == peer.credentialKey
            if arrived, let at = probe.receivedAt {
                peers[index].mcpReturnProof = AgentRoundTripProof(at: at, endpoint: peer.endpoint,
                    executable: nil, version: nil, workspace: workspace, credentialKey: peer.credentialKey)
                peers[index].unavailableAt = nil
            }
            try write(peers)
            return arrived
        }) ?? false
    }

    /// Called only by a transport after a validated response to its request.
    /// Inbound traffic alone never writes round-trip evidence.
    public func recordRoundTrip(peerID: String, executable: String? = nil,
                                version: String? = nil, workspace: String) {
        try? prepareDirectory()
        try? CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
            let peer = peers[index]
            let proof = AgentRoundTripProof(
                at: ISO8601DateFormatter().string(from: Date()), endpoint: peer.endpoint,
                executable: executable, version: version, workspace: workspace, credentialKey: peer.credentialKey)
            peers[index].roundTripProof = proof
            peers[index].unavailableAt = nil
            try write(peers)
        }
    }

    public func recordUnavailable(peerID: String) {
        try? prepareDirectory()
        try? CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
            peers[index].unavailableAt = ISO8601DateFormatter().string(from: Date())
            try write(peers)
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
            fresh.provenInboundAt = nil
            fresh.provenOutboundAt = nil
            fresh.roundTripProof = nil
            fresh.mcpReturnProof = nil
            fresh.connectionProbe = nil
            fresh.unavailableAt = nil
            peers.append(fresh)
            try write(peers)
            return fresh
        }
    }

    public static func sameRoute(_ lhs: AgentPeerContact, _ rhs: AgentPeerContact) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.transport == rhs.transport &&
            (lhs.transport != .desktop || lhs.conversationLabel == rhs.conversationLabel) &&
            (lhs.transport != .mcpHost || lhs.hostWorkspace == rhs.hostWorkspace)
    }

    /// The known-agent row id behind an `mcp://<id>` endpoint, or nil. A row
    /// this build does not have is not an identity this store will accept.
    public static func hostRowID(_ endpoint: URL) -> String? {
        guard let host = endpoint.host, ["mcp://" + host, "acp://" + host, "grok://" + host].contains(endpoint.absoluteString) else { return nil }
        // Preserve saved ACP identities from before the shared directory landed,
        // while resolving them to its one canonical row.
        let aliases = ["gemini": "gemini-cli", "cursor-agent": "cursor-cli"]
        let id = endpoint.scheme == "acp" ? aliases[host] ?? host : host
        guard AgentHostDirectory.rows.contains(where: { $0.id == id }) else { return nil }
        return id
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
        if contact.transport == .grokBot {
            guard contact.endpoint.absoluteString == "grok://grok-bot",
                  contact.credentialKey == AgentPeerContact.credentialKey(for: contact.id),
                  ["creating", "secure-paste", "set up", "disconnected"].contains(contact.grokSetup ?? "") else {
                throw AgentPeerStoreError.invalidContact
            }
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
        if contact.transport == .mcpHost || contact.transport == .acp {
            // An identity, not an address: nothing here is ever dialled, and
            // the key this contact owns is the only thing that resolves an
            // inbound request to it.
            guard let id = hostRowID(contact.endpoint),
                  let row = AgentHostDirectory.rows.first(where: { $0.id == id }) else { throw AgentPeerStoreError.invalidEndpoint }
            if contact.transport == .acp {
                guard contact.endpoint.scheme == "acp", row.acp != nil else { throw AgentPeerStoreError.invalidEndpoint }
            } else if contact.endpoint.scheme != "mcp" { throw AgentPeerStoreError.invalidEndpoint }
            if row.requiresWorkspace {
                guard let folder = contact.hostWorkspace, folder.hasPrefix("/"),
                      !folder.contains("\0"), folder.utf8.count <= 4096 else { throw AgentPeerStoreError.invalidEndpoint }
            } else if contact.hostWorkspace != nil { throw AgentPeerStoreError.invalidEndpoint }
            if let key = contact.credentialKey, key != AgentPeerContact.credentialKey(for: contact.id) {
                throw AgentPeerStoreError.invalidCredentialReference
            }
            return
        }
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
            let allowed = Set(["id", "name", "endpoint", "transport", "credentialKey", "conversationLabel",
                               "approvedExecutablePath", "acpWorkingDirectory", "acpExecutable",
                                "hostWorkspace", "grokSetup", "grokConversation", "grokBootstrapConfirmed",
                                "allowElevation", "provenInboundAt", "provenOutboundAt",
                                "roundTripProof", "mcpReturnProof", "connectionProbe", "unavailableAt"])
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
