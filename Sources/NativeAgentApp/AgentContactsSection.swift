import ApprovalTransactions
import AppKit
import EngineRuntime
import SwiftUI
import NativeAgentCore
import AgentConversations
import PersistenceCore

// Blueprint: | `AgentContactsSection.swift` | `AgentContactsSection`: contact rows/actions from discovery state; offscreen capture reads never initiate discovery |

typealias AgentContactRow = EngineRuntime.AgentContactRow

struct AgentContactsSection: View {
    var refresh = 0
    var fixtureRows: [AgentContactRow]? = nil
    @Environment(AppModel.self) private var appModel
    private var contacts: ContactListFacade { appModel.engine.contacts }
    private var rows: [AgentContactRow] { contacts.rows }
    private var loadError: String? { contacts.loadError }
    private var loading: Bool { !contacts.loaded }
    @State private var busy = false
    @State private var refreshGeneration = 0
    private var root: URL { appModel.engine.dataRoot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            if let loadError {
                AgentContactReadFailure(message: loadError, dataRoot: root) { Task { _ = try? await contacts.refresh() } }
            }
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
                            GrokSecureSetupCard(dataRoot: root, contact: contact)
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
            _ = try? await contacts.refresh()
        }
        // A refresh offers what it finds (discovery.json, her wake), so the
        // offscreen copy never runs it.
        .liveTask(id: refresh + refreshGeneration) {
            guard fixtureRows == nil else { return }
            _ = await AgentDiscoverySession.shared.candidates(refresh: true, dataRoot: root)
            contacts.watch()
            _ = try? await contacts.refresh()
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

struct AgentContactReadFailure: View {
    let message: String
    let dataRoot: URL
    let retry: () -> Void

    var body: some View {
        let file = AgentPeerStore(dataRoot: dataRoot).fileURL
        ConnectorsNote(text: "The address book at \(file.path) could not load: \(message)", color: NativeAgentShell.trouble)
        HStack {
            Button("Reveal address book") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            Button("Try again", action: retry)
        }
    }
}
