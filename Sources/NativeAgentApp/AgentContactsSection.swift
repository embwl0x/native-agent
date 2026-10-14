import ApprovalTransactions
import EngineRuntime
import SwiftUI
import NativeAgentCore
import ChatOrchestration
import PersistenceCore

typealias AgentContactRow = EngineRuntime.AgentContactRow

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
    /// Reads can finish out of order; only the newest one applies.
    @State private var reloadGeneration = 0
    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                        if let contact = row.contact {
                            ConnectorsNote(text: "Trusted switch: \(contact.elevationAllowed ? "on" : "off")")
                        }
                        if let contact = row.contact, contact.transport == .grokBot, contact.grokSetup != "set up" {
                            GrokSecureSetupCard(dataRoot: root)
                        }
                        if let last = row.lastExchange {
                            ConnectorsNote(text: "Last exchange · " + last)
                        }
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
                                if !row.repliesOnly {
                                Button("Send a test message") { perform(row, .test) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Send a test message to \(row.displayName)")
                                }
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
        .pageActions {
            Button("Refresh", systemImage: "arrow.clockwise") { refreshGeneration += 1 }
                .accessibilityLabel("Refresh agents")
        }
        // A screenshot's offscreen copy reads the contacts once, from the
        // last discovery, and is counted so the capture waits for it.
        .quietReadTask(live: false) {
            guard fixtureRows == nil else { return }
            discovery = await AgentDiscoverySession.shared.candidates(dataRoot: root)
            await reload()
        }
        // A refresh offers what it finds (discovery.json, her wake), so the
        // offscreen copy never runs it.
        .liveTask(id: refresh + refreshGeneration) {
            guard fixtureRows == nil else { return }
            discovery = await AgentDiscoverySession.shared.candidates(refresh: true, dataRoot: root)
            // Any chat append rewrites the chat index, so a contact's session moving shows here.
            let events = FileChangeEvents(paths: [root.appendingPathComponent("agents/peers.json"),
                                                  root.appendingPathComponent("agents/conversations.json"),
                                                  AgentLocalHealth.url(root),
                                                  InstallPaths.current.bridgeConfigRoot(dataRoot: root).appendingPathComponent("claude-bridge/claude-live"),
                                                  root.appendingPathComponent("chat/sessions.json")], emitInitial: true)
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    guard !Task.isCancelled else { break }
                    await reload()
                }
            } onCancel: { events.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatGPTDotIPCTransport.didChange)) { _ in
            Task { await reload() }
        }
    }

    @MainActor private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        // Peers (under their lock), the lanes, Keychain and the conversations
        // file: all read off the main actor, once.
        let root = root
        let discovery = discovery
        let read = await Task.detached(priority: .utility) {
            Result {
                try AgentContactRow.read(dataRoot: root, candidates: discovery)
            }
        }.value
        guard generation == reloadGeneration else { return }
        loading = false
        switch read {
        case .success(let next):
            rows = next
            loadError = nil
        case .failure:
            loadError = "Could not load agent contacts. Refresh Agents to try again."
        }
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
