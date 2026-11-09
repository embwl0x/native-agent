import AgentConversations
import Agents
import AppToolRuntime
import AuthoredCapabilities
import ChatTurnContracts
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import Transcripts
import TrustCenter
// Blueprint: | `ConnectorFace+Agents.swift` | Connectors' agent rows: contact doors, their threads and the person's send; Connect, Test and Disconnect ask in a new Mac chat; a read never discovers; each row is a door call, and the agent verbs no other verb runs run here |

/// The Mac's chat column behind the agent rows: a contact's Connect, Test or Disconnect starts a new conversation with its prompt.
@MainActor public protocol AgentContactsFaceHost {
    func askInNewChat(_ words: String) async throws -> String
}

extension NativeAgentEngine {
    /// The contact owner's files whose change re-reads the Connectors page.
    var agentFacePaths: [URL] {
        ["agents/peers.json", "agents/conversations.json", "agents/discovery.json", "agents/local-health.json", "chat/sessions.json"]
            .map { dataRoot.appendingPathComponent($0) }
    }

    /// The contact owner's change signals beyond its files: a direct chat's transport reports a reply or a status change.
    static let agentFaceNotifications = [ChatGPTDotIPCTransport.didChange]

    /// Reads the contact owner's doors and threads; offscreen and page reads never start discovery.
    @concurrent func agentFaceSections() async -> [PartFace.Section] {
        let root = dataRoot, owner = contacts
        let threads: [MobileAgentThread]?
        let threadsFailure: String?
        do {
            threads = try await Task.detached(priority: .utility) {
                try await AgentContactThreads.mobileThreads(root: root, contacts: owner)
            }.value
            threadsFailure = nil
        } catch {
            threads = nil
            threadsFailure = error.localizedDescription
        }
        let state = await MainActor.run { (error: contacts.loadError, loaded: contacts.loaded, doors: contacts.doors) }
        let primary = state.doors.filter(\.primary)
        var rows: [PartFace.Row] = []
        // The threads read is the doors' read too: before the doors ever load, its failure is theirs.
        if let error = state.error ?? (state.loaded ? nil : threadsFailure) {
            rows.append(.init(id: "agents.unavailable", title: "The agent address book could not load",
                detail: AgentPeerStore(dataRoot: root).fileURL.path + ": " + error, tone: .failed,
                actions: [.init(id: "refresh", label: "Try again", call: .init("agent.refresh"))]))
        }
        if state.loaded && state.error == nil && primary.isEmpty {
            rows.append(.init(id: "agents.none", title: "No agent contacts or supported apps found on this Mac.", tone: .quiet))
        }
        rows += primary.flatMap { agentDoorRows($0) }
        rows.append(.init(id: "agents.look", title: "Look for agents",
            detail: "Finds A2A cards, MCP settings and ACP programs on this Mac; it may run a program's --help or initialize.",
            symbol: "magnifyingglass", actions: [.init(id: "discover", label: "Look for agents", call: .init("agent.look"))]))
        var sections: [PartFace.Section] = [.init(id: "agents", title: "Agents", style: .list, rows: rows)]
        if let threads {
            if !threads.isEmpty {
                sections.append(.init(id: "agent-threads", title: "Agent conversations", style: .list, rows: threads.map { agentThreadRow($0) }))
            }
        } else {
            sections.append(.init(id: "agent-threads", title: "Agent conversations", style: .list, rows: [.init(id: "agents.threads-error",
                title: "Agent conversations could not be read", detail: threadsFailure, tone: .failed)]))
        }
        return sections
    }

