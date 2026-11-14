import AgentLinkTransport
import AgentWorkspace
import Darwin
import Dispatch
import Foundation
import Experiences
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `AgentPeerStore.swift` | `isReady`, `AgentContactHealth`, `list` |

// The checked peer array is private contact authority; backup, export and phone projections must respect its privacy map.

public typealias AgentPeerTransport = NativeAgentCore.AgentPeerTransport

/// Round-trip history cannot promise current route availability.
public struct AgentRoundTripProof: Codable, Sendable, Equatable {
    public let at: String
    public let endpoint: URL
    public let executable: String?
    public let version: String?
    public let workspace: String
    public let credentialKey: String?
    public var appVersion: String?
    /// Retain recipe digest as well as version to detect hand edits that do not bump versions.
    public var recipeVersion: Int?
    public var recipeDigest: String?
}

struct AgentConnectionProbe: Codable, Sendable, Equatable {
    let nonce: String
    let endpoint: URL
    let credentialKey: String?
    let expiresAt: Date
    var receivedAt: String?
}

/// A contact's last read of the table: when, and what it read (the Desk, or one piece by its Make ref and title).
public struct AgentTableRead: Codable, Sendable, Equatable {
    public let at: Date
    /// Both absent for a read of the Desk.
    public let piece: String?
    public let title: String?

    public init(at: Date, piece: String?, title: String?) { (self.at, self.piece, self.title) = (at, piece, title) }

    /// "read my Desk today at 3:04 PM": `desk` names the Desk as the reader of these words calls it.
    public func words(desk: String) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(at) ? "today" : calendar.isDateInYesterday(at) ? "yesterday"
            : "on " + at.formatted(.dateTime.month(.abbreviated).day())
        return "read " + (title ?? piece ?? desk) + " " + day + " at " + at.formatted(date: .omitted, time: .shortened)
    }
}

/// Configuration only: neither presence, trust, nor permission to send a message.
public struct AgentPeerContact: Codable, Sendable, Equatable {
    var appBundleIDs: [String] {
        if let bundle = AgentPeerStore.desktopBundleID(endpoint) { return [bundle] }
        guard [.grokBot, .desktopChat, .mcpHost].contains(transport) else { return [] }
        return AgentPeerStore.hostRowID(endpoint).flatMap { AgentHostDirectory.row(named: $0)?.bundleIDs } ?? []
    }

    /// Host recipes use the host ID; A2A contacts own their own card recipe.
    public var recipeID: String? { transport == .a2a ? id : AgentPeerStore.hostRowID(endpoint) }

    /// Capture the send’s recipe and app version so later changes invalidate proof.
    func stampVersions(_ proof: inout AgentRoundTripProof, recipe: AgentRecipeStore.Recipe?) throws {
        if let recipe {
            proof.recipeVersion = recipe.recipeVersion
            proof.recipeDigest = try recipe.hostDigest
        }
        guard let app = appBundleIDs.compactMap(AgentHostRow.applicationURL).first else { return }
        proof.appVersion = Self.appVersion(at: app.path)
    }

