import SenseCore
import MindCore
import Foundation
import MacNerves
import NativeAgentCore
import NativeAgentShared
import DeskCore
// Blueprint: | `ConnectorFace+Agents.swift` | Connectors' agent rows: contact doors, their threads and the person's send; Connect, Test and Disconnect ask in a new Mac chat; a read never discovers; each row is a door call, and the agent verbs no other verb runs run here |

/// The Mac's chat column behind the agent rows: a contact's Connect, Test or Disconnect starts a new conversation with its prompt.
@MainActor public protocol AgentContactsFaceHost {
    func askInNewChat(_ words: String) async throws -> String
}

extension NativeAgentEngine {
    /// The contact owner's files whose change re-reads the Connectors page.
    var agentFacePaths: [URL] {
        ["agents/peers.json", "agents/conversations.json", "agents/discovery.json", "agents/recipes/", "agents/local-health.json", "chat/sessions.json"]
            .map { dataRoot.appendingPathComponent($0) }
    }

    /// The contact owner's change signals beyond its files: a direct chat's transport reports a reply or a status change.
    static let agentFaceNotifications = [ChatGPTDotIPCTransport.DidChange.name, ContactThreadReadouts.ContactsDidChange.name]

    /// Reads the contact owner's doors, one connector row each with its unfinished setup behind it, and its conversations as their own
    /// section; offscreen and page reads never start discovery.
    @concurrent func agentFace() async -> (rows: [PartFace.Row], sections: [PartFace.Section]) {
        let root = dataRoot
        let threads: [MobileAgentThread]?
        let threadsFailure: String?
        do {
            threads = try await contactThreads.mobileThreads()
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
        rows += primary.map { agentDoorRow($0) }
        rows.append(.init(id: "agents.look", title: "Look for agents",
            detail: "Finds A2A cards, MCP settings and ACP programs on this Mac; it may run a program's --help or initialize.",
            symbol: "magnifyingglass", actions: [.init(id: "discover", label: "Look for agents", call: .init("agent.look"))]))
        var sections: [PartFace.Section] = []
        if let threads {
            if !threads.isEmpty {
                sections.append(.init(id: "agent-threads", title: "Agent conversations", style: .list, rows: threads.map { agentThreadRow($0) }))
            }
        } else {
            sections.append(.init(id: "agent-threads", title: "Agent conversations", style: .list, rows: [.init(id: "agents.threads-error",
                title: "Agent conversations could not be read", detail: threadsFailure, tone: .failed)]))
        }
        return (rows, sections)
    }

    private func agentDoorRow(_ row: AgentContactRow) -> PartFace.Row {
        var detail = [row.route, row.status]
        if let contact = row.contact { detail.append("Trusted switch: " + (contact.elevationAllowed ? "on" : "off")) }
        if row.contact?.readsDesk == true { detail.append("Reads my Desk") }
        if let last = row.lastExchange { detail.append("Last exchange · " + last) }
        if let at = row.contact?.provenInboundAt { detail.append("Received a message · " + at) }
        if let at = row.contact?.provenOutboundAt { detail.append("Sent a message · " + at) }
        // Each asks in a new conversation on the Mac's chat column, so they run from the Mac door.
        func ask(_ ask: String) -> PartFace.Call { .init("agent.ask_in_chat", ["agent": .string(row.id), "ask": .string(ask)]) }
        var actions = [PartFace.Action(id: "connect", label: "Connect", role: .primary, doors: ["mac"], call: ask("connect"))]
        if row.contact != nil {
            actions = row.repliesOnly ? [] : [PartFace.Action(id: "test", label: "Send a test message", doors: ["mac"], call: ask("test"))]
            if let contact = row.contact, AgentPeerStore.hostRowID(contact.endpoint) != nil {
                actions.insert(.init(id: "reconnect", label: "Reconnect", doors: ["mac"], call: ask("connect")), at: 0)
            }
            actions.append(PartFace.Action(id: "disconnect", label: "Disconnect agent", doors: ["mac"], call: ask("disconnect")))
        }
        var setup: [PartFace.Row] = []
        // A Grok Bot routine finishes setup when its webhook address and key are pasted securely; the credentials themselves never enter a face.
        if let contact = row.contact, contact.transport == .grokBot, ["creating", "secure-paste"].contains(contact.grokSetup ?? "") {
            let peer: [String: PartFace.Value] = ["agent": .string(contact.id)]
            setup.append(.init(id: "agent-grok:" + contact.id, title: "Routine credentials", detail: contact.grokSetup == "creating"
                ? """
                    Routine setup is unfinished. Connect gives the steps: send its one message in the Grok Bot chat, then copy the routine's webhook \
                    address and key with Grok Bot's own Copy and paste them securely.
                    """
                : "Grok Bot setup is unfinished. Paste the routine's webhook address and key securely, together or one after the other.",
                tone: .attention, actions: [.init(id: "paste", label: "Paste credentials securely", doors: ["mac"],
                                                  call: .init("agent.grok_paste", peer))]))
            if contact.grokConversation == nil {
                setup.append(.init(id: "agent-grok-bot:" + contact.id, title: "Grok Bot name", detail: """
                    Connect's steps name the Grok Bot chat its setup message goes to. For another Bot's chat, enter that Bot's exact sidebar name \
                    here, then Connect again.
                    """, control: .field("", placeholder: "Bot name", call: .init("agent.grok_bot", peer))))
            }
        }
        // A contact that calls the MCP tools with its own key can be brought to the table; the switch is the person's lever, its setting lower-only.
        var table: [PartFace.Row] = []
        if let contact = row.contact, contact.canReadTable {
            let on = contact.readsDesk == true
            let about = "At my table, \(row.displayName) reads my Desk and the pieces on it through its own connection. It changes nothing; it asks me."
            table.append(.init(id: "agent-desk:" + contact.id, title: "Reads my Desk",
                detail: contact.lastRead.map { about + "\nLast " + $0.words(desk: "my Desk") } ?? about,
                control: .toggle(on, confirm: on ? nil : "Let \(row.displayName) read my Desk and the pieces on it?",
                                 call: settingSetCall("agent.reads_desk_" + contact.id))))
        }
        // Unfinished setup sits behind the agent's row, which says it waits on the person.
        let nested = setup + table
        return .init(id: "agent:" + row.id, title: row.displayName, detail: detail.joined(separator: "\n"), value: row.pillWord,
            symbol: "person.2", tone: row.state == .connected ? .live : setup.isEmpty ? nil : .attention, actions: actions,
            rows: nested.isEmpty ? nil : nested)
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
        let threads = try contactThreads.mobileThreads()
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

    /// `agent.refresh`: the thread owner rereads the address book and publishes its conversations together.
    @MainActor func agentsRefresh() async throws -> String? {
        try await contactThreads.refreshContacts()
        return nil
    }

    /// `agent.look`: discovery looks for agents on this Mac, then the contact owner reads the address book again.
    @MainActor func agentsLook() async throws -> String? {
        _ = await AgentDiscoverySession.shared.candidates(refresh: true, dataRoot: dataRoot)
        let found = try await contacts.refresh()
        return "\(found.count) agent \(found.count == 1 ? "contact or app is" : "contacts or apps are") listed."
    }

    /// `agent.ask_in_chat`: the listed contact, the ask, and the Mac's chat (the lookups); a new conversation on the Mac's chat column opens
    /// with the contact's own prompt to connect, test or disconnect (the effect).
    @MainActor func agentAskInChat(agent: String, ask: String) throws -> HostVerbEffect {
        let contact = try contactRow(agent)
        let prompt: AgentContactRow.Action
        switch ask {
        case "connect": prompt = .connect
        case "test": prompt = .test
        case "disconnect": prompt = .disconnect
        default: throw PartCallError(code: "bad_value", message: "ask is connect, test or disconnect; nothing was asked.")
        }
        guard let host = ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false, self).quietHost() as? any AgentContactsFaceHost else {
            throw PartCallError(code: "unavailable", message: "The Mac's chat is unavailable; nothing was asked.")
        }
        return { try await host.askInNewChat(contact.prompt(prompt)) }
    }

    /// `agent.send`: the person's own words to a contact, from `session` when the person's door names the conversation it was typed in (the
    /// phone's thread view), otherwise the person's current conversation. The words, the reachable contact, the door and the conversation
    /// are the lookups; the send is the effect.
    @MainActor func agentSend(agent: String, text: String, session named: String, turn: Turn) async throws -> HostVerbEffect {
        guard !text.isEmpty, text.count <= 16_000 else {
            throw PartCallError(code: "bad_value", message: "A message to an agent is between 1 and 16,000 characters. Nothing was sent.")
        }
        let row = try contactRow(agent)
        guard row.contact != nil else { throw NamedRow.stale("\(row.name) is listed but not connected, so nothing was sent.") }
        let agent = row.id
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
        return { [self] in
            if let why = await sendContactMessage(agent: agent, text: text, session: session, root: dataRoot,
                                                  turn: Turn(dataRoot: dataRoot, session: session).with(\.envelope, envelope)) {
                throw PartCallError(code: "send_failed", message: why)
            }
            return "Message accepted."
        }
    }

    /// `agent.grok_paste`: a Grok Bot routine's webhook goes from a secure paste to the keychain only. One rule decides the path. The person's own press
    /// of the Connectors row's button in the app opens the Mac's secure field for the person's paste. Every other call through the door (the agent's
    /// own, one the person's word decided, an approved card's replay) is the one paste that field allows the agent: the clipboard, read natively at
    /// once, never a window and never waiting on one. Each call is independent: address and key in either order, each saved as it arrives; the one
    /// that completes the setup closes any secure window still open for the contact. The contact waiting for routine credentials is the
    /// lookup; the window or the paste is the effect.
    @MainActor func grokPaste(peer: String, turn: Turn) throws -> HostVerbEffect {
        guard let contact = try contactRow(peer).contact, contact.transport == .grokBot,
              ["creating", "secure-paste"].contains(contact.grokSetup ?? "") else {
            throw NamedRow.stale("This contact is not waiting for routine credentials.")
        }
        return { [self] in
            if case .tap(let door, _, _, let page, _)? = turn.personAct?.by, door == "mac", page == "connectors",
               let renderer = turn[FacePresentationPart.self] {
                switch try await faceActs.call(.showGrokSetup(contact: contact.id, operation: UUID()), renderer: renderer) {
                case .acknowledged: return nil
                case .failed(let issue), .refused(let issue): throw issue
                case .cancelled: throw CancellationError()
                default: throw FaceWireError.invalidFeedOrder
                }
            }
            let pasted = try await GrokBotConnection.pasteClipboard(peer: contact.id, dataRoot: dataRoot)
            if pasted.complete, let close = connectors.platform.closeGrokSecureSetup { try? await close(contact.id) }
            return pasted.words
        }
    }

    /// `agent.grok_bot`: a name was given, and the contact it names (its id or its name), read now, is a Grok Bot contact that is connected
    /// and has no routine conversation yet, the ones the Bot's name can still be chosen for (the lookups); the Bot's exact sidebar name is
    /// saved for the contact's routine request (the effect).
    @MainActor func grokBot(peer: String, name: String) throws -> HostVerbEffect {
        guard !name.isEmpty else { throw PartCallError(code: "bad_value", message: "Enter the Bot's exact sidebar name. Nothing was saved.") }
        guard let contact = try contactRow(peer).contact, contact.transport == .grokBot, contact.grokSetup != "disconnected",
              contact.grokConversation == nil else {
            throw NamedRow.stale("That is not a Grok Bot contact that can take a Bot name.")
        }
        return { [self] in
            try GrokBotConnection.selectBot(peer: contact.id, name: name, dataRoot: dataRoot)
            return "Bot selected. Connect again for the setup steps in that Bot's chat."
        }
    }

    /// The listed contact a call names by its row id, its contact id or its name (`NamedRow`).
    @MainActor private func contactRow(_ named: String) throws -> AgentContactRow {
        try NamedRow.find(named, kind: "agent", in: contacts.rows,
            ids: { [$0.id] + ($0.contact.map { [$0.id] } ?? []) }, names: { [$0.name] + ($0.contact.map { [$0.name] } ?? []) },
            shown: { "\($0.name) (\($0.id))" })
    }

    @MainActor private func anchoredSession(for purpose: String) throws -> String {
        guard let session = try ConversationAnchor.checkedCurrent(dataRoot: dataRoot)?.sessionId else {
            throw PartCallError(code: "conversation_required", message: "Open a chat with me, then choose this again so I can \(purpose) there.")
        }
        return session
    }
}