    private func agentDoorRows(_ row: AgentContactRow) -> [PartFace.Row] {
        var detail = [row.route, row.status]
        if let contact = row.contact { detail.append("Trusted switch: " + (contact.elevationAllowed ? "on" : "off")) }
        if let last = row.lastExchange { detail.append("Last exchange · " + last) }
        if let at = row.contact?.provenInboundAt { detail.append("Received a message · " + at) }
        if let at = row.contact?.provenOutboundAt { detail.append("Sent a message · " + at) }
        // Each asks in a new conversation on the Mac's chat column, so they run from the Mac door.
        func ask(_ ask: String) -> PartFace.Call { .init("agent.ask_in_chat", ["agent": .string(row.id), "ask": .string(ask)]) }
        var actions = [PartFace.Action(id: "connect", label: "Connect", role: .primary, doors: ["mac"], call: ask("connect"))]
        if row.contact != nil {
            actions = row.repliesOnly ? [] : [PartFace.Action(id: "test", label: "Send a test message", doors: ["mac"], call: ask("test"))]
            actions.append(PartFace.Action(id: "disconnect", label: "Disconnect agent", doors: ["mac"], call: ask("disconnect")))
        }
        var rows = [PartFace.Row(id: "agent:" + row.id, title: row.displayName, detail: detail.joined(separator: "\n"), value: row.pillWord,
            symbol: "person.2", tone: row.state == .connected ? .live : nil, actions: actions)]
        // A Grok Bot routine finishes setup by reading its credentials natively; the credentials themselves never enter a face.
        if let contact = row.contact, contact.transport == .grokBot, ["creating", "secure-paste"].contains(contact.grokSetup ?? "") {
            let peer: [String: PartFace.Value] = ["agent": .string(contact.id)]
            rows.append(.init(id: "agent-grok:" + contact.id, title: row.displayName + " · Routine credentials", detail: contact.grokSetup == "creating"
                ? """
                    Routine setup is not confirmed. Connect again to continue this contact's setup. If a request was already submitted, it will not be \
                    sent again; approve it in Grok Bot if asked.
                    """
                : "Grok Bot setup is unfinished. Connect again to continue, or read the routine securely on this Mac.",
                tone: .attention, actions: [.init(id: "import", label: "Read routine securely", doors: ["mac"], call: .init("agent.grok_import", peer)),
                                            .init(id: "paste", label: "Paste credentials securely", doors: ["mac"],
                                                  call: .init("agent.grok_paste", peer))]))
            if contact.grokConversation == nil {
                rows.append(.init(id: "agent-grok-bot:" + contact.id, title: "Grok Bot name", detail: """
                    Connect briefly brings Grok Bot forward to send the routine request. If the current Bot cannot be identified, enter its exact \
                    sidebar name here, then Connect again.
                    """, control: .field("", placeholder: "Bot name", call: .init("agent.grok_bot", peer))))
            }
        }
        return rows
    }

    /// A conversation is one row: its state, the person's send, and an open to its lines, which are a document read on demand.
    private func agentThreadRow(_ thread: MobileAgentThread) -> PartFace.Row {
        let agent = thread.agent
        let when = agent.lastActivityAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        var detail = [agent.via]
        if !agent.status.isEmpty { detail.append(agent.status) }
        if !agent.lastExchange.isEmpty { detail.append(agent.lastExchange) }
        if let restriction = agent.sendRestriction { detail.append(restriction) }
        return PartFace.Row(id: "agent-send:" + agent.id, title: agent.name, detail: detail.joined(separator: "\n"),
            value: agent.stateLine ?? "State not reported", at: when.map { $0.formatted(.iso8601) }, symbol: "bubble.left.and.bubble.right",
            open: "page:connectors/agent-thread:" + agent.id,
            control: agent.sendRestriction == nil
                ? .field("", placeholder: "Message " + agent.name, call: .init("agent.send", ["agent": .string(agent.id)])) : nil)
    }

    /// One conversation's lines as a document: who said what and when, oldest first, as the contact owner reads them now.
    @MainActor func agentThreadDocument(_ agent: String) async throws -> String {
        let root = dataRoot, owner = contacts
        let threads = try await Task.detached(priority: .utility) {
            try await AgentContactThreads.mobileThreads(root: root, contacts: owner)
        }.value
        guard let thread = threads.first(where: { $0.agent.id == agent }) else {
            throw PartCallError(code: "stale_row", message: "That conversation is no longer listed. Read Connectors again.")
        }
        var lines = [thread.agent.name + " · " + thread.agent.via]
        if thread.lines.isEmpty { lines.append("No exchanges yet.") }
        lines += thread.lines.map { line in
            Date(timeIntervalSince1970: line.at).formatted(date: .abbreviated, time: .shortened) + " · " + line.speaker + "\n" + line.text
        }
        if thread.truncated { lines.append("Showing recent excerpts. The full conversation remains on the Mac.") }
        return lines.joined(separator: "\n\n")
    }

    /// `agent.refresh`: the contact owner reads the address book again.
    @MainActor func agentsRefresh() async throws -> String? {
        try await contacts.refresh()
        return nil
    }

    /// `agent.look`: discovery looks for agents on this Mac, then the contact owner reads the address book again.
    @MainActor func agentsLook() async throws -> String? {
        _ = await AgentDiscoverySession.shared.candidates(refresh: true, dataRoot: dataRoot)
        let found = try await contacts.refresh()
        return "\(found.count) agent \(found.count == 1 ? "contact or app is" : "contacts or apps are") listed."
    }

