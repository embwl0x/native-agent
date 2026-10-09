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
                    AliveRow("Telegram poll loop", detail: snapshot.pollStatusMessage ?? (snapshot.pollerRunning ? "Running" : "Not running")) { EmptyView() }
                    AliveDivider()
                    AliveRow("Last successful poll", detail: snapshot.lastSuccessfulPollAt.map(UserDisplayFormatters.humanizeISOTimestamp) ?? "None") { EmptyView() }
                    AliveDivider()
                    AliveRow("Set up on your Mac", detail: "Open Telegram on your Mac to add or replace the bot token. Tokens cannot be sent through iCloud.") { EmptyView() }
                }
                MobileAppSettingsSections(pages: ["telegram"], title: "Who can reach me")

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
    }

    private func adopt(_ value: MobileTelegramSnapshot) {
        guard value.observedAt >= (snapshot?.observedAt ?? 0) else { return }
        snapshot = value
    }

    private func refresh() async {
        failure = nil
        await readSnapshot()
        await MobileAppSettingsStore.shared.refresh()
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
