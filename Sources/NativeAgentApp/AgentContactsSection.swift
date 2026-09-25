import SwiftUI
import NativeAgentCore
import ChatOrchestration
import PersistenceCore

struct AgentContactRow: Identifiable {
    let id: String
    let name: String
    let contact: AgentPeerContact?
    var candidate: AgentDiscoveryCandidate? = nil
    var builtIn = false
    var sharesBuiltInName = false
    var peers: [AgentPeerContact] = []
    var readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }

    var credentialAvailable: Bool {
        contact.map { AgentPeerCredentials.isAvailable($0, peers: peers, readCredential: readCredential) } ?? true
    }

    var state: AgentPeerContactState? { credentialAvailable ? contact?.state : .unavailable }

    var displayName: String {
        builtIn ? name + " (built-in connection)" : sharesBuiltInName ? name + " (agent contact)" : name
    }

    var route: String {
        if builtIn { return "Built-in connection · Available to send; no recent reply checked here." }
        if let contact, contact.transport == .acp {
            return "Route: ACP\nStarts in folder: \(contact.acpWorkingDirectory ?? "Not set")"
                + "\nProgram: \(contact.approvedExecutablePath ?? "Not approved")"
                + "\n\(contact.canStartTurn ? "Can start a turn now" : "Cannot start a turn now · Connect again to approve the program")"
        }
        let hostID = contact.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? id
        let host = AgentHostDirectory.rows.first { $0.id == hostID }
        if let host {
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
        if let candidate { return candidate.detail + "\nA2A address: " + (candidate.endpoint ?? candidate.cardURL)!.absoluteString }
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

    static func rows(peers: [AgentPeerContact], candidates: [AgentDiscoveryCandidate], usable: Set<String>) -> [Self] {
        let hosts = candidates.compactMap { candidate in
            candidate.hostID.flatMap { id in AgentHostDirectory.rows.first { $0.id == id } }
        }
        let discovered = candidates.filter { candidate in
            candidate.hostID == nil && !peers.contains { $0.endpoint == candidate.cardURL || $0.endpoint == candidate.endpoint }
        }.map { Self(id: $0.id, name: $0.name, contact: nil, candidate: $0) }
        // Each lane under its own name, the one the bridge signs its turns
        // with ("[from: claude, via bridge]"), not the app behind it.
        let names = [("codex", "Codex"), ("claude", "Claude"), ("omp", "OMP")]
        let liveLanes = names.filter { usable.contains($0.0) }
        let contacts = (rows(peers: peers, installed: hosts) + discovered).map { row in
            var row = row
            row.sharesBuiltInName = liveLanes.contains { row.name.caseInsensitiveCompare($0.1) == .orderedSame }
            return row
        }
        return contacts + liveLanes.map { Self(id: "builtin:" + $0.0, name: $0.1, contact: nil, builtIn: true) }
    }

    static func rows(peers: [AgentPeerContact], installed: [AgentHostRow]) -> [Self] {
        let configured = Set(peers.compactMap { AgentPeerStore.hostRowID($0.endpoint) })
        return peers.map { Self(id: "peer:" + $0.id, name: $0.name, contact: $0, peers: peers) }
            + installed.filter { !configured.contains($0.id) }
                .map { Self(id: $0.id, name: $0.displayName, contact: nil) }
    }

    /// The one word the row's pill carries; the full status stays below it.
    var pillWord: String {
        if builtIn { return "Available" }
        guard contact != nil else { return "Not set up" }
        switch state {
        case .connected: return "Connected"
        case .setUp: return "Set up"
        case .listed: return "Listed"
        case .sendOnly: return "Send only"
        case .unavailable, nil: return "Unavailable"
        }
    }

    var status: String {
        if builtIn { return "Available · Reply not checked" }
        guard let contact else { return "On this Mac · Not set up" }
        if contact.transport == .grokBot {
            return contact.grokSetup == "set up" ? "Set up · \(contact.provenInboundAt == nil ? "No answer checked yet" : "A reply has arrived")"
                : contact.grokSetup == "secure-paste" ? "Setup needs a secure credential import on the Connect card"
                : contact.grokSetup == "disconnected" ? "Disconnected · Routine cleanup still needed" : "Routine setup is not confirmed"
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
        case .setUp: return contact.provenOutboundAt == nil
            ? "Set up · Nothing has crossed yet" : "Set up · Sent a message, no reply yet"
        case .sendOnly: return "Can send · Replies are not connected"
        case .connected:
            return "No proven round trip"
        }
    }

    enum Action { case connect, disconnect, test }
    func prompt(_ action: Action) -> String {
        switch action {
        case .connect: return "Connect to \(name)."
        case .disconnect: return "Disconnect the \(name) agent contact."
        case .test: return "Send \(name) a short test message and tell me what it answers."
        }
    }
}

enum AgentContactResult {
    /// A bounded display result on the existing approval receipt, so a long
    /// settings description cannot cut off the test answer's JSON mid-string.
    static func receipt(_ result: JSONValue) -> JSONValue {
        guard case .object(let value) = result else { return .null }
        var display: [String: JSONValue] = [:]
        for key in ["status", "reply", "detail", "reason", "error", "connection_check", "connection_reply_received",
                    "sent", "completed", "terminal", "needs_input", "needs_authentication", "task_id",
                    "message_id", "conversation_id", "run_id", "local_request_id", "read_with"] {
            if case .string(let text)? = value[key] {
                display[key] = .string(String(text.prefix(4096)) + (text.count > 4096 ? "\nAnswer shortened." : ""))
            } else if let item = value[key] { display[key] = item }
        }
        if let probe = value["probe"] { display["probe"] = receipt(probe) }
        if let remote = value["remote_evidence"] { display["remote_evidence"] = receipt(remote) }
        return .object(display)
    }

    static func text(_ result: JSONValue) -> String {
        guard case .object(let value) = result else { return "The result could not be read. Nothing is confirmed." }
        func string(_ key: String) -> String? {
            guard case .string(let text)? = value[key], !text.isEmpty else { return nil }
            return text
        }
        if ["pending_approval", "waiting_approval"].contains(string("status") ?? "") { return "Waiting for approval." }
        if let probe = value["probe"] { return text(probe) }
        if value["error"] != nil || ["failed", "rejected", "canceled", "cancelled", "unavailable", "error", "blocked", "refused"].contains(string("status") ?? "") {
            switch string("reason") ?? string("error") ?? "" {
            case "missing_session_id":
                return "The request could not be started. Refresh Agents and try again."
            default:
                return "The action could not be completed. Check that the other app is available and signed in, then refresh Agents and try again."
            }
        }
        let reply = string("reply")
        if value["connection_check"] == .bool(true), value["connection_reply_received"] != .bool(true) {
            return (string("detail") ?? "No new answer arrived through the connection.")
                + (reply.map { "\nThe other app said: \($0)" } ?? "")
        }
        let status = string("status") ?? ""
        let phase: String?
        if value["needs_authentication"] == .bool(true) || status == "auth-required" { phase = "Needs sign-in" }
        else if value["needs_input"] == .bool(true) || status == "input-required" { phase = "Needs input" }
        else if ["failed", "rejected", "canceled", "unavailable", "error"].contains(status) { phase = "Failed" }
        else if value["completed"] == .bool(true) || ["completed", "replied", "reply"].contains(status) { phase = "Completed" }
        else if ["working", "running", "in_progress"].contains(status) { phase = "Working" }
        else if ["accepted", "submitted", "enqueued", "queued"].contains(status) { phase = "Accepted" }
        else { phase = nil }
        let accepted = ["Accepted", "Working", "Needs input", "Needs sign-in", "Completed"].contains(phase ?? "")
        var lines: [String] = []
        if let phase {
            lines.append("Delivery: \(accepted ? "accepted" : value["sent"] == .bool(true) ? "sent" : "not confirmed") · Result: \(phase)")
        } else if value["completed"] == .bool(false) || value["sent"] != nil {
            lines.append("Delivery: \(value["sent"] == .bool(true) ? "sent" : "not confirmed") · Completion: not confirmed")
        }
        if let detail = reply ?? string("detail"), !detail.isEmpty { lines.append(detail) }
        for (key, label) in [("task_id", "Task"), ("message_id", "Message"), ("conversation_id", "Conversation"),
                             ("run_id", "Attempt"), ("local_request_id", "Request")] {
            if let locator = string(key) { lines.append("\(label): \(locator)") }
        }
        if let remote = value["remote_evidence"] { lines.append(text(remote)) }
        return lines.isEmpty ? "No answer came back. Delivery has not been confirmed." : lines.joined(separator: "\n")
    }
}

struct AgentContactsSection: View {
    var refresh = 0
    var fixtureRows: [AgentContactRow]? = nil
    @Environment(AppModel.self) private var appModel
    @State private var rows: [AgentContactRow] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var busy = false
    @State private var discovery: [AgentDiscoveryCandidate] = []
    @State private var refreshGeneration = 0
    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { refreshGeneration += 1 }
                    .accessibilityLabel("Refresh agents")
            }
            if let loadError { ConnectorsNote(text: loadError, color: NativeAgentShell.trouble) }
            if loading && fixtureRows == nil { ProgressView("Looking for agents…") }
            if !loading && (fixtureRows ?? rows).isEmpty && loadError == nil {
                ConnectorsCard { ConnectorsNote(text: "No agent contacts or supported apps found on this Mac.") }
            }
            // Alive glass (2026-09-23): one group card, a row per agent.
            if !(fixtureRows ?? rows).isEmpty {
            AliveGroupCard {
            ForEach(fixtureRows ?? rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(row.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(NativeAgentShell.text)
                            Spacer(minLength: 8)
                            ConnectorsStatusPill(
                                text: row.pillWord,
                                tone: row.state == .connected ? NativeAgentShell.calm : NativeAgentShell.secondary)
                        }
                        ConnectorsNote(text: row.route)
                        ConnectorsNote(text: row.status,
                            color: row.state == .connected ? NativeAgentShell.calm : NativeAgentShell.secondary)
                        if let at = row.contact?.provenInboundAt {
                            ConnectorsNote(text: "Received a message · \(at)")
                        }
                        if let at = row.contact?.provenOutboundAt {
                            ConnectorsNote(text: "Sent a message · \(at)")
                        }
                        HStack {
                            if row.contact == nil && !row.builtIn {
                                Button("Connect") { perform(row, .connect) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Connect \(row.displayName)")
                            } else {
                                Button("Send a test message") { perform(row, .test) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Send a test message to \(row.displayName)")
                                if !row.builtIn {
                                Button("Disconnect agent") { perform(row, .disconnect) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Disconnect \(row.displayName) agent contact")
                                    .help("Remove this agent connection. Your model provider sign-in stays connected.")
                                }
                            }
                        }
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .disabled(busy || loadError != nil)
                    }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            }
            }.padding(.bottom, 32)
        }
        .task(id: refresh + refreshGeneration) {
            guard fixtureRows == nil else { return }
            discovery = await AgentDiscoverySession.shared.candidates(refresh: true)
            let events = FileChangeEvents(paths: [root.appendingPathComponent("agents/peers.json")], emitInitial: true)
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    guard !Task.isCancelled else { break }
                    await reload()
                }
            } onCancel: { events.cancel() }
        }
    }

    @MainActor private func reload() async {
        defer { loading = false }
        do {
            let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
            let usable = Set(["codex", "claude", "omp"].filter { dispatcher.builtInAgentLaneUsable($0) })
            rows = AgentContactRow.rows(peers: try AgentPeerStore(dataRoot: root).list(),
                candidates: discovery, usable: usable)
            loadError = nil
        } catch { loadError = "Could not load agent contacts. Refresh Agents to try again." }
    }

    private func perform(_ row: AgentContactRow, _ action: AgentContactRow.Action) {
        guard !busy else { return }
        busy = true
        NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        Task { @MainActor in
            defer { busy = false }
            let previousSessionID = appModel.activeChatSessionId
            await appModel.newChatSession()
            let sessionID = appModel.activeChatSessionId
            guard !sessionID.isEmpty, sessionID != previousSessionID else { return }
            _ = await appModel.startActiveChatTurn(row.prompt(action), expectedSessionId: sessionID)
        }
    }
}