    static func appVersion(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
    /// Stable, canonical lowercase UUID. Names are presentation, never identity.
    public var id: String
    public var name: String
    /// The who this contact is a door of: another contact's id, written only as an explicit association. Absent: this contact is its own who.
    public var who: String?
    /// Aliases locate this contact only; they cannot establish another contact’s identity.
    public var handles: [String]?
    public var endpoint: URL
    public var transport: AgentPeerTransport
    /// An authored ability changes reachability only; contact identity, trust and proof remain with this owner.
    public var ability: String?
    /// Reference only. Credential values must never enter this document.
    public var credentialKey: String?
    /// Launch only the exact executable disclosed and approved at connection.
    public var approvedExecutablePath: String? = nil
    /// Desktop target data only, never a script or verified conversation ID.
    public var conversationLabel: String?
    /// ACP starting directories must be explicitly disclosed.
    public var acpWorkingDirectory: String?
    /// Identity receipt for approvedExecutablePath, never a second launch binding.
    public var acpExecutable: AgentACPExecutable?
    /// Workspace-scoped connections require an explicitly selected folder.
    public var hostWorkspace: String?
    /// Nonsecret setup state. The routine URL and key live only in Keychain.
    public var grokSetup: String?
    public var grokConversation: String?
    /// An unconfirmed submission may already have happened; reconnect must not resend it.
    public var grokBootstrapConfirmed: Bool?
    /// Only the person’s grant may elevate an inbound peer turn; absence is refusal, including self-discovered peers. Keep the optional field absent until
    /// explicitly set so untouched persisted rows remain byte-identical.
    public var allowElevation: Bool?
    public var elevationAllowed: Bool { allowElevation == true }
    /// The person brought this contact to the table: it reads the Desk and the pieces laid on it through its own key, and changes nothing. Absent until
    /// set, like the grant above; only `setReadsDesk` writes it.
    public var readsDesk: Bool?
    /// Its last read while at the table, written by `recordTableRead` before the words go back; absent off the table, so taking the contact away leaves
    /// the record as an older build wrote it.
    public var lastRead: AgentTableRead?
    /// The table's one door is the MCP tools a host (`nativeagent-link mcp`) or an ACP session calls with this contact's own key; messaging-only
    /// routes, Grok Bot's reply-scoped key and desktop chats have none.
    public var canReadTable: Bool { [.mcpHost, .acp].contains(transport) && credentialKey == Self.credentialKey(for: id) }

    /// Credential authority owns whether the person’s grant can take effect; unavailable keys cannot imply permission.
    public func elevationUnavailable(peers: [AgentPeerContact], availability: Result<Bool, ToolFailureError>? = nil) -> ToolFailureError? {
        let available: Bool
        switch availability ?? AgentPeerCredentials.availability(self, peers: peers) {
        case .success(let value): available = value
        case .failure(let failure): return failure
        }
        if credentialKey == Self.credentialKey(for: id),
           available { return nil }
        // Only settings-host reconnects mint keys; other routes require the peer’s own credential.
        let repairable = AgentPeerStore.hostRowID(endpoint).flatMap(AgentHostDirectory.row(named:))
            .map { $0.settingsSupported || $0.format == .shellEnvironment } == true && transport == .mcpHost
        return ToolFailureError(AgentPeerCredentials.unavailableDetail, effects: .none,
            owner: "Keychain peer:" + id,
            nextCall: repairable ? ToolFailureError.call("app", ["action": .string("agent.connect"),
                "args": .object(["name": .string("peer:" + id)])]) : nil,
            tap: repairable ? nil : "Agents > \(name) > connect again with the key \(name) gives you")
    }

    /// Only recordProof may stamp actual inbound or outbound messages; configuration alone proves no traffic. Optional evidence preserves untouched persisted
    /// rows byte-for-byte.
    public var provenInboundAt: String?
    public var provenOutboundAt: String?
    public var roundTripProof: AgentRoundTripProof?
    public var mcpReturnProof: AgentRoundTripProof?
    var connectionProbe: AgentConnectionProbe?
    public var unavailableAt: String?

    /// This owner checks route proof and startability; contact health owns version and digest freshness.
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

    /// Setup and handshake evidence prove configuration only; connection requires actual inbound traffic or a round trip.
    public var state: AgentPeerContactState {
        // Inbound credentials prove a contact's return path. ACP routes still need their own completed round-trip proof.
        let inboundContact = transport != .acp && transport != .desktop
            && credentialKey == Self.credentialKey(for: id) && provenInboundAt != nil
        if unavailableAt == nil && (isReady || inboundContact) { return .connected }
        if transport == .desktop { return canAnswerBack ? .setUp : .sendOnly }
        return .setUp
    }

    public var approvedACPExecutable: AgentACPExecutable? {
        guard let receipt = acpExecutable, receipt.path == approvedExecutablePath else { return nil }
        return receipt
    }

    /// Hash the approved program immediately before each Full Mac launch; a changed or missing path is not approved.
    public var verifiedExecutablePath: String? {
        guard let receipt = acpExecutable, (try? receipt.verify()) != nil else { return nil }
        return receipt.path
    }

    public var canStartTurn: Bool {
        if ChatGPTDotIPCTransport.owns(self) { return ChatGPTDotIPCTransport.available }
        if transport == .acp { return approvedACPExecutable?.isCurrent == true }
        if transport == .mcpHost {
            return AgentPeerStore.hostRowID(endpoint).flatMap { AgentHostDirectory.row(named: $0)?.commandLine } != nil
        }
        return true
    }
    /// Desktop answers must be read from the same chat that received the send.
    public var canAnswerBack: Bool { transport != .desktop || readsReplyInWindow }
    public var readsReplyInWindow: Bool { transport == .desktop && AgentPeerStore.desktopBundleID(endpoint) == GrokBotRoute.bundleID }
}

/// Listed hosts have no contact yet; shared contact projections cannot invent one.
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
            return "The entry is written, but no round trip is proven on it yet. Set up is not connected. last_exchange shows any message that crossed it."
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
        case .invalidContact: return "Contact identity, name or conversation settings are invalid."
        case .invalidEndpoint: return """
            Endpoint does not match this contact's transport. Network routes require HTTPS or explicit loopback HTTP without credentials, query or \
            fragment; desktop routes require an exact app bundle identifier; recipe routes require a valid host identity and any configured \
            starting folder.
            """
        case .invalidCredentialReference: return "Credential reference must belong to this contact's dedicated namespace."
        case .invalidConfiguration: return "Saved contacts are invalid; existing bytes were preserved."
        case .tooManyContacts: return "Contact limit reached (128)."
        case .configurationTooLarge: return "Saved contacts exceed 1048576 bytes."
        case .unreadableConfiguration: return "Saved contacts cannot be read safely; existing bytes were preserved."
        }
    }

    func failure(file: URL? = nil) -> ToolFailureError {
        let read = ToolFailureError.call("app", ["action": .string("agent.contacts")])
        var instruction: String
        switch self {
        case .tooManyContacts:
            instruction = "Read contacts, then disconnect an unused contact with agent.connect using its name and disconnect:true."
        case .invalidConfiguration, .configurationTooLarge, .unreadableConfiguration:
            instruction = "Ask the person to repair the contact array and file access while preserving every saved contact and the original bytes."
        case .invalidContact:
            instruction = "Read contacts and correct the invalid ID, name, route or conversation label; preserve the saved identity."
        case .invalidEndpoint:
            instruction = "Use the endpoint shape required by this contact's transport; read contacts for its saved route."
        case .invalidCredentialReference:
            instruction = "Read contacts, then reconnect the affected contact with its own dedicated credential."
        }
        let damaged = [.invalidConfiguration, .configurationTooLarge, .unreadableConfiguration].contains(self)
        if damaged, let file {
            instruction = ToolFailureError.fileRepairInstruction(file,
                shape: """
                    The file must be a JSON array of at most 128 valid AgentPeerContact records, at most 1048576 bytes; preserve IDs and credential \
                    references.
                    """)
        }
        let code = switch self {
        case .invalidContact: "agent_contact_invalid"
        case .invalidEndpoint: "agent_endpoint_invalid"
        case .invalidCredentialReference: "agent_credential_reference_invalid"
        case .invalidConfiguration: "agent_configuration_invalid"
        case .tooManyContacts: "agent_contact_limit"
        case .configurationTooLarge: "agent_configuration_too_large"
        case .unreadableConfiguration: "agent_configuration_unreadable"
        }
        return ToolFailureError(errorDescription!, effects: file == nil ? .none : .unknown, owner: file?.path ?? "Agent contacts",
            nextCall: damaged ? nil : read, code: code, instruction: instruction, recovery: damaged ? .repair : .inspect)
    }
}

