import Foundation
import Testing
@testable import MacControl

final class AttentionManualObservation: MacAttentionObservation, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var isStopped = false

    func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }
}

final class AttentionManualSource: MacAttentionEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (MacAttentionActivity) -> Void)?
    let observation = AttentionManualObservation()

    var isAvailable: Bool { true }

    func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAttentionObservation {
        lock.lock()
        self.handler = handler
        lock.unlock()
        return observation
    }

    func emit(_ activity: MacAttentionActivity) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(activity)
    }
}

private func attentionSnapshot(id: String, at date: Date) -> MacScreenViewSnapshot {
    MacScreenViewSnapshot(
        viewId: id,
        capturedAt: date,
        scope: .focusedWindow,
        bounds: MacAXFrame(x: 0, y: 0, w: 100, h: 100),
        appName: "Test",
        windowTitle: "Window",
        marks: []
    )
}

func waitForUserSequence(
    _ expected: Int64,
    store: MacAttentionSessionStore
) async -> MacAttentionSnapshot? {
    for _ in 0..<100 {
        if let current = await store.status(now: Date()), current.userSequence >= expected {
            return current
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await store.status(now: Date())
}

@Suite("Explicit Mac attention")
struct MacAttentionTests {
    @Test("physical input invalidates the frozen view and requires re-observation")
    func physicalInputYieldsAndInvalidates() async throws {
        let viewStore = MacScreenViewStore()
        let store = MacAttentionSessionStore(screenViewStore: viewStore)
        let source = AttentionManualSource()
        let now = Date()
        let initial = try #require(await store.start(
            durationSeconds: 60,
            now: now,
            eventSource: source
        ))

        await viewStore.record(attentionSnapshot(id: "view-1", at: now))
        let observed = try #require(await store.observed(
            sessionId: initial.sessionId,
            viewId: "view-1",
            sequence: 0,
            userSequence: 0,
            now: now
        ))
        #expect(!observed.yieldRequired)
        #expect(await viewStore.latestViewId() == "view-1")
        #expect(await store.permissionForAction(
            sessionId: initial.sessionId,
            observedUserSequence: 0,
            now: now
        ) == .allowed)

        source.emit(MacAttentionActivity(
            kind: .pointerMoved,
            occurredAt: now.addingTimeInterval(0.1),
            pointerX: 42,
            pointerY: 24
        ))
        let interrupted = try #require(await waitForUserSequence(1, store: store))
        #expect(interrupted.yieldRequired)
        #expect(interrupted.lastActivity?.kind == .pointerMoved)
        #expect(await viewStore.latestViewId() == nil)

        guard case .refused(let reason, _) = await store.permissionForAction(
            sessionId: initial.sessionId,
            observedUserSequence: 0,
            now: now.addingTimeInterval(0.2)
        ) else {
            Issue.record("physical input should refuse the stale motor action")
            return
        }
        #expect(reason.contains("human_takeover"))
    }

    @Test("next wakes on an event without a refresh loop")
    func nextWakesOnEvent() async throws {
        let viewStore = MacScreenViewStore()
        let store = MacAttentionSessionStore(screenViewStore: viewStore)
        let source = AttentionManualSource()
        let initial = try #require(await store.start(
            durationSeconds: 60,
            now: Date(),
            eventSource: source
        ))

        let waiter = Task {
            await store.waitForActivity(
                sessionId: initial.sessionId,
                after: initial.sequence,
                timeoutMilliseconds: 2_000,
                now: Date()
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        source.emit(MacAttentionActivity(kind: .appChanged))
        let next = try #require(await waiter.value)
        #expect(next.sequence == 1)
        #expect(next.userSequence == 0)
        #expect(!next.yieldRequired)
        #expect(!next.timedOutWaiting)
    }

    @Test("an app change retires the scene without falsely claiming human takeover")
    func appChangeRequiresARefreshOnly() async throws {
        let viewStore = MacScreenViewStore()
        let store = MacAttentionSessionStore(screenViewStore: viewStore)
        let source = AttentionManualSource()
        let now = Date()
        let initial = try #require(await store.start(
            durationSeconds: 60,
            now: now,
            eventSource: source
        ))
        await viewStore.record(attentionSnapshot(id: "view-1", at: now))
        _ = try #require(await store.observed(
            sessionId: initial.sessionId,
            viewId: "view-1",
            sequence: 0,
            userSequence: 0,
            now: now
        ))

        source.emit(MacAttentionActivity(kind: .appChanged))
        let changed = try #require(await store.waitForActivity(
            sessionId: initial.sessionId,
            after: 0,
            timeoutMilliseconds: 2_000,
            now: now
        ))
        #expect(changed.sequence == 1)
        #expect(changed.userSequence == 0)
        #expect(changed.refreshRequired)
        #expect(!changed.yieldRequired)
        #expect(await viewStore.latestViewId() == nil)

        guard case .refused(let reason, _) = await store.permissionForAction(
            sessionId: initial.sessionId,
            observedUserSequence: 0,
            now: now
        ) else {
            Issue.record("an app change must retire the old scene")
            return
        }
        #expect(reason.contains("scene_changed"))
        #expect(!reason.contains("human_takeover"))
    }

    @Test("keyboard observation retains activity only, never key content")
    func keyboardIsContentFree() async throws {
        let viewStore = MacScreenViewStore()
        let store = MacAttentionSessionStore(screenViewStore: viewStore)
        let source = AttentionManualSource()
        let initial = try #require(await store.start(
            durationSeconds: 60,
            now: Date(),
            eventSource: source
        ))
        source.emit(MacAttentionActivity(kind: .keyboardActivity))
        let current = try #require(await waitForUserSequence(1, store: store))
        let encoded = try current.toJSON().serializedData(pretty: false)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("keyboard_activity"))
        #expect(!text.contains("keycode"))
        #expect(!text.contains("characters"))
        #expect(!text.contains("modifiers"))

        #expect(await store.stop())
        #expect(source.observation.isStopped)
        #expect(await store.status(now: Date()) == nil)
        _ = initial
    }

    @Test("actions cannot enter an active session before its first fused view")
    func firstViewRequired() async throws {
        let store = MacAttentionSessionStore(screenViewStore: MacScreenViewStore())
        let source = AttentionManualSource()
        let initial = try #require(await store.start(
            durationSeconds: 60,
            now: Date(),
            eventSource: source
        ))
        guard case .refused(let reason, _) = await store.permissionForAction(
            sessionId: initial.sessionId,
            observedUserSequence: 0,
            now: Date()
        ) else {
            Issue.record("an action must not race ahead of the initial fused view")
            return
        }
        #expect(reason.contains("scene_changed"))
    }

    @Test("agent motor provenance is bounded and monotonic")
    func motorEpochIsBounded() {
        NativeAgentMotorEpoch.resetForTesting()
        defer { NativeAgentMotorEpoch.resetForTesting() }
        let anchor: TimeInterval = 100
        NativeAgentMotorEpoch.noteAgentMotorEvent(atUptime: anchor)
        #expect(NativeAgentMotorEpoch.isAgentDriven(atUptime: anchor + 2.9))
        #expect(!NativeAgentMotorEpoch.isAgentDriven(atUptime: anchor + 3.1))
        #expect(!NativeAgentMotorEpoch.isAgentDriven(atUptime: anchor - 1))
    }
}
