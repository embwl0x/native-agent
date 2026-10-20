import Foundation
import NativeAgentCore
import ChatOrchestration

public struct AgentContactRow: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let contact: AgentPeerContact?
    public var candidate: AgentDiscoveryCandidate? = nil
    public var builtIn = false
    /// The newest retained exchange with this contact, from any chat.
    public var lastExchange: String?
    /// Home's own word for this contact (AgentContactHealth): one source, so
    /// Agents, the Simple view and home never disagree.
    public var health: AgentLocalHealth?
    /// Read once when the row is built (a Keychain read), not on every redraw.
    public var credentialAvailable = true
    public var elevationFailure: ToolFailureError?
    public var state: AgentPeerContactState?

    public var repliesOnly: Bool {
        let hostID = contact.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? id
        return AgentHostDirectory.row(named: hostID)?.format == .shellEnvironment
    }

    public var displayName: String { name }

    public var route: String {
        if let contact, contact.transport == .acp {
            return "Route: ACP\nStarts in folder: \(contact.acpWorkingDirectory ?? "Not set")"
                + "\nProgram: \(contact.approvedExecutablePath ?? "Not approved")"
                + "\n\(contact.canStartTurn ? "Can start a turn now" : "Cannot start a turn now · Connect again to approve the program")"
        }
        let hostID = contact.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? id
        let host = AgentHostDirectory.rows.first { $0.id == hostID }
        if let host {
            if repliesOnly { return host.description }
            if host.route == .grokBot {
                return host.description + " Messages start a routine; its local reply returns here. Grok Bot may ask you to approve each reply command."
            }
            if host.acp != nil {
                return "\(host.description) I can start a conversation with it after you connect.\nRoute: ACP\nConnect to choose its starting folder and approve the exact program. Cannot start a turn yet."
            }
            return host.description + " I add myself to its settings so it can message me. "
                + (host.commandLine == nil ? "It can message me; I cannot start a conversation with it yet."
                    : "I can start a conversation with it.")
        }
        if let candidate { return candidate.detail + ((candidate.endpoint ?? candidate.cardURL).map { "\nA2A address: " + $0.absoluteString } ?? "") }
        guard let contact else { return "On this Mac" }
        switch contact.transport {
        case .grokBot: return "Grok Bot routine with a local reply helper."
        case .acp: return "Route: ACP"
        case .a2a: return "A2A address: " + contact.endpoint.absoluteString
        case .nativeAgent: return "Direct connection: " + contact.endpoint.absoluteString
        case .desktop: return "Through its app window · " + contact.endpoint.absoluteString
        case .desktopChat: return "Its own chat in the app's window · " + contact.endpoint.absoluteString
        case .mcpHost: return "Settings entry (MCP) · " + contact.endpoint.absoluteString
        }
    }

    public static func rows(peers: [AgentPeerContact], candidates: [AgentDiscoveryCandidate], usable: Set<String>, everyDoor: Bool = false) -> [Self] {
        let hosts = candidates.filter(\.connectable).compactMap { candidate in
            candidate.hostID.flatMap { id in AgentHostDirectory.rows.first { $0.id == id } }
        }
        let discovered = candidates.filter { candidate in
            // A card, or a find no recipe knows yet (its draft).
            (candidate.cardURL != nil || candidate.draft != nil) && !peers.contains { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }
        }.map { Self(id: $0.id, name: $0.name, contact: nil, candidate: $0) }
        let contacts = (rows(peers: peers, installed: hosts, everyDoor: everyDoor) + discovered).map { row in
            var row = row
            let hostID = row.contact.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? row.id
            row.candidate = row.candidate ?? candidates.first { $0.hostID == hostID }
            return row
        }
        return contacts
    }

    /// The same canonical contact identities as People, preferring a built-in lane.
    public static func rows(peers: [AgentPeerContact], candidates: [AgentDiscoveryCandidate], usable: Set<String>, dataRoot: URL, everyDoor: Bool = false) -> [Self] {
        Task.detached(priority: .utility) { await AgentContactHealth.shared.refresh(dataRoot: dataRoot) }
        let identity = AgentContactIdentity(dataRoot: dataRoot)
        let health = AgentContactHealth.read(dataRoot: dataRoot)
        let all = rows(peers: peers, candidates: candidates, usable: usable, everyDoor: true).map { row in
            var row = row
            row.health = health[row.key]
            return row
        }
        func brain(_ row: Self) -> String {
            identity.canonical(row.key)
        }
        var seen: Set<String> = []
        return all.compactMap { row in
            // Fold the same evidence before choosing which doors to display.
            if !everyDoor, let who = row.contact?.who, peers.contains(where: { $0.id == who }) { return nil }
            let canonical = brain(row)
            guard everyDoor || seen.insert(canonical).inserted else { return nil }
            var row = row
            row.candidate = all.filter { brain($0) == canonical }.compactMap(\.candidate).first { $0.setupFailure != nil }
                ?? row.candidate
            row.health = all.filter { brain($0) == canonical }.compactMap(\.health)
                .filter { $0.problem != nil }
                .sorted { $0.isBroken != $1.isBroken ? $0.isBroken : $0.checkedAt > $1.checkedAt }
                .first ?? health[canonical] ?? row.health
            return row
        }
    }

    /// The id home and the health file know it by: a lane's name, a contact's `peer:` id.
    public var key: String { id }

    /// One row per who; `everyDoor` (Trust: each door keeps its own grant) lists
    /// each associated door too, under its who's name.
    public static func rows(peers: [AgentPeerContact], installed: [AgentHostRow], everyDoor: Bool = false) -> [Self] {
        let configured = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
        return peers.filter { peer in everyDoor || !peers.contains { $0.id == peer.who } }.map { peer in
            let available = AgentPeerCredentials.isAvailable(peer, peers: peers)
            let who = peers.first { $0.id == peer.who }
            return Self(id: "peer:" + peer.id, name: who.map { $0.name + " · " + peer.name } ?? peer.name, contact: peer,
                        credentialAvailable: available, elevationFailure: peer.elevationUnavailable(peers: peers, available: available),
                        state: available ? peer.state : .unavailable)
        }
            + installed.filter { !configured.contains($0.id) }
                .map { Self(id: $0.id, name: $0.displayName, contact: nil) }
    }

    /// Installed with no proven reply: the health record's word and detail
    /// stand over a saved contact's setup state.
    private var unproven: Bool { health?.current == true && health?.status == "installed" }

    /// The one word the row's pill carries; the full status stays below it.
    public var pillWord: String {
        if candidate?.setupFailure != nil { return "Unavailable" }
        if let word = health?.problemWord { return word }
        if let health, AgentLocalHealth.presenceStatuses.contains(health.status) { return health.word ?? "Not checked" }
        if contact != nil && (!credentialAvailable || state == .unavailable || contact?.unavailableAt != nil) { return "Unavailable" }
        if let word = health?.word, contact == nil || health?.problem != nil || unproven { return word }
        guard contact != nil else { return "Not set up" }
        switch state {
        case .connected: return "Connected"
        case .setUp: return "Set up"
        case .listed: return "Listed"
        case .sendOnly: return "Send only"
        case .unavailable, nil: return "Unavailable"
        }
    }

    public var status: String {
        if let failure = candidate?.setupFailure { return failure }
        if let health, let problem = health.problem { return problem + (health.presenceDetail.map { " · " + $0 } ?? "") }
        if let health, AgentLocalHealth.presenceStatuses.contains(health.status) { return health.detail }
        if credentialAvailable, state != .unavailable, contact?.unavailableAt == nil,
           let said = health?.problem ?? (unproven ? health?.detail : nil) { return said }
        guard let contact else { return "On this Mac · Not set up" }
        if repliesOnly {
            return !credentialAvailable ? AgentPeerCredentials.unavailableDetail
                : contact.provenInboundAt == nil ? "Replies only · No inbound message checked yet"
                : "Replies only · An inbound message has arrived"
        }
        if contact.transport == .grokBot {
            return contact.grokSetup == "set up" ? "Set up · \(contact.provenInboundAt == nil ? "No answer checked yet" : "A reply has arrived")"
                : contact.grokSetup == "disconnected" ? "Disconnected · Routine cleanup still needed"
                : "Setup needs a secure credential import at Agents → Grok Bot → Routine credentials"
        }
        let keyAvailable = credentialAvailable
        let returnProof = contact.mcpReturnProof.map {
            "\nMCP return path · \($0.endpoint.absoluteString) · Proven \($0.at)"
        } ?? ""
        let unavailable = !keyAvailable ? AgentPeerCredentials.unavailableDetail + "\n"
            : contact.unavailableAt.map { "Unavailable now · Checked \($0)\n" } ?? ""
        if let proof = contact.roundTripProof {
            return unavailable + (keyAvailable && contact.isReady ? "Ready" : "Historical round trip")
                + " · \(contact.transport == .acp ? "ACP round trip" : proof.executable == nil ? "Remote round trip" : "Command-line round trip") · \(proof.executable ?? proof.endpoint.absoluteString)"
                + " · Version \(proof.version ?? "not reported") · Folder: \(proof.workspace)"
                + " · Sign-in: \(proof.credentialKey == nil ? "connection session" : "saved credential")"
                + " · Proven \(proof.at)" + returnProof
        }
        if contact.mcpReturnProof != nil {
            return unavailable + (keyAvailable && contact.isReady ? "Ready" : "Historical proof") + returnProof
        }
        if !keyAvailable {
            return unavailable + (contact.provenInboundAt.map { "Historical inbound message · \($0)" } ?? "No proven round trip")
        }
        if contact.unavailableAt != nil { return unavailable + "No proven round trip" }
        if contact.provenInboundAt != nil { return "It can reach me · No proven outbound round trip" }
        if contact.transport == .mcpHost,
           let host = AgentPeerStore.hostRowID(contact.endpoint),
           AgentHostDirectory.rows.first(where: { $0.id == host })?.commandLine == nil {
            return "It can message me; I cannot start a conversation with it yet."
        }
        switch contact.state {
        case .unavailable: return AgentPeerCredentials.unavailableDetail
        case .listed: return "On this Mac · Not set up"
        // With history, the last exchange shows in its own note below.
        case .setUp: return lastExchange != nil ? "Set up · No proven round trip" : contact.provenOutboundAt == nil
            ? "Set up · Nothing has crossed yet" : "Set up · Sent a message, no reply yet"
        case .sendOnly: return "Can send · Replies are not connected"
        case .connected:
            return "No proven round trip"
        }
    }

    public enum Action { case connect, disconnect, test }
    public func prompt(_ action: Action) -> String {
        switch action {
        case .connect: return "Connect to \(name)."
        case .disconnect: return "Disconnect the \(name) agent contact."
        case .test: return "Send \(name) a short test message and tell me what it answers."
        }
    }
}

extension AgentContactRow {
    public static func read(dataRoot root: URL, everyDoor: Bool = false) async -> Result<[Self], Error> {
        let discovery = await AgentDiscoverySession.shared.candidates(dataRoot: root)
        return Result {
            let peers = try AgentPeerStore(dataRoot: root).list()
            let lasts = AgentConversationStore.lastExchanges(peers: peers,
                records: (try? AgentConversationStore(dataRoot: root).records()) ?? [], dataRoot: root).mapValues(\.summary)
            return AgentContactRow.rows(peers: peers, candidates: discovery, usable: [], dataRoot: root, everyDoor: everyDoor).map { row in
                var row = row
                row.lastExchange = row.contact.flatMap { lasts[$0.id] }
                return row
            }
        }
    }
}
