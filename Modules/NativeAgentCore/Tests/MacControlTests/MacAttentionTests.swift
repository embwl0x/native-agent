import Foundation
import Testing
@testable import MacControl

@Test
func attentionPointerCoalescingUsesElapsedTimeNotReceiptTime() {
    let coalescer = MacAttentionEventCoalescer()
    let firstReceipt = Date(timeIntervalSince1970: 10_000)
    let adjustedReceipt = firstReceipt.addingTimeInterval(-3_600)
    func receive(atUptime uptime: TimeInterval, receipt: Date) -> MacAttentionActivity? {
        guard coalescer.shouldEmit(kind: .pointerMoved, atUptime: uptime) else { return nil }
        return MacAttentionActivity(kind: .pointerMoved, occurredAt: receipt)
    }

    #expect(receive(atUptime: 100, receipt: firstReceipt)?.occurredAt == firstReceipt)
    #expect(receive(atUptime: 100.01, receipt: adjustedReceipt) == nil)
    #expect(receive(atUptime: 100.034, receipt: adjustedReceipt)?.occurredAt == adjustedReceipt)
    #expect(receive(atUptime: 100.05, receipt: firstReceipt.addingTimeInterval(3_600)) == nil)
    #expect(receive(atUptime: 100.068, receipt: adjustedReceipt)?.occurredAt == adjustedReceipt)
}

@Test
func attentionPointerCoalescingPreservesSharedMoveDragBoundAndImmediateActivity() {
    let coalescer = MacAttentionEventCoalescer()
    #expect(coalescer.shouldEmit(kind: .pointerMoved, atUptime: 0))
    #expect(!coalescer.shouldEmit(kind: .pointerDragged, atUptime: 0.01))
    #expect(coalescer.shouldEmit(kind: .pointerDragged, atUptime: 0.034))
    for kind: MacAttentionActivityKind in [
        .pointerPressed, .pointerReleased, .keyboardActivity, .scrolled,
    ] {
        #expect(coalescer.shouldEmit(kind: kind, atUptime: 0.035))
        #expect(coalescer.shouldEmit(kind: kind, atUptime: 0.035))
    }
    #expect(!coalescer.shouldEmit(kind: .pointerMoved, atUptime: 0.05))
    #expect(coalescer.shouldEmit(kind: .pointerMoved, atUptime: 0.068))
}

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

