import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / inspector.liveDropCount
//
// Drives the actual TurnTraceBus producer and the mounted Inspector store. It
// proves both meanings a live read must preserve: a measured overflow produces
// a visible count, while a retired subscription is unavailable rather than a
// success-shaped zero.

private actor InspectorLiveDropGate {
    private var subscription: UUID?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait(subscriptionID: UUID) async {
        subscription = subscriptionID
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func subscriptionID() -> UUID? { subscription }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func inspectorRuntimeDropEvent(_ ordinal: Int) -> TurnTraceEvent {
    TurnTraceEvent(
        turnId: "inspector-runtime-drop",
        ts: Date(timeIntervalSince1970: 1_700_000_000 + Double(ordinal)),
        kind: "tool.dispatch",
        sessionId: "inspector-runtime-eval",
        surface: "chat",
        payload: .object([:])
    )
}

@Suite("Inspector live drop-count runtime boundary", .serialized)
struct InspectorLiveDropCountEvalTests {
    @MainActor
    @Test("bus overflow is observed by the mounted Inspector read model")
    func overflowIsMeasuredAndRendered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-runtime-drop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let gate = InspectorLiveDropGate()
        let store = TurnInspectorStore(
            liveBus: bus,
            liveSubscriptionCapacity: 1,
            beforeLiveConsumption: { id in await gate.wait(subscriptionID: id) }
        )
        store.start()

        let subscriptionDeadline = Date().addingTimeInterval(2)
        while await gate.subscriptionID() == nil, Date() < subscriptionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.subscriptionID() != nil)

        for ordinal in 0..<8 {
            TurnTraceBus.fire(inspectorRuntimeDropEvent(ordinal), on: bus)
        }

        let overflowDeadline = Date().addingTimeInterval(2)
        while Date() < overflowDeadline {
            guard let id = await gate.subscriptionID() else { break }
            if case .available(let drops) = await bus.dropCountRead(id), drops > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await gate.release()

        let readDeadline = Date().addingTimeInterval(2)
        while store.liveDropCount == 0, Date() < readDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.liveDropCount > 0)
        #expect(store.liveDropCountState == .measured(store.liveDropCount))
        #expect(TurnInspectorLiveDropPresentation.label(for: store.liveDropCountState)
            == "\(store.liveDropCount) dropped")
        store.stop()
    }

    @MainActor
    @Test("retired bus subscription is rendered as unavailable, never zero drops")
    func retiredSubscriptionDoesNotClaimZeroDrops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-runtime-retired-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let gate = InspectorLiveDropGate()
        let store = TurnInspectorStore(
            liveBus: bus,
            beforeLiveConsumption: { id in await gate.wait(subscriptionID: id) }
        )
        store.start()

        let deadline = Date().addingTimeInterval(2)
        while await gate.subscriptionID() == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let id = await gate.subscriptionID() else {
            Issue.record("Inspector never subscribed to the runtime bus")
            store.stop()
            return
        }

        // The real producer owns this failure mode: retiring a sink finishes
        // its stream. Releasing the Inspector's held consumer lets its normal
        // lifecycle mark the count unavailable.
        await bus.unsubscribe(id)
        await gate.release()

        let unavailableDeadline = Date().addingTimeInterval(2)
        while store.liveDropCountState != .unavailable, Date() < unavailableDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.liveDropCountState == .unavailable)
        #expect(store.liveDropCount == 0)
        #expect(TurnInspectorLiveDropPresentation.label(for: store.liveDropCountState)
            == "drop count unavailable")
        store.stop()
    }
}
