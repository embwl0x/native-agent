import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `MobileAgentsView.swift` | Plain contact state/time rows and ID-resolved conversations; bounded request states and diagnostic disclosure retain shared readbacks, local drafts and submission state |

struct MobileAgentsView: View {
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairing: PairingStore
    @State private var error: String?

    var body: some View {
        AlivePage(title: "Agents", line: "Contacts and their latest exchanges.") {
            if !pairing.isPaired { AliveUnpairedReason() }
            if let error = sync.staleSnapshotGroups["helpers_agents"] ?? error {
                AliveSection("Couldn’t refresh agents") { Text(error).aliveRow() }
            }
            AliveSection("Contacts") {
                if let snapshot = sync.helpersSnapshot {
                    if snapshot.agents.isEmpty { Text("No connected agents yet.").aliveRow() }
                    ForEach(snapshot.agents) { agent in
                        NavigationLink { MobileAgentThreadView(id: agent.id) } label: {
                            AliveRow(agent.name, detail: MobileAgentPresentation.line(agent), detailLines: 1) { AliveChevron() }
                        }.aliveRowButtonStyle()
                        AliveDivider()
                    }
                    if snapshot.truncated { Text("Showing the first 100 helpers and agents.").aliveRow() }
                } else { Text("Not yet received from the Mac").aliveRow() }
            }
        }
        .macSyncErrorBanner()
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        error = await sync.refreshHelpersSnapshot() ? nil : "Keep the Mac app open, then pull to refresh."
    }
}

enum MobileAgentPresentation {
    static func line(_ agent: MobileAgentRow) -> String {
        let state = agent.stateLine ?? "State not reported"
        guard let at = agent.lastActivityAt, at.isFinite, at > 0 else { return state }
        return state + " · " + Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened)
    }
}

struct MobileAgentThreadView: View {
    let id: String
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairing: PairingStore
    @Environment(ChatStore.self) private var chatStore
    @State private var draft = ""
    @State private var message: String?
    @State private var busy = false
    @State private var error: String?
    private var thread: MobileAgentThread? { sync.agentThreads[id] }
    private var agent: MobileAgentRow? { sync.helpersSnapshot?.agents.first { $0.id == id } ?? thread?.agent }

    private var sendRestriction: String? {
        agent?.sendRestriction
    }

    var body: some View {
        AlivePage(title: agent?.name ?? "Agent", line: agent.map(MobileAgentPresentation.line) ?? "Conversation with another agent.") {
            if !pairing.isPaired { AliveUnpairedReason() }
            if let error { AliveSection("Couldn’t complete the request") { Text(error).aliveRow() } }
            AliveSection("Conversation") {
                if let thread {
                    if thread.lines.isEmpty { Text("No exchanges yet.").aliveRow() }
                    if thread.truncated { Text("Showing recent excerpts. The full conversation remains on the Mac.").aliveRow() }
                    ForEach(thread.lines) { line in
                        AliveCard {
                            Text(line.speaker)
                            Text(line.text).textSelection(.enabled)
                            Text(Date(timeIntervalSince1970: line.at).formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                } else if busy {
                    ProgressView("Reading conversation from the Mac…").aliveRow()
                } else {
                    Text(pairing.isPaired
                         ? "This conversation hasn’t reached this iPhone. Keep NativeAgent open on the Mac, then pull to refresh."
                         : "Pair with your Mac to read this conversation.").aliveRow()
                }
            }
            if let agent {
                AliveSection("Details") {
                    DisclosureGroup("Connection details") {
                        Text(agent.via)
                        if !agent.status.isEmpty { Text(agent.status).textSelection(.enabled) }
                        if !agent.lastExchange.isEmpty { Text(agent.lastExchange).textSelection(.enabled) }
                    }.aliveRow()
                }
            }
            AliveSection("Message") {
                if let restriction = sendRestriction {
                    Text(restriction).aliveRow()
                } else {
                    if let message { Text(message).aliveRow() }
                    TextField("Message \(agent?.name ?? "agent")", text: $draft, axis: .vertical).lineLimit(2...8).aliveRow()
                    Button("Send") { Task { await refresh(send: true) } }.aliveRow()
                        .disabled(busy || !pairing.isPaired || agent == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if busy { ProgressView("Waiting for Mac…").aliveRow() }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: agent) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh(send: Bool = false) async {
        guard !busy, !send || sendRestriction == nil else { return }
        guard pairing.isPaired else {
            error = "Pair with your Mac to read or send agent messages."
            return
        }
        busy = true; error = nil; message = nil
        let sentDraft = draft
        defer { busy = false }
        do {
            _ = try await sync.agentThreadAction(id: id, text: send ? sentDraft : nil,
                                                     sessionID: chatStore.selectedSessionID ?? chatStore.mainSessionID)
            if send {
                if draft == sentDraft { draft = "" }
                message = "Message accepted by the Mac."
            }
        } catch { self.error = error.localizedDescription }
    }
}