private actor AttentionWaitSleeper {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var cancelled = 0
    private(set) var finished = 0
    private(set) var requestedMilliseconds: [Int] = []
    let ignoresCancellation: Bool

    init(ignoresCancellation: Bool = false) { self.ignoresCancellation = ignoresCancellation }

    func sleep(milliseconds: Int) async throws {
        nextID += 1
        let id = nextID
        requestedMilliseconds.append(milliseconds)
        defer { finished += 1 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard pending[id] != nil else { return }
        cancelled += 1
        if !ignoresCancellation {
            pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    func finish(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
    var activeCount: Int { pending.count }
    func waitForStarted(_ count: Int) async {
        while nextID < count { await Task.yield() }
    }
    func waitForCancelled(_ count: Int) async {
        while cancelled < count { await Task.yield() }
    }
    func waitForFinished(_ count: Int) async {
        while finished < count { await Task.yield() }
    }
}

private actor AttentionWaitCompletion {
    private(set) var complete = false
    func markComplete() { complete = true }
}

@Test(.timeLimit(.minutes(1)))
func attentionCallbackFromReplacedSessionCannotInvalidateOrWakeCurrentSession() async throws {
    let sleeper = AttentionWaitSleeper()
    let completion = AttentionWaitCompletion()
    let viewStore = MacScreenViewStore()
    let store = MacAttentionSessionStore(screenViewStore: viewStore, waitSleep: {
        try await sleeper.sleep(milliseconds: $0)
    })
    let oldSource = AttentionManualSource()
    let old = try #require(await store.start(durationSeconds: 60, now: Date(), eventSource: oldSource))
    let currentSource = AttentionManualSource()
    let current = try #require(await store.start(durationSeconds: 60, now: Date(), eventSource: currentSource))
    #expect(oldSource.observation.isStopped)
    await viewStore.record(attentionSnapshot(id: "current-view", at: Date()))
    _ = await store.observed(sessionId: current.sessionId, viewId: "current-view", sequence: 0, userSequence: 0, now: Date())
    let wait = Task {
        let result = await store.waitForActivity(sessionId: current.sessionId, after: 0,
                                                 timeoutMilliseconds: 15_000, now: Date())
        await completion.markComplete()
        return result
    }
    await sleeper.waitForStarted(1)
    // Drive the exact actor entry used by the callback Task after it has been
    // queued. Awaiting it pins delivery order without arbitrary sleeps or UI.
    await store.record(MacAttentionActivity(kind: .pointerPressed), sessionId: old.sessionId)
    await store.record(MacAttentionActivity(kind: .appChanged, occurredAt: current.expiresAt.addingTimeInterval(1)),
                       sessionId: old.sessionId)
    let unchanged = try #require(await store.status(now: Date()))
    #expect(unchanged.sessionId == current.sessionId)
    #expect(unchanged.sequence == 0)
    #expect(unchanged.userSequence == 0)
    #expect(await viewStore.latestViewId() == "current-view")
    #expect(await completion.complete == false)
    #expect(await sleeper.activeCount == 1)
    #expect(await store.permissionForAction(sessionId: current.sessionId, observedUserSequence: 0, now: Date()) == .allowed)

    // The real injected-source callback is still admitted for its own session.
    currentSource.emit(MacAttentionActivity(kind: .pointerPressed))
    let changed = try #require(await wait.value)
    #expect(changed.sequence == 1)
    #expect(changed.userSequence == 1)
    #expect(changed.yieldRequired)
    #expect(!changed.timedOutWaiting)
    #expect(await viewStore.latestViewId() == nil)
    await sleeper.waitForCancelled(1)
    guard case .refused(let reason, _) = await store.permissionForAction(
        sessionId: current.sessionId, observedUserSequence: 0, now: Date()
    ) else {
        Issue.record("Current-session user input must still require takeover"); return
    }
    #expect(reason.contains("human_takeover"))
    _ = await store.stop()
    await viewStore.record(attentionSnapshot(id: "after-stop", at: Date()))
    await store.record(MacAttentionActivity(kind: .pointerPressed), sessionId: current.sessionId)
    #expect(await viewStore.latestViewId() == "after-stop")
}

@Test(.timeLimit(.minutes(1)))
func attentionEarlyActivityCancelsEveryOwnedWaitTimeout() async throws {
    let sleeper = AttentionWaitSleeper()
    let store = MacAttentionSessionStore(screenViewStore: MacScreenViewStore(), waitSleep: {
        try await sleeper.sleep(milliseconds: $0)
    })
    let source = AttentionManualSource()
    var current = try #require(await store.start(durationSeconds: 60, now: Date(), eventSource: source))
    for count in 1...8 {
        let previous = current
        let wait = Task {
            await store.waitForActivity(sessionId: previous.sessionId, after: previous.sequence,
                                        timeoutMilliseconds: 15_000, now: Date())
        }
        await sleeper.waitForStarted(count)
        source.emit(MacAttentionActivity(kind: .appChanged))
        current = try #require(await wait.value)
        #expect(current.sequence == previous.sequence + 1)
        #expect(!current.timedOutWaiting)
        await sleeper.waitForCancelled(count)
        #expect(await sleeper.activeCount == 0, "No old deadline remains after the event wakes its waiter")
    }
    #expect(await sleeper.requestedMilliseconds == Array(repeating: 15_000, count: 8))
    _ = await store.stop()
}

@Test(.timeLimit(.minutes(1)))
func attentionCancellationStopAndReplacementRetireTheirWaitTimeouts() async throws {
    for exit in ["cancel", "stop", "replace"] {
        let sleeper = AttentionWaitSleeper()
        let store = MacAttentionSessionStore(screenViewStore: MacScreenViewStore(), waitSleep: {
            try await sleeper.sleep(milliseconds: $0)
        })
        let initial = try #require(await store.start(durationSeconds: 60, now: Date(), eventSource: AttentionManualSource()))
        let wait = Task {
            await store.waitForActivity(sessionId: initial.sessionId, after: 0,
                                        timeoutMilliseconds: 15_000, now: Date())
        }
        await sleeper.waitForStarted(1)
        switch exit {
        case "cancel": wait.cancel()
        case "stop": _ = await store.stop()
        default: _ = await store.start(durationSeconds: 60, now: Date(), eventSource: AttentionManualSource())
        }
        let result = await wait.value
        if exit != "cancel" { #expect(result == nil) }
        await sleeper.waitForCancelled(1)
        #expect(await sleeper.activeCount == 0)
        _ = await store.stop()
    }
}

@Test(.timeLimit(.minutes(1)))
func attentionCancelledOldTimeoutCannotCompleteReplacementWait() async throws {
    let sleeper = AttentionWaitSleeper(ignoresCancellation: true)
    let completion = AttentionWaitCompletion()
    let store = MacAttentionSessionStore(screenViewStore: MacScreenViewStore(), waitSleep: {
        try await sleeper.sleep(milliseconds: $0)
    })
    let source = AttentionManualSource()
    let initial = try #require(await store.start(durationSeconds: 60, now: Date(), eventSource: source))
    let first = Task {
        await store.waitForActivity(sessionId: initial.sessionId, after: 0, timeoutMilliseconds: 15_000, now: Date())
    }
    await sleeper.waitForStarted(1)
    source.emit(MacAttentionActivity(kind: .appChanged))
    let changed = try #require(await first.value)
    await sleeper.waitForCancelled(1)
    let second = Task {
        let result = await store.waitForActivity(sessionId: changed.sessionId, after: changed.sequence,
                                                 timeoutMilliseconds: 15_000, now: Date())
        await completion.markComplete()
        return result
    }
    await sleeper.waitForStarted(2)
    await sleeper.finish(1) // Non-cooperative old sleeper returns after its task was cancelled.
    await sleeper.waitForFinished(1)
    #expect(await completion.complete == false)
    #expect(await sleeper.activeCount == 1)
    await sleeper.finish(2)
    let timedOut = try #require(await second.value)
    #expect(timedOut.timedOutWaiting)
    #expect(timedOut.sequence == changed.sequence)
    #expect(await completion.complete)
    _ = await store.stop()
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