/// Unreadable or invalid peer rows fail closed instead of being erased by mutation. All mutations use the canonical sidecar lock and preserve the store’s
/// documented privacy boundaries.
public struct AgentPeerStore: Sendable {
    /// A contact's identity, grant or credential binding changed; traffic timestamps do not change memory attribution.
    public static let trustDidChange = Notification.Name("AgentPeerStore.trustDidChange")
    public static let maximumContacts = 128
    public static let maximumNameLength = 120
    public static let maximumEndpointLength = 2048
    public static let maximumConfigurationBytes = 1_048_576
    public let fileURL: URL

    public init(dataRoot: URL) {
        fileURL = dataRoot.appendingPathComponent("agents/peers.json")
    }

    /// Enforce private directory permissions before locked reads.
    public func list() throws -> [AgentPeerContact] {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) { try read() }
    }

    /// Contact names and handles resolve through the saved address book, independently of reachability.
    public func references(named name: String) throws -> Set<String> {
        Set(try list().filter {
            name.caseInsensitiveCompare("peer:" + $0.id) == .orderedSame || $0.id == name.lowercased()
                || $0.name.caseInsensitiveCompare(name) == .orderedSame
                || ($0.handles ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }.map { peer in peer.handles?.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? "peer:" + peer.id })
    }

    /// Saved contacts for turn orientation; reachability never removes a contact.
    package func contactSummaries(turn: Turn?) throws -> [String] {
        let start = DispatchTime.now().uptimeNanoseconds
        let peers = try read()
        let health = AgentLocalHealth.read(fileURL.deletingLastPathComponent().deletingLastPathComponent())
        // Availability checks each token against every configured contact. Read each key once for this summary, including missing/unreadable results; the next
        // summary and every effect still read afresh.
        var credentials: [String: Result<String?, any Error>] = [:]
        func credential(_ id: String) throws -> String? {
            if let kept = credentials[id] { return try kept.get() }
            let result = Result { try AgentPeerCredentials.read(peerID: id) }
            credentials[id] = result
            return try result.get()
        }
        let summaries = peers.map { peer in
            let notes = (AgentContactHealth.checkIn(peer) == nil ? ""
                : "; messages wait for their next check-in, so sending does not interrupt them")
                + (peer.readsDesk == true ? "; at your table: it reads your Desk and its pieces itself, and asks you to change anything" : "")
                + (peer.lastRead.map { "; last " + $0.words(desk: "your Desk") } ?? "")
            let observed = health["peer:" + peer.id]
            let available: Bool
            switch AgentPeerCredentials.availability(peer, peers: peers, readCredential: credential) {
            case .success(let value): available = value
            case .failure(let failure):
                return """
                    \(peer.name) (reachability: unavailable; credential error: \(failure.localizedDescription); trusted: \
                    \(peer.elevationAllowed ? "on" : "off")\(notes))
                    """
            }
            let unavailable = peer.grokSetup == "disconnected" || peer.unavailableAt != nil
                || !available
            let reachability = unavailable ? "unavailable"
                : observed?.current == true ? observed!.replyStatus.replacingOccurrences(of: "_", with: " ") : "not checked"
            return "\(peer.name) (reachability: \(reachability); trusted: \(peer.elevationAllowed ? "on" : "off")\(notes))"
        }.sorted()
        TurnTraceBus.fireFromContext(kind: "context.contacts.summary", payload: .object([
            "elapsedMs": .int(Int64((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)),
            "contactCount": .int(Int64(peers.count)), "credentialReads": .int(Int64(credentials.count))
        ]), turn: turn)
        return summaries
    }

    public func rename(_ agent: String, name: String) throws -> JSONValue {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            let owners = Set(peers.filter {
                "peer:" + $0.id == agent || $0.name.caseInsensitiveCompare(agent) == .orderedSame
                    || ($0.handles ?? []).contains { $0.caseInsensitiveCompare(agent) == .orderedSame }
            }.map { peer in peers.first { $0.id == peer.who }?.id ?? peer.id })
            guard owners.count == 1, let index = peers.firstIndex(where: { owners.contains($0.id) }) else {
                throw ToolFailureError("Choose one saved agent from agent.contacts to rename.", argumentPath: "agent", effects: .none)
            }
            peers[index].name = name
            try Self.validate(peers[index])
            try write(peers)
            return .object(["status": .string("renamed"), "agent": .string("peer:" + peers[index].id), "name": .string(name)])
        }
    }

    @discardableResult public func upsert(_ contact: AgentPeerContact, resetProof: Bool = false) throws -> AgentPeerContact {
        try Self.validate(contact)
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            // Only setElevation and setReadsDesk may change the person’s levers, and only recordProof may stamp traffic evidence. Configure cannot grant,
            // erase grants or manufacture proof; explicit reconnect retires prior consent proof under the same lock.
            var merged = contact
            if let index = peers.firstIndex(where: { $0.id == contact.id }) {
                // A key belongs to the route it was minted for. Changing a workspace or endpoint requires a new contact and key.
                if peers[index].credentialKey != nil,
                   (!Self.sameRoute(peers[index], contact) || peers[index].credentialKey != contact.credentialKey) {
                    throw AgentPeerStoreError.invalidContact.failure(file: fileURL)
                }
                merged.allowElevation = peers[index].allowElevation
                merged.readsDesk = peers[index].readsDesk
                merged.lastRead = peers[index].lastRead
                merged.ability = peers[index].ability
                merged.provenInboundAt = resetProof ? nil : peers[index].provenInboundAt
                merged.provenOutboundAt = resetProof ? nil : peers[index].provenOutboundAt
                merged.roundTripProof = resetProof ? nil : peers[index].roundTripProof
                merged.mcpReturnProof = resetProof ? nil : peers[index].mcpReturnProof
                merged.connectionProbe = resetProof ? nil : peers[index].connectionProbe
                merged.unavailableAt = resetProof ? nil : peers[index].unavailableAt
                peers[index] = merged
            } else {
                merged.allowElevation = nil
                merged.readsDesk = nil
                merged.lastRead = nil
                merged.ability = nil
                merged.provenInboundAt = nil
                merged.provenOutboundAt = nil
                merged.roundTripProof = nil
                merged.mcpReturnProof = nil
                merged.connectionProbe = nil
                merged.unavailableAt = nil
                guard peers.count < Self.maximumContacts else { throw AgentPeerStoreError.tooManyContacts.failure(file: fileURL) }
                peers.append(merged)
            }
            try write(peers)
            return merged
        }
    }

    /// Serialize setup and credential effects with removal so stale cards cannot recreate contacts.
    @discardableResult public func updateGrok(_ id: String, allowDisconnected: Bool = false,
                                             _ edit: (inout AgentPeerContact) throws -> Void) throws -> AgentPeerContact {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == id && $0.transport == .grokBot }),
                  allowDisconnected || peers[index].grokSetup != "disconnected" else { throw AgentPeerStoreError.invalidContact.failure(file: fileURL) }
            try edit(&peers[index])
            try Self.validate(peers[index])
            try write(peers)
            return peers[index]
        }
    }

    /// Only Trust Center may write person-granted elevation; chat tools cannot reach this writer.
    @discardableResult public func setElevation(peerID: String, allowed: Bool) throws -> AgentPeerContact? {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return nil }
            if allowed, let failure = peers[index].elevationUnavailable(peers: peers) { throw failure }
            peers[index].allowElevation = allowed ? true : nil
            try write(peers)
            return peers[index]
        }
    }

    /// The person's table lever: only the contact's lower-only setting reaches this writer, so the agent takes a contact away from the table and
    /// bringing one asks the person. Off removes the last read with the lever.
    @discardableResult public func setReadsDesk(peerID: String, on: Bool) throws -> AgentPeerContact? {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return nil }
            peers[index].readsDesk = on ? true : nil
            if !on { peers[index].lastRead = nil }
            try write(peers)
            return peers[index]
        }
    }

    /// Records a read under the store lock, only while the contact is still at the table: false means the lever is off now (or the contact is gone),
    /// so the read's words must not go back.
    public func recordTableRead(peerID: String, _ entry: AgentTableRead) throws -> Bool {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }), peers[index].readsDesk == true, peers[index].canReadTable else {
                return false
            }
            peers[index].lastRead = entry
            try write(peers)
            return true
        }
    }

    /// Only this writer changes authored contact routes; a removed contact cannot be recreated here.
    public func route(peerID: String, ability: String?) throws -> AgentPeerContact? {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return nil }
            peers[index].ability = ability
            try write(peers)
            return peers[index]
        }
    }

    /// Reapproval holds the store lock so concurrent disconnect cannot restore a removed contact.
    @discardableResult public func approveExecutable(peerID: String, path: String, version: String? = nil) throws -> Bool {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID && [.mcpHost, .acp].contains($0.transport) }) else { return false }
            var receipt = try AgentACPExecutable.capture(path: path)
            receipt.version = version
            // ACP reapproval must use the path resolved in its own receipt.
            peers[index].approvedExecutablePath = peers[index].transport == .acp ? receipt.path : path
            peers[index].acpExecutable = receipt
            try write(peers)
            return true
        }
    }

    /// Only real transport events write proof; missing IDs or unreadable storage retain persistence debt. Never repeat completed work to recreate missing
    /// evidence.
    public func recordProof(peerID: String, inbound: Bool = false, outbound: Bool = false,
                            message: String? = nil) {
        guard inbound || outbound, Self.validID(peerID) else { return }
        let contactAt = Date()
        let stamp = NativeTimestampFormat.fractionalZulu(contactAt)
        retainEvidence(peerID: peerID, operation: "proof") {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return false }
            if inbound {
                peers[index].provenInboundAt = stamp
                if peers[index].transport != .acp && peers[index].transport != .desktop,
                   peers[index].credentialKey == AgentPeerContact.credentialKey(for: peerID),
                   let unavailable = peers[index].unavailableAt {
                    if let marked = NativeTimestampFormat.parseISO8601FractionalFirst(unavailable), marked < contactAt {
                        peers[index].unavailableAt = nil
                    }
                }
            }
            if inbound, var probe = peers[index].connectionProbe,
               probe.receivedAt == nil, probe.expiresAt > Date(),
               probe.endpoint == peers[index].endpoint, probe.credentialKey == peers[index].credentialKey,
               message?.trimmingCharacters(in: .whitespacesAndNewlines) == probe.nonce {
                probe.receivedAt = stamp
                peers[index].connectionProbe = probe
            }
            if outbound { peers[index].provenOutboundAt = stamp }
            try write(peers)
            return true
        }
    }

    /// One outstanding challenge per contact, bound to its current return route.
    package func beginConnectionProbe(peerID: String, timeout: TimeInterval) throws -> String {
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID && $0.transport == .mcpHost }) else {
                throw AgentPeerStoreError.invalidContact.failure(file: fileURL)
            }
            let nonce = AgentHostDirectory.probeToken + ":" + UUID().uuidString.lowercased()
            peers[index].connectionProbe = AgentConnectionProbe(nonce: nonce, endpoint: peers[index].endpoint,
                credentialKey: peers[index].credentialKey, expiresAt: Date().addingTimeInterval(timeout))
            try write(peers)
            return nonce
        }
    }

    /// Consume this exact challenge once; unrelated, stale and replayed traffic cannot prove it.
    package func finishConnectionProbe(peerID: String, nonce: String, ran: Bool, workspace: String,
                                       recipe: AgentRecipeStore.Recipe? = nil) throws -> Bool {
        try CredentialFileLock.withLock(fileURL) {
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
                try peer.stampVersions(&peers[index].mcpReturnProof!, recipe: recipe)
                peers[index].unavailableAt = nil
            }
            try write(peers)
            return arrived
        }
    }

    /// Only a transport-validated response proves a round trip; inbound traffic alone cannot. Capture the recipe used when the send began, not the current
    /// recipe.
    public func recordRoundTrip(peerID: String, executable: String? = nil,
                                version: String? = nil, workspace: String, recipe: AgentRecipeStore.Recipe? = nil) {
        retainEvidence(peerID: peerID, operation: "round-trip") {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return false }
            let peer = peers[index]
            var proof = AgentRoundTripProof(
                at: NativeTimestampFormat.fractionalZulu(Date()), endpoint: peer.endpoint,
                executable: executable, version: version, workspace: workspace, credentialKey: peer.credentialKey)
            try peer.stampVersions(&proof, recipe: recipe)
            peers[index].roundTripProof = proof
            peers[index].unavailableAt = nil
            try write(peers)
            return true
        }
    }

    /// Clear marks only from the requested boundary while preserving ambiguous same-second timestamps.
    public func clearUnavailable(peerID: String, since: Date) {
        retainEvidence(peerID: peerID, operation: "clear-unavailable") {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }),
                  let stamp = peers[index].unavailableAt else { return false }
            let fractional = stamp.contains(".")
            guard let marked = NativeTimestampFormat.parseISO8601FractionalFirst(stamp), marked >= since,
                  fractional || marked > since else { return false }
            peers[index].unavailableAt = nil
            try write(peers)
            return true
        }
    }

    public func recordUnavailable(peerID: String) {
        retainEvidence(peerID: peerID, operation: "unavailable") {
            var peers = try read()
            guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return false }
            peers[index].unavailableAt = NativeTimestampFormat.fractionalZulu(Date())
            try write(peers)
            return true
        }
    }

    private func retainEvidence(peerID: String, operation: String, _ mutation: () throws -> Bool) {
        do {
            try prepareDirectory()
            if try CredentialFileLock.withLock(fileURL, mutation) {
                RepairOwed.settle(fileURL.deletingLastPathComponent().deletingLastPathComponent(),
                    operation: "agent.contact.evidence:" + peerID + ":" + operation,
                    evidence: .init(source: fileURL.path, id: peerID))
            }
        } catch { recordEvidenceFailure(peerID: peerID, operation: operation, error: error) }
    }

    public func recordEvidenceFailure(peerID: String, operation: String, error: Error) {
        RepairOwed.owe(fileURL.deletingLastPathComponent().deletingLastPathComponent(),
            id: UUID().uuidString.lowercased(), kind: .act,
            operation: "agent.contact.evidence:" + peerID + ":" + operation, owner: fileURL.path,
            words: """
                Contact \(peerID) \(operation) evidence could not be retained: \(error.localizedDescription). Its completed work must not be resent \
                to replace missing evidence.
                """,
            lever: "Repair the contact evidence store, then reconcile the original operation's receipt.")
    }

    /// Discovery cannot replace an existing identity or its credentials. Exact routes reuse identity under the store lock; desktop labels scope routes.
    @discardableResult public func insertDiscovered(_ contact: AgentPeerContact) throws -> AgentPeerContact {
        try Self.validate(contact)
        try prepareDirectory()
        return try CredentialFileLock.withLock(fileURL) {
            var peers = try read()
            let matches = peers.filter { Self.sameRoute($0, contact) }
            guard matches.count <= 1 else { throw AgentPeerStoreError.invalidConfiguration.failure(file: fileURL) }
            if let existing = matches.first { return existing }
            guard !peers.contains(where: { $0.id == contact.id }) else { throw AgentPeerStoreError.invalidContact.failure(file: fileURL) }
            guard peers.count < Self.maximumContacts else { throw AgentPeerStoreError.tooManyContacts.failure(file: fileURL) }
            // A discovered peer is never elevated. See `setElevation`.
            var fresh = contact
            fresh.allowElevation = nil
            fresh.readsDesk = nil
            fresh.lastRead = nil
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

    /// Only known host recipes may establish mcp endpoint identity.
    public static func hostRowID(_ endpoint: URL) -> String? {
        if let bundle = desktopBundleID(endpoint) {
            return AgentHostDirectory.rows.first { $0.route == .desktopChat && $0.bundleIDs.contains(bundle) }?.id
        }
        guard let host = endpoint.host, ["mcp://" + host, "acp://" + host, "grok://" + host].contains(endpoint.absoluteString) else { return nil }
        guard AgentHostDirectory.rows.contains(where: { $0.id == host }) else { return nil }
        return host
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
        guard Self.validID(id) else { throw AgentPeerStoreError.invalidContact.failure(file: fileURL) }
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
        else { throw AgentPeerStoreError.invalidContact.failure() }
        if contact.transport == .desktop || contact.transport == .desktopChat {
            guard desktopBundleID(contact.endpoint) != nil else { throw AgentPeerStoreError.invalidEndpoint.failure() }
            guard contact.credentialKey == nil else { throw AgentPeerStoreError.invalidCredentialReference.failure() }
            if let label = contact.conversationLabel {
                guard !label.isEmpty, label.utf8.count <= 480,
                      label == label.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw AgentPeerStoreError.invalidContact.failure()
                }
            }
            return
        }
        if contact.transport == .grokBot {
            guard contact.endpoint.absoluteString == "grok://grok-bot",
                  contact.credentialKey == AgentPeerContact.credentialKey(for: contact.id),
                  ["creating", "secure-paste", "set up", "disconnected"].contains(contact.grokSetup ?? "") else {
                throw AgentPeerStoreError.invalidContact.failure()
            }
            if let label = contact.conversationLabel {
                guard !label.isEmpty, label.utf8.count <= 480,
                      label == label.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw AgentPeerStoreError.invalidContact.failure()
                }
            }
            return
        }
        guard contact.conversationLabel == nil else { throw AgentPeerStoreError.invalidContact.failure() }
        if contact.transport == .mcpHost || contact.transport == .acp {
            // Endpoint text is identity only, never a dialled address; the owned key resolves inbound requests.
            let scheme = contact.transport == .acp ? "acp" : "mcp"
            guard let host = contact.endpoint.host, !host.isEmpty,
                  contact.endpoint.absoluteString == scheme + "://" + host,
                  contact.endpoint.absoluteString.utf8.count <= maximumEndpointLength,
                  host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
            else { throw AgentPeerStoreError.invalidEndpoint.failure() }
            let row = hostRowID(contact.endpoint).flatMap { id in AgentHostDirectory.rows.first { $0.id == id } }
            guard let row, contact.transport != .acp || row.acp != nil else { throw AgentPeerStoreError.invalidEndpoint.failure() }
            if row.requiresWorkspace {
                guard let folder = contact.hostWorkspace, folder.hasPrefix("/"),
                      !folder.contains("\0"), folder.utf8.count <= 4096 else { throw AgentPeerStoreError.invalidEndpoint.failure() }
            } else if contact.hostWorkspace != nil { throw AgentPeerStoreError.invalidEndpoint.failure() }
            if let key = contact.credentialKey, key != AgentPeerContact.credentialKey(for: contact.id) {
                throw AgentPeerStoreError.invalidCredentialReference.failure()
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
        else { throw AgentPeerStoreError.invalidEndpoint.failure() }
        if let key = contact.credentialKey, key != AgentPeerContact.credentialKey(for: contact.id) {
            throw AgentPeerStoreError.invalidCredentialReference.failure()
        }
    }

    private static func validID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw AgentPeerStoreError.unreadableConfiguration.failure(file: fileURL) }
        } else {
            guard errno == ENOENT else { throw AgentPeerStoreError.unreadableConfiguration.failure(file: fileURL) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard chmod(directory.path, 0o700) == 0 else { throw AgentPeerStoreError.unreadableConfiguration.failure(file: fileURL) }
    }

    fileprivate func read() throws -> [AgentPeerContact] {
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw AgentPeerStoreError.unreadableConfiguration.failure(file: fileURL)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentPeerStoreError.unreadableConfiguration.failure(file: fileURL)
        }
        guard info.st_size <= Self.maximumConfigurationBytes else { throw AgentPeerStoreError.configurationTooLarge.failure(file: fileURL) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, Self.maximumConfigurationBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumConfigurationBytes else { throw AgentPeerStoreError.configurationTooLarge.failure(file: fileURL) }
        }
        do {
            let peers = try JSONValue.parse(data).decodedExactly(as: [AgentPeerContact].self)
            guard peers.count <= Self.maximumContacts, Set(peers.map(\.id)).count == peers.count else {
                throw AgentPeerStoreError.invalidConfiguration.failure(file: fileURL)
            }
            for peer in peers { try Self.validate(peer) }
            return peers
        } catch { throw AgentPeerStoreError.invalidConfiguration.failure(file: fileURL) }
    }

    private func write(_ peers: [AgentPeerContact]) throws {
        let previous = try read()
        guard peers != previous else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(peers)
        guard data.count <= Self.maximumConfigurationBytes else { throw AgentPeerStoreError.configurationTooLarge.failure(file: fileURL) }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
        if Self.trustIdentity(peers) != Self.trustIdentity(previous) {
            NotificationCenter.default.post(name: Self.trustDidChange, object: fileURL)
            let locator = fileURL.standardizedFileURL.path
            Task {
                await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                    namespace: "agent-trust", stableID: "contacts", operation: .changed,
                    canonicalLocator: locator, reason: "contact_trust_changed"))
            }
        }
    }

    /// Compare the canonical fields read by principal/name resolution and credential-backed grants, without persisting another truth.
    private static func trustIdentity(_ peers: [AgentPeerContact]) -> JSONValue {
        .array(peers.sorted { $0.id < $1.id }.map { peer in
            .object(["id": .string(peer.id), "name": .string(peer.name), "who": peer.who.map(JSONValue.string) ?? .null,
                     "handles": .array((peer.handles ?? []).sorted().map(JSONValue.string)),
                     "transport": .string(peer.transport.rawValue), "credentialKey": peer.credentialKey.map(JSONValue.string) ?? .null,
                     "allowed": .bool(peer.elevationAllowed)])
        })
    }
}

extension AgentContactIdentity {
    public init(dataRoot: URL, peers: [AgentPeerContact]? = nil) throws {
        let contacts = try peers ?? AgentPeerStore(dataRoot: dataRoot).read()
        self.init(contacts: contacts)
    }
    public init(contacts: [AgentPeerContact]) {
        self.init(peers: contacts.map { peer in
            ["id": peer.id, "name": peer.name, "who": peer.who, "endpoint": peer.endpoint.absoluteString,
             "transport": peer.transport.rawValue].compactMapValues { $0 }
        }, handles: Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0.handles ?? []) }))
    }
}
