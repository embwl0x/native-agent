import SwiftUI
import Foundation
import Combine
import NativeAgentShared
// Blueprint: | `DiagnosticsView.swift` | Mac diagnostics face and phone push, verification, refusal and connection evidence |

// MARK: - Diagnostics

/// The Mac's diagnostics as the agent's face draws them, then what only this iPhone knows.
struct DiagnosticsView: View {
    private let sync = iCloudSyncEngine.shared
    @ObservedObject private var cloudReplies = iCloudBridge.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var pushReceipts: PushReceiptLedger.Reading?
    @State private var pushed: FaceDestination?

    var body: some View {
        let face = sync.faces["diagnostics"]?.face
        AlivePage(title: face?.title ?? "Diagnostics", line: face?.line) {
            MobileFaceRows(page: "diagnostics") { pushed = $0 }
            FaceView(face: localFace, door: ReadOnlyFaceDoor(), session: sync.pageSessions.page("phone-diagnostics"))
        }
        .navigationDestination(item: $pushed) { $0.view }
        .task {
            pushReceipts = await Self.readPushReceipts()
            _ = await sync.refreshRunsSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: PushReceiptLedger.didChange).receive(on: RunLoop.main)) { _ in
            Task { pushReceipts = await Self.readPushReceipts() }
        }
    }

    @concurrent nonisolated private static func readPushReceipts() async -> PushReceiptLedger.Reading {
        PushReceiptLedger.load()
    }

    private var localFace: PartFace {
        let pushRows: [PartFace.Row]
        if let reading = pushReceipts {
            if let failure = reading.failure { pushRows = [.init(id: "failure", title: failure, tone: .failed)] }
            else if reading.entries.isEmpty { pushRows = [.init(id: "empty", title: "No pushes recorded on this iPhone.")] }
            else { pushRows = reading.entries.prefix(8).map { .init(id: $0.id, title: $0.source, at: $0.receivedAt.ISO8601Format()) } }
        } else { pushRows = [.init(id: "waiting", title: "Reading this iPhone's push receipts…")] }
        var sections: [PartFace.Section] = [.init(id: "pushes", title: "Recent pushes", rows: pushRows)]
        let refused = cloudReplies.failingMacRecords.values.sorted { $0.firstRefusedAt < $1.firstRefusedAt }
        if !refused.isEmpty {
            sections.append(.init(id: "refused", title: "Mac records this iPhone holds", rows: refused.map { entry in
                .init(id: entry.message.id, title: entry.message.metadata?["kind"] ?? "chat", detail: entry.reason,
                    value: entry.message.id, at: entry.firstRefusedAt.ISO8601Format())
            }))
        }
        if let error = cloudReplies.unverifiedRecordsError {
            sections.append(.init(id: "verification-error", title: "Verification history unavailable", rows: [
                .init(id: "cause", title: error, tone: .failed)
            ]))
        }
        if !cloudReplies.unverifiedRecords.isEmpty {
            sections.append(.init(id: "unverified", title: "Unverified Mac records", rows: cloudReplies.unverifiedRecords.map { record in
                .init(id: record.id, title: record.kind, detail: record.reason,
                    value: "Sender: \(record.sender) · Pairing version: \(record.pairingVersion) · \(record.id)",
                    at: record.timestamp.ISO8601Format())
            }))
        }
        var rows: [PartFace.Row] = [.init(id: "state", title: "State", value: AliveConnection.line(bridgeClient.connection)),
            .init(id: "pairing", title: "Pairing", value: pairingStore.usesICloudTransport ? "iCloud" : "Not paired")]
        if let lastSeen = bridgeClient.lastSeenAt { rows.append(.init(id: "seen", title: "Last seen", at: lastSeen.ISO8601Format())) }
        let state = StatusConnectionPresentation.syncState(lastSyncedAt: sync.transportDeliveryAt(screenGroup: "runs"))
        rows.append(.init(id: "sync", title: "Last synced", detail: StatusConnectionPresentation.detail(for: state),
            value: StatusConnectionPresentation.cardValue(for: state)))
        sections.append(.init(id: "connection", title: "Connection", rows: rows))
        return .init(sections: sections)
    }
}
