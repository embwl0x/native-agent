import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.inspector.liveDropCountBadge
//
// Exercises the production generation-guarded drop poll with real Inspector
// subscriptions, a controllable bus-count reader, and the exact ingest helper
// used by live events. A stopped generation may finish late, but it must never
// overwrite or delay the reopened Inspector's current warning badge.

private actor InspectorSubscriptionCapture {
    private var ids: [UUID] = []

    func record(_ id: UUID) { ids.append(id) }
    func id(at index: Int) -> UUID? {
        guard ids.indices.contains(index) else { return nil }
        return ids[index]
    }
}

private actor InspectorDropCountStub {
    private var values: [UUID: Int] = [:]
    private var held: Set<UUID> = []
    private var readIDs: Set<UUID> = []
    private var continuations: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func set(_ value: Int, for id: UUID) { values[id] = value }
    func hold(_ id: UUID) { held.insert(id) }
    func wasRead(_ id: UUID) -> Bool { readIDs.contains(id) }

    func release(_ id: UUID) {
        held.remove(id)
        let waiting = continuations.removeValue(forKey: id) ?? []
        waiting.forEach { $0.resume() }
    }

    func read(_ id: UUID) async -> Int {
        readIDs.insert(id)
        while held.contains(id) {
            await withCheckedContinuation { continuation in
                guard held.contains(id) else {
                    continuation.resume()
                    return
                }
                continuations[id, default: []].append(continuation)
            }
        }
        return values[id] ?? 0
    }
}

private func inspectorDropEvalEvent(_ id: String) -> TurnTraceEvent {
    TurnTraceEvent(
        turnId: id,
        ts: Date(timeIntervalSince1970: 1_700_000_000),
        kind: "tool.dispatch",
        sessionId: "inspector-eval",
        surface: "chat",
        payload: .object([:])
    )
}

@Test @MainActor
func inspectorLiveDropBadgeKeepsOnlyTheCurrentGenerationCount() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("inspector-drop-badge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let subscriptions = InspectorSubscriptionCapture()
    let drops = InspectorDropCountStub()
    let store = TurnInspectorStore(
        liveBus: bus,
        beforeLiveConsumption: { id in await subscriptions.record(id) },
        liveDropCountReader: { _, id in await drops.read(id) }
    )

    store.start()
    let firstDeadline = Date().addingTimeInterval(2)
    while Date() < firstDeadline {
        if await subscriptions.id(at: 0) != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let firstID = await subscriptions.id(at: 0)
    #expect(firstID != nil)
    guard let firstID else {
        store.stop()
        return
    }

    await drops.set(11, for: firstID)
    await drops.hold(firstID)
    store._appendLiveForTesting(inspectorDropEvalEvent("first"), subscriptionID: firstID)
    let firstPollDeadline = Date().addingTimeInterval(2)
    while Date() < firstPollDeadline {
        if await drops.wasRead(firstID) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await drops.wasRead(firstID))

    // Reopening immediately clears the old count, even while that old bus
    // query is still suspended. The new generation must not wait for it.
    store.stop()
    store.start()
    #expect(store.liveDropCount == 0)

    let secondDeadline = Date().addingTimeInterval(2)
    while Date() < secondDeadline {
        if await subscriptions.id(at: 1) != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let secondID = await subscriptions.id(at: 1)
    #expect(secondID != nil)
    guard let secondID else {
        await drops.release(firstID)
        store.stop()
        return
    }

    await drops.set(3, for: secondID)
    store._appendLiveForTesting(inspectorDropEvalEvent("second"), subscriptionID: secondID)
    let secondPollDeadline = Date().addingTimeInterval(2)
    while store.liveDropCount != 3, Date() < secondPollDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.liveDropCount == 3)
    #expect(TurnInspectorLiveDropPresentation.label(for: store.liveDropCount) == "3 dropped")

    await drops.release(firstID)
    try await Task.sleep(for: .milliseconds(20))
    #expect(store.liveDropCount == 3)
    store.stop()
}
