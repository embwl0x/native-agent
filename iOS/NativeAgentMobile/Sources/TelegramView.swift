import SwiftUI
import NativeAgentShared

struct TelegramView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var snapshot: MobileTelegramSnapshot?
    @State private var saving = false
    @State private var failure: String?
    @State private var snapshotFailure: String?
    @State private var showDisconnect = false
    @State private var showAccessChange = false
    @State private var pendingAccessChange: MobileTelegramChange?

    var body: some View {
        AlivePage(title: "Telegram", line: "Telegram settings on your Mac.") {
            if !pairingStore.isPaired { AliveUnpairedReason() }
            if let failure = failure ?? snapshotFailure {
                AliveSection("Telegram unavailable") { Text(failure).aliveRow() }
            }
            if let snapshot {
                AliveSection("Connection") {
                    AliveRow("Bot token", detail: snapshot.tokenConfigured ? "Saved on your Mac" : "Not set up") { EmptyView() }
                    AliveDivider()
                    AliveRow("Telegram poll loop", detail: snapshot.pollerRunning ? "Running" : "Not running") { EmptyView() }
                    AliveDivider()
                    AliveRow("Set up on your Mac", detail: "Open Telegram on your Mac to add or replace the bot token. Tokens cannot be sent through iCloud.") { EmptyView() }
                }
                AliveSection("Who can reach me") {
                    Toggle("Telegram is on", isOn: Binding(
                        get: { snapshot.enabled },
                        set: { value in
                            if value { confirmAccessChange(.enabled(true)) }
                            else { Task { await change(.enabled(false)) } }
                        }
                    )).aliveRow()
                    AliveDivider()
                    Toggle("Only answer when mentioned in a group", isOn: Binding(
                        get: { snapshot.requireMention },
                        set: { value in
                            if value { Task { await change(.requireMention(true)) } }
                            else { confirmAccessChange(.requireMention(false)) }
                        }
                    )).aliveRow()
                    AliveDivider()
                    AliveRow("Allowed chat IDs", detail: snapshot.allowedChatIDs.isEmpty ? "None" : snapshot.allowedChatIDs.joined(separator: ", ")) { EmptyView() }
                    AliveDivider()
                    AliveRow("Allowed user IDs", detail: snapshot.allowedUserIDs.isEmpty ? "None" : snapshot.allowedUserIDs.joined(separator: ", ")) { EmptyView() }
                }
                .disabled(!pairingStore.isPaired || saving || !snapshot.tokenConfigured)

                AliveSection("Model") {
                    AliveRow("Follows Chat: \(snapshot.model)") { EmptyView() }
                }

                if snapshot.tokenConfigured {
                    AliveSection("Actions") {
                        Button("Disconnect Telegram", role: .destructive) { showDisconnect = true }
                            .disabled(!pairingStore.isPaired || saving)
                            .aliveRow()
                    }
                }
                if saving { Text("Waiting for your Mac…").aliveRow() }
            } else if failure == nil && snapshotFailure == nil {
                AliveCalmState(title: "Not yet received from the Mac", line: "Open NativeAgent on your Mac to publish Telegram settings.")
            }
        }
        .macSyncErrorBanner()
        .task { await refresh() }
        .onChange(of: sync.lastSyncAt) { _, _ in Task { await readSnapshot() } }
        .refreshable { await refresh() }
        .confirmationDialog("Disconnect Telegram?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await change(.disconnect) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved bot token and disables Telegram until new credentials are saved.")
        }
        .confirmationDialog(TelegramAccessConfirmation.title, isPresented: $showAccessChange, titleVisibility: .visible) {
            Button(TelegramAccessConfirmation.action) {
                if let pendingAccessChange { Task { await change(pendingAccessChange) } }
                pendingAccessChange = nil
            }
            Button("Cancel", role: .cancel) { pendingAccessChange = nil }
        } message: {
            Text(TelegramAccessConfirmation.message)
        }
    }

    private func confirmAccessChange(_ change: MobileTelegramChange) {
        pendingAccessChange = change
        showAccessChange = true
    }

    private func adopt(_ value: MobileTelegramSnapshot) {
        guard value.observedAt >= (snapshot?.observedAt ?? 0) else { return }
        snapshot = value
    }

    private func refresh() async {
        failure = nil
        await readSnapshot()
    }

    private func readSnapshot() async {
        guard !saving else { return }
        if let value: MobileTelegramSnapshot = await sync.loadSnapshotObjectAsync(named: "telegram.json") {
            guard !saving else { return }
            adopt(value)
            snapshotFailure = sync.staleSnapshotGroups["telegram"]
        } else {
            snapshotFailure = "Telegram settings have not arrived or could not be read. Open NativeAgent on your Mac, then refresh."
        }
    }

    private func change(_ change: MobileTelegramChange) async {
        guard !saving, pairingStore.isPaired else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            adopt(try await sync.changeTelegram(change))
        } catch {
            failure = "Telegram change failed: \(error.localizedDescription)"
        }
    }
}
