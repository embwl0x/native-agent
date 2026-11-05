import SwiftUI
import Combine
import NativeAgentShared
// Blueprint: | `DiagnosticsView.swift` | Diagnostics: the Mac's diagnostics face (checks, status, runs), then this iPhone's own readback: recent pushes, unverified Mac records and the connection |

// MARK: - Diagnostics

/// The Mac's diagnostics as the agent's face draws them, then what only this iPhone knows.
struct DiagnosticsView: View {
    private let sync = iCloudSyncEngine.shared
    @ObservedObject private var cloudReplies = iCloudBridge.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var pushReceipts = PushReceiptLedger.load()
    @State private var pushed: FaceDestination?

    var body: some View {
        let face = sync.faces["diagnostics"]?.face
        AlivePage(title: face?.title ?? "Diagnostics", line: face?.line) {
            MobileFaceRows(page: "diagnostics") { pushed = $0 }
            Section {
                if let failure = pushReceipts.failure { Text(failure) }
                else if pushReceipts.entries.isEmpty { Text("No pushes recorded on this iPhone.") }
                ForEach(pushReceipts.entries.prefix(8)) { entry in
                    LabeledContent(entry.source) {
                        Text(entry.receivedAt, style: .relative)
                    }
                }
            } header: { AliveEyebrow("Recent pushes") }
            let held = cloudReplies.failingMacRecords.values.filter(\.held).sorted { $0.firstRefusedAt < $1.firstRefusedAt }
            if !held.isEmpty {
                Section {
                    ForEach(held, id: \.message.id) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.message.metadata?["kind"] ?? "chat").font(.headline)
                            Text(entry.reason)
                            Text("Refused \(entry.attempts) times since \(entry.firstRefusedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                            Text(entry.message.id).font(.caption).textSelection(.enabled)
                        }
                    }
                } header: { AliveEyebrow("Mac records this iPhone holds") }
            }
            if let failure = cloudReplies.unverifiedRecordsError {
                Section { Text(failure) } header: { AliveEyebrow("Verification history unavailable") }
            }
            if !cloudReplies.unverifiedRecords.isEmpty {
                Section {
                    ForEach(cloudReplies.unverifiedRecords) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.kind).font(.headline)
                            Text("Sender: \(record.sender)")
                            Text(record.timestamp, style: .date)
                            Text(record.timestamp, style: .time)
                            Text(record.reason).font(.caption)
                            Text("Pairing version: \(record.pairingVersion)").font(.caption)
                            Text(record.id).font(.caption).textSelection(.enabled)
                        }
                    }
                } header: { AliveEyebrow("Unverified Mac records") }
            }
            Section {
                MobileReadingStat(
                    label: "State",
                    value: AliveConnection.line(bridgeClient.connection),
                    systemImage: "antenna.radiowaves.left.and.right"
                )

                MobileReadingStat(
                    label: "Pairing",
                    value: pairingStore.usesICloudTransport ? "iCloud" : "Not paired",
                    systemImage: "network"
                )

                if let lastSeen = bridgeClient.lastSeenAt {
                    LabeledContent("Last seen") {
                        Text(lastSeen, style: .relative).foregroundStyle(.secondary)
                    }
                }
                // Age advanced data from its own delivery; cache reads cannot refresh it.
                let syncState = StatusConnectionPresentation.syncState(
                    lastSyncedAt: iCloudSyncEngine.shared.transportDeliveryAt(screenGroup: "runs")
                )
                MobileReadingStat(
                    label: "Last synced",
                    value: StatusConnectionPresentation.cardValue(for: syncState),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                if let detail = StatusConnectionPresentation.detail(for: syncState) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: { AliveEyebrow("Connection") }
        }
        .navigationDestination(item: $pushed) { $0.view }
        .task { _ = await sync.refreshRunsSnapshot() }
        .onAppear { pushReceipts = PushReceiptLedger.load() }
        .onReceive(NotificationCenter.default.publisher(for: PushReceiptLedger.didChange).receive(on: RunLoop.main)) { _ in
            pushReceipts = PushReceiptLedger.load()
        }
    }
}
