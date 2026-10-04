import SwiftUI
import NativeAgentShared

struct MobileAgentsView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
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
                        NavigationLink { MobileAgentThreadView(agent: agent) } label: {
                            AliveRow(agent.name, detail: agent.lastExchange.isEmpty ? agent.via : agent.lastExchange) { AliveChevron() }
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

private struct MobileAgentThreadView: View {
    let agent: MobileAgentRow
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var chatStore: ChatStore
    @State private var thread: MobileAgentThread?
    @State private var draft = ""
    @State private var message: String?
    @State private var busy = false
    @State private var error: String?

    private var sendRestriction: String? {
        (thread?.agent ?? agent).sendRestriction
    }

    var body: some View {
        AlivePage(title: agent.name, line: thread?.agent.status ?? agent.via) {
            if let error { AliveSection("Couldn’t complete the request") { Text(error).aliveRow() } }
            AliveSection("Conversation") {
                if let thread {
                    if thread.lines.isEmpty { Text("No exchanges yet.").aliveRow() }
                    if thread.truncated { Text("Showing recent excerpts. The full conversation remains on the Mac.").aliveRow() }
                    ForEach(thread.lines) { line in
                        AliveCard {
                            Text(line.speaker)
                            Text(line.text).textSelection(.enabled)
                            Text(Date(timeIntervalSince1970: line.at), style: .date)
                        }
                    }
                } else { Text("Loading conversation…").aliveRow() }
            }
            AliveSection("Message") {
                if let restriction = sendRestriction {
                    Text(restriction).aliveRow()
                } else {
                    if let message { Text(message).aliveRow() }
                    TextField("Message \(agent.name)", text: $draft, axis: .vertical).lineLimit(2...8).aliveRow()
                    Button("Send") { Task { await refresh(send: true) } }.aliveRow()
                        .disabled(busy || !pairing.isPaired || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if busy { ProgressView("Waiting for Mac…").aliveRow() }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: sync.helpersSnapshot?.agents.first { $0.id == agent.id }) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh(send: Bool = false) async {
        guard !busy, !send || sendRestriction == nil else { return }
        busy = true; error = nil; message = nil
        let sentDraft = draft
        defer { busy = false }
        do {
            thread = try await sync.agentThreadAction(id: agent.id, text: send ? sentDraft : nil,
                                                     sessionID: chatStore.selectedSessionID ?? chatStore.mainSessionID)
            if send {
                if draft == sentDraft { draft = "" }
                message = "Message accepted by the Mac."
            }
        } catch { self.error = error.localizedDescription }
    }
}
