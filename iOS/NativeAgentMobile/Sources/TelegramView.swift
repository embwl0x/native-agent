import SwiftUI
import NativeAgentShared
// Blueprint: | `TelegramView.swift` | `TelegramView` struct; reads the shared revision-ordered Telegram projection |

struct TelegramView: View {
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    private var snapshot: MobileTelegramSnapshot? { sync.telegram }
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
        .refreshable { await refresh() }
        .confirmationDialog("Disconnect Telegram?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await disconnectTelegram() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved bot token and disables Telegram until new credentials are saved.")
        }
    }

    private func refresh() async {
        failure = nil
        await readSnapshot()
        await sync.refreshAppSettings()
    }

    private func readSnapshot() async {
        if await sync.refreshTelegramSnapshot() {
            snapshotFailure = sync.staleSnapshotGroups["telegram"]
        } else {
            snapshotFailure = "Telegram settings have not arrived or could not be read. Open NativeAgent on your Mac, then refresh."
        }
    }

    private func disconnectTelegram() async {
        guard !saving, pairingStore.isPaired else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            _ = try await sync.disconnectTelegram()
        } catch {
            failure = "Telegram change failed: \(error.localizedDescription)"
        }
    }
}