    /// `agent.ask_in_chat`: a new conversation on the Mac's chat column opens with the contact's own prompt to connect, test or disconnect.
    @MainActor func agentAskInChat(agent: String, ask: String) async throws -> String? {
        guard let contact = contacts.rows.first(where: { $0.id == agent }) else {
            throw PartCallError(code: "stale_row", message: "That agent is no longer listed. Refresh Connectors before choosing it.")
        }
        let prompt: AgentContactRow.Action
        switch ask {
        case "connect": prompt = .connect
        case "test": prompt = .test
        case "disconnect": prompt = .disconnect
        default: throw PartCallError(code: "bad_value", message: "ask is connect, test or disconnect; nothing was asked.")
        }
        guard let host = ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false).quietHost() as? any AgentContactsFaceHost else {
            throw PartCallError(code: "unavailable", message: "The Mac's chat is unavailable; nothing was asked.")
        }
        return try await host.askInNewChat(contact.prompt(prompt))
    }

    /// `agent.send`: the person's own words to a contact, from `session` when the person's door names the conversation it was typed in (the
    /// phone's thread view), otherwise the person's current conversation.
    @MainActor func agentSend(agent: String, text: String, session named: String, turn: Turn) async throws -> String? {
        guard !text.isEmpty, text.count <= 16_000 else {
            throw PartCallError(code: "bad_value", message: "A message to an agent is between 1 and 16,000 characters. Nothing was sent.")
        }
        guard contacts.rows.contains(where: { $0.id == agent && $0.contact != nil }) else {
            throw PartCallError(code: "stale_row", message: "This agent is no longer reachable. Refresh Connectors before sending.")
        }
        guard let envelope = turn.envelope else {
            throw PartCallError(code: "door_unknown", message: "The door this message came from is not known, so nothing was sent.")
        }
        let session: String
        if named.isEmpty { session = try anchoredSession(for: "send it") } else {
            guard try await transcripts.list().contains(where: { $0.id == named }) else {
                throw PartCallError(code: "conversation_unknown", message: "That conversation is not one of yours, so nothing was sent.")
            }
            session = named
        }
        if let why = await sendContactMessage(agent: agent, text: text, session: session, root: dataRoot,
                                              turn: Turn(session: session).with(\.envelope, envelope)) {
            throw PartCallError(code: "send_failed", message: why)
        }
        return "Message accepted."
    }

    /// `agent.grok_paste`: the Mac's secure window takes a Grok Bot routine's credentials, from its secure field to the keychain only.
    @MainActor func grokPaste(peer: String, renderer: UUID?) async throws -> String? {
        guard let contact = contacts.rows.first(where: { $0.contact?.id == peer })?.contact,
              contact.transport == .grokBot, ["creating", "secure-paste"].contains(contact.grokSetup ?? "") else {
            throw PartCallError(code: "stale_row", message: "This contact is not waiting for routine credentials. Refresh Connectors.")
        }
        if let renderer {
            switch try await faceActs.call(.showGrokSetup(contact: peer, operation: UUID()), renderer: renderer) {
            case .acknowledged: return nil
            case .failed(let issue), .refused(let issue): throw issue
            case .cancelled: throw CancellationError()
            default: throw FaceWireError.invalidFeedOrder
            }
        }
        guard let show = connectors.platform.showGrokSecureSetup else {
            throw PartCallError(code: "mac_required", message: "Paste the Grok Bot credentials on your Mac.")
        }
        try await show(peer)
        return nil
    }

    /// `agent.grok_import`: a Grok Bot routine's credentials are read securely on this Mac into the keychain.
    @MainActor func grokImport(peer: String) async throws -> String? {
        let turn = Turn().with(\.envelope, .personOnMac("mac_ui:grok.import"))
        guard try await GrokBotConnection.importSecureCredentials(turn: turn, mac: .init(dataRoot: dataRoot), peer: peer, dataRoot: dataRoot,
                                                                 desktop: agents.desktop) else {
            throw PartCallError(code: "stale_row", message: "This contact is not waiting for routine credentials. Refresh Connectors.")
        }
        return "Set up. Credentials are in Keychain. Send a test message; approve the local reply command in Grok Bot if asked."
    }

    /// `agent.grok_bot`: the Grok Bot's exact sidebar name for a contact's routine request.
    @MainActor func grokBot(peer: String, name: String) throws -> String? {
        guard !name.isEmpty else { throw PartCallError(code: "bad_value", message: "Enter the Bot's exact sidebar name. Nothing was saved.") }
        try GrokBotConnection.selectBot(peer: peer, name: name, dataRoot: dataRoot)
        return "Bot selected. Connect again to send the routine request."
    }

    @MainActor private func anchoredSession(for purpose: String) throws -> String {
        guard let session = try ConversationAnchor.checkedCurrent(dataRoot: dataRoot)?.sessionId else {
            throw PartCallError(code: "conversation_required", message: "Open a chat with me, then choose this again so I can \(purpose) there.")
        }
        return session
    }
}
