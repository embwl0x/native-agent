import Foundation
import BackgroundLoops
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Coverage ledger: app.background / app.background.loop.desk_notify
///
/// The ordinary case for this self-gating loop is silence. This evaluation
/// therefore keeps an ordinary item beside the marked item in ONE real Desk
/// store, then proves the direct card alone crosses both delivery adapters and
/// that the durable notify stamp makes the next unchanged tick inert.
@Suite("app.background · desk notify loop", .serialized)
struct DeskNotifyLoopCoverageEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-notify-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("one marked Desk item delivers one card, its ordinary sibling stays quiet, and an unchanged second tick is idempotent")
    func directItemDeliversExactlyOnceWhileOrdinaryItemFilesNothing() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let marked = try await store.createItem(kind: .watch, project: "Alerts", title: "Direct item")
        let ordinary = try await store.createItem(kind: .watch, project: "Alerts", title: "Ordinary item")
        _ = try await store.setNotify(marked.handle, policy: NotifyPolicy(level: .direct))

        let delivery = DeskNotifyDeliveryCapture()
        let loop = BackgroundLoopsAssembly.makeDeskNotifyLoop(
            dataRoot: root,
            postMacNotification: { title, body in
                await delivery.record(channel: .mac, title: title, body: body)
                return true
            },
            postPairedDeviceNotification: { title, body in
                await delivery.record(channel: .paired, title: title, body: body)
                return true
            }
        )

        let first = await loop.tickOutcome()
        guard case .completed(let result) = first else {
            Issue.record("expected direct Desk notification delivery, got \(first)")
            return
        }
        #expect(result?.contains("sent 1 Desk notification") == true)

        let firstDelivery = await delivery.snapshot()
        #expect(firstDelivery.mac.count == 1)
        #expect(firstDelivery.paired.count == 1)
        #expect(firstDelivery.mac[0].title == "Desk · Alerts")
        #expect(firstDelivery.mac[0].body.contains("Direct item"))
        #expect(!firstDelivery.mac.contains { $0.body.contains("Ordinary item") })
        #expect(firstDelivery.mac == firstDelivery.paired)

        let stateAfterFirst = try await store.liveState()
        let markedAfterFirst = try #require(stateAfterFirst.items.first { $0.handle == marked.handle })
        let ordinaryAfterFirst = try #require(stateAfterFirst.items.first { $0.handle == ordinary.handle })
        #expect(markedAfterFirst.notify.lastNotifiedAt != nil)
        #expect(ordinaryAfterFirst.notify.lastNotifiedAt == nil)

        let second = await loop.tickOutcome()
        #expect(second == .skipped(reason: "no Desk notification due"))
        #expect(await delivery.snapshot() == firstDelivery,
                "the persisted notify stamp must suppress a duplicate card for an unchanged item")
    }
}

private actor DeskNotifyDeliveryCapture {
    enum Channel: Sendable { case mac, paired }

    struct Card: Sendable, Equatable {
        let title: String
        let body: String
    }

    struct Snapshot: Sendable, Equatable {
        let mac: [Card]
        let paired: [Card]
    }

    private var mac: [Card] = []
    private var paired: [Card] = []

    func record(channel: Channel, title: String, body: String) {
        switch channel {
        case .mac:
            mac.append(Card(title: title, body: body))
        case .paired:
            paired.append(Card(title: title, body: body))
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(mac: mac, paired: paired)
    }
}
