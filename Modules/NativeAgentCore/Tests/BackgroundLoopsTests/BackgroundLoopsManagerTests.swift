import Testing
import Foundation
@testable import BackgroundLoops

// Tests for the unified 6-loop BackgroundLoopsManager. The manager is the
// public actor the AppDelegate spins on launch; tests verify the
// start / cancel / status surface against 6 stub loops standing in for the
// real auto-doctor / harness / dream / REM / memory / self-improvement
// loops that the app target wires.

private struct StubLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval
    let onTick: @Sendable () -> Void
    init(_ id: String, interval: TimeInterval = 0.05, onTick: @escaping @Sendable () -> Void = {}) {
        self.loopId = id
        self.interval = interval
        self.onTick = onTick
    }
    func tickOutcome() async -> LoopTickOutcome { onTick(); return .completed(result: nil) }
}

private struct AsyncStubLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval
    let onTick: @Sendable () async -> Void

    init(
        _ id: String,
        interval: TimeInterval = 86_400,
        onTick: @escaping @Sendable () async -> Void = {}
    ) {
        self.loopId = id
        self.interval = interval
        self.onTick = onTick
    }

    func tickOutcome() async -> LoopTickOutcome { await onTick(); return .completed(result: nil) }
}

private struct OutcomeStubLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval = 86_400
    let outcome: LoopTickOutcome

    func tickOutcome() async -> LoopTickOutcome { outcome }
}

private struct TimeoutStubLoop: LoopRunner {
    let loopId = "timeout"
    let interval: TimeInterval = 86_400
    var tickTimeoutOverride: TimeInterval? { 0.01 }

    func tickOutcome() async -> LoopTickOutcome {
        try? await Task.sleep(for: .seconds(5))
        return .completed(result: nil)
    }
}

/// A loop with a short tick budget whose body ignores cooperative
/// cancellation — the exact shape that used to wedge the single-flight gate
/// forever after one timeout.
private struct WedgedTimeoutStubLoop: LoopRunner {
    let loopId = "wedged_timeout"
    let interval: TimeInterval = 86_400
    var tickTimeoutOverride: TimeInterval? { 0.05 }
    let onTick: @Sendable () async -> Void

    func tickOutcome() async -> LoopTickOutcome {
        await onTick()
        return .completed(result: nil)
    }
}

private final class PhysiologyEventSource: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func emit() { continuation.yield(()) }
}

private actor PhysiologyDeadlineState {
    var deadline: Date?
    init(_ deadline: Date? = nil) { self.deadline = deadline }
    func read() -> Date? { deadline }
    func set(_ value: Date?) { deadline = value }
    func clear() { deadline = nil }
}

private struct PhysiologyStubLoop: EventDeadlineLoopRunner {
    let loopId: String
    let interval: TimeInterval = 86_400
    let eventCoalescingDelay: TimeInterval
    let source: PhysiologyEventSource
    let counter: TickCounter
    let deadlineState: PhysiologyDeadlineState

    func tickOutcome() async -> LoopTickOutcome {
        await counter.bump()
        if let due = await deadlineState.read(), due <= Date() {
            await deadlineState.clear()
        }
        return .completed(result: nil)
    }

    func physiologyEvents() -> AsyncStream<Void> { source.stream }
    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        await deadlineState.read()
    }
}

private func stubManifest() -> [any LoopRunner] {
    [
        StubLoop("doctor_auto_run"),
        StubLoop("harness_learning"),
        StubLoop("memory_consolidation"),
        StubLoop("self_improvement_sweep"),
        StubLoop("dream_cycle"),
        StubLoop("rem_cycle"),
    ]
}

@Suite("BackgroundLoopsManager")
struct BackgroundLoopsManagerTests {

    @Test("one-shot execution returns the typed loop outcome")
    func oneShotReturnsTypedOutcome() async {
        let expected = LoopTickOutcome.failed(error: "provider unavailable")
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [
            OutcomeStubLoop(loopId: "manual", outcome: expected),
        ])

        #expect(await manager.runTickOnce(loopId: "manual") == expected)
        #expect(await manager.status().first { $0.name == "manual" }?.lastError == "provider unavailable")
        #expect(
            await manager.runTickOnce(loopId: "missing")
                == .failed(error: "loop not registered: missing")
        )
        await manager.stop()
    }

    @Test("one-shot timeout returns failure and records it")
    func oneShotTimeoutIsTypedAndRecorded() async {
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [TimeoutStubLoop()])

        let outcome = await manager.runTickOnce(loopId: "timeout")
        guard case .failed(let error) = outcome else {
            Issue.record("expected timeout failure, got \(outcome)")
            await manager.stop()
            return
        }
        #expect(error.contains("timeout after"))
        #expect(await manager.status().first { $0.name == "timeout" }?.lastError == error)
        await manager.stop()
    }

    @Test("start registers all 6 loops with non-nil nextRun")
    func startRegistersAll6() async {
        let manager = BackgroundLoopsManager()
        await manager.start(loops: stubManifest())
        let status = await manager.status()
        #expect(status.count == 6)
        let names = Set(status.map(\.name))
        #expect(names == Set([
            "doctor_auto_run",
            "harness_learning",
            "memory_consolidation",
            "self_improvement_sweep",
            "dream_cycle",
            "rem_cycle",
        ]))
        // Every loop should have a forward-looking nextRun seeded by the
        // scheduler at spawn time.
        for s in status {
            #expect(s.nextRun != nil, "loop \(s.name) missing nextRun")
        }
        #expect(await manager.isRunning() == true)
        await manager.stop()
    }

    @Test("stop cancels every running tick task")
    func stopCancelsTasks() async {
        let manager = BackgroundLoopsManager()
        await manager.start(loops: stubManifest())
        #expect(await manager.isRunning() == true)
        await manager.stop()
        #expect(await manager.isRunning() == false)
    }

    @Test("status lastRun updates after a tick lands")
    func statusUpdatesAfterTick() async throws {
        let counter = TickCounter()
        let fastLoop = StubLoop("fast", interval: 0.05) {
            Task { await counter.bump() }
        }
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [fastLoop])
        // Wait for at least one tick to land.
        var ticks = 0
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            ticks = await counter.value
            if ticks > 0 { break }
        }
        #expect(ticks > 0, "expected at least one tick to land")
        let status = await manager.status()
        let s = try #require(status.first { $0.name == "fast" })
        #expect(s.lastRun != nil)
        #expect(s.runCount >= 1)
        await manager.stop()
    }

    @Test("periodic tick and OS wake coalesce into one execution")
    func periodicAndOSWakeCoalesce() async throws {
        let probe = SuspendedTickProbe()
        let loop = AsyncStubLoop("coalesced_tick") {
            await probe.tick()
        }
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [loop])

        let periodic = Task {
            await manager._testRunPeriodicTick(loopId: loop.loopId)
        }
        await probe.waitUntilStarted()
        let osWake = Task {
            await manager.runTickOnce(loopId: loop.loopId)
        }
        await manager._testWaitForCoalescedRequest(loopId: loop.loopId)
        await probe.release()
        await periodic.value
        #expect(await osWake.value == .skipped(reason: "coalesced with active tick"))

        #expect(await probe.value == 1)
        let status = try #require(await manager.status().first { $0.name == loop.loopId })
        #expect(status.runCount == 1)
        await manager.stop()
    }

    @Test("a cancelled coalesced join resumes instead of leaking behind a wedged tick")
    func cancelledCoalescedJoinResumes() async throws {
        // 2026-07-21 audit (MED): pre-fix, cancelling the joining Task left its
        // continuation parked in the gate's idleWaiters forever when the active
        // tick ignored cancellation — the joiner below would never complete.
        let probe = SuspendedTickProbe()
        let loop = AsyncStubLoop("wedged_tick") {
            await probe.tick()
        }
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [loop])

        let periodic = Task {
            await manager._testRunPeriodicTick(loopId: loop.loopId)
        }
        await probe.waitUntilStarted()
        let joinCounter = TickCounter()
        let joiner = Task {
            _ = await manager.runTickOnce(loopId: loop.loopId)
            await joinCounter.bump()
        }
        await manager._testWaitForCoalescedRequest(loopId: loop.loopId)
        joiner.cancel()

        // The active tick is still wedged, but the cancelled joiner must
        // resume promptly. Poll with a hard bound so a regression fails
        // loudly instead of hanging the suite.
        var resumed = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if await joinCounter.value > 0 { resumed = true; break }
        }
        #expect(resumed, "cancelled coalesced join never resumed — continuation leaked")

        await probe.release()
        await periodic.value
        #expect(await probe.value == 1)
        await manager.stop()
    }

    @Test("a timed-out uncancellable tick force-releases the gate so the next tick runs")
    func timedOutWedgedTickDoesNotWedgeTheGate() async throws {
        // Pre-fix: ManagedLoopRunner awaited `underlying.tickOutcome()`
        // directly, so when the manager's timeout cancelled the tick task and
        // the loop body ignored cancellation, `gate.finish` never ran. The
        // gate stayed active forever and EVERY later tick coalesced into a
        // skip — a permanently dead loop behind a single timeout receipt.
        let probe = SuspendedTickProbe()
        let loop = WedgedTimeoutStubLoop { await probe.tick() }
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [loop])

        let first = await manager.runTickOnce(loopId: loop.loopId)
        guard case .failed(let firstError) = first else {
            Issue.record("expected the wedged first tick to time out, got \(first)")
            await probe.release()
            await manager.stop()
            return
        }
        #expect(firstError.hasPrefix("timeout after"))

        // A subsequent request must RUN the underlying loop rather than
        // coalesce. Entry count is the only honest verdict here: a coalesced
        // joiner is itself cancelled by the same tick timeout, so the returned
        // outcome is `.failed(timeout…)` either way and cannot discriminate.
        // The force-release also lands one actor hop after the timeout throws,
        // so a single follow-up may legitimately still join — but a join waits
        // for idle, so a bounded retry converges. Pre-fix, entries stayed at 1
        // forever no matter how many attempts were made.
        var entries = await probe.value
        attempts: for _ in 0..<3 {
            _ = await manager.runTickOnce(loopId: loop.loopId)
            // The wedged body is entered from an unstructured child, so observe
            // the entry by bounded polling rather than a bare sleep.
            for _ in 0..<20 {
                entries = await probe.value
                if entries >= 2 { break attempts }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        #expect(entries >= 2, "gate stayed wedged — underlying loop never ran again (entries=\(entries))")

        await probe.release()
        await manager.stop()
    }

    @Test("Telegram replacement preserves every unrelated task and counter")
    func telegramReplacementIsTargeted() async throws {
        let ids = [
            "cognition_microcycle",
            "mission_executor",
            "slack_socket_mode",
            "heartbeat",
            "self_improvement_sweep",
        ]
        let oldTelegramCounter = TickCounter()
        let newTelegramCounter = TickCounter()
        let manifest: [any LoopRunner] = ids.map { AsyncStubLoop($0) }
            + [AsyncStubLoop("telegram_poll") { await oldTelegramCounter.bump() }]
        let manager = BackgroundLoopsManager()
        await manager.start(loops: manifest)

        for id in ids {
            await manager.runTickOnce(loopId: id)
        }
        let before = Dictionary(uniqueKeysWithValues: await manager.status().map {
            ($0.name, $0.runCount)
        })
        var preservedTasks: [Task<Void, Never>] = []
        for id in ids {
            let handle = await manager._testTaskHandle(loopId: id)
            preservedTasks.append(try #require(handle))
        }
        let oldTelegramTask = try #require(
            await manager._testTaskHandle(loopId: "telegram_poll")
        )

        await manager.restartLoop(
            id: "telegram_poll",
            newLoop: AsyncStubLoop("telegram_poll") { await newTelegramCounter.bump() }
        )

        #expect(oldTelegramTask.isCancelled)
        #expect(preservedTasks.allSatisfy { !$0.isCancelled })
        #expect(Set(await manager.registered()) == Set(ids + ["telegram_poll"]))
        let after = Dictionary(uniqueKeysWithValues: await manager.status().map {
            ($0.name, $0.runCount)
        })
        for id in ids {
            #expect(after[id] == before[id])
        }

        await manager.runTickOnce(loopId: "telegram_poll")
        #expect(await oldTelegramCounter.value == 0)
        #expect(await newTelegramCounter.value == 1)
        await manager.stop()
    }

    @Test("event physiology coalesces bursts and stays idle without signals")
    func physiologyBurstAndIdle() async throws {
        let source = PhysiologyEventSource()
        let counter = TickCounter()
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [
            PhysiologyStubLoop(
                loopId: "event_lane",
                eventCoalescingDelay: 0.01,
                source: source,
                counter: counter,
                deadlineState: PhysiologyDeadlineState()
            ),
        ])

        await manager._testWaitForPhysiologyStartup(loopId: "event_lane")
        #expect(await counter.value == 1)
        let reconciled = await counter.value
        for _ in 0..<50 { source.emit() }
        await counter.waitUntil(atLeast: reconciled + 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await counter.value == reconciled + 1)
        await manager.stop()
    }

    @Test("exact physiology deadline survives startup reconciliation")
    func physiologyExactDeadline() async throws {
        let source = PhysiologyEventSource()
        let counter = TickCounter()
        // Keep wall-clock scheduling out of this invariant test. The test
        // verifies that startup reconciliation preserves the exact deadline
        // and that the manager's deadline CAS fires it once; a heavily loaded
        // full-suite process must not be able to expire the fixture first.
        let deadline = Date().addingTimeInterval(60)
        let deadlineState = PhysiologyDeadlineState(deadline)
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [
            PhysiologyStubLoop(
                loopId: "deadline_lane",
                eventCoalescingDelay: 0,
                source: source,
                counter: counter,
                deadlineState: deadlineState
            ),
        ])

        await manager._testWaitForPhysiologyStartup(loopId: "deadline_lane")
        #expect(await counter.value == 1)
        #expect(await manager._testPhysiologyDeadline(loopId: "deadline_lane") == deadline)
        // At a real threshold crossing the owner consumes its due state during
        // the tick. Mirror that owner-side transition before invoking the
        // manager's deterministic deadline hook.
        await deadlineState.clear()
        await manager._testFirePhysiologyDeadline(loopId: "deadline_lane")
        #expect(await counter.value == 2)
        #expect(await manager._testPhysiologyDeadline(loopId: "deadline_lane") == nil)
        await manager.stop()
    }

    @Test("restart reconciles a physiology event missed while stopped")
    func physiologyRestartReconcilesMissedEvent() async throws {
        let source = PhysiologyEventSource()
        let counter = TickCounter()
        let loop = PhysiologyStubLoop(
            loopId: "restart_lane",
            eventCoalescingDelay: 0,
            source: source,
            counter: counter,
            deadlineState: PhysiologyDeadlineState()
        )
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [loop])
        await manager._testWaitForPhysiologyStartup(loopId: loop.loopId)
        #expect(await counter.value == 1)
        await manager.stop()

        source.emit() // no listener exists: intentionally dropped
        try await Task.sleep(for: .milliseconds(20))
        #expect(await counter.value == 1)

        await manager.start(loops: [loop])
        await manager._testWaitForPhysiologyStartup(loopId: loop.loopId)
        #expect(await counter.value == 2)
        await manager.stop()
    }

    @Test("slow integrity tick catches deliberately dropped physiology event")
    func physiologyIntegrityCatchesDroppedEvent() async throws {
        let source = PhysiologyEventSource()
        let counter = TickCounter()
        let loop = PhysiologyStubLoop(
            loopId: "integrity_lane",
            eventCoalescingDelay: 0,
            source: source,
            counter: counter,
            deadlineState: PhysiologyDeadlineState()
        )
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [loop])
        await manager._testWaitForPhysiologyStartup(loopId: loop.loopId)
        #expect(await counter.value == 1)

        // Simulate a filesystem notification that never reached the process.
        // The inherited periodic lane remains the bounded integrity fallback.
        await manager._testRunPeriodicTick(loopId: loop.loopId)
        #expect(await counter.value == 2)
        await manager.stop()
    }

    @Test("slow integrity completion recomputes the next exact deadline")
    func physiologyIntegrityRecomputesDeadline() async throws {
        let source = PhysiologyEventSource()
        let counter = TickCounter()
        let deadlineState = PhysiologyDeadlineState()
        let loop = PhysiologyStubLoop(
            loopId: "integrity_deadline_lane",
            eventCoalescingDelay: 0,
            source: source,
            counter: counter,
            deadlineState: deadlineState
        )
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [loop])
        await manager._testWaitForPhysiologyStartup(loopId: loop.loopId)
        #expect(await counter.value == 1)

        let deadline = Date().addingTimeInterval(60)
        await deadlineState.set(deadline)
        await manager._testRunPeriodicTick(loopId: loop.loopId)
        #expect(await manager._testPhysiologyDeadline(loopId: loop.loopId) == deadline)
        await manager.stop()
    }
}

private actor TickCounter {
    var value: Int = 0
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func bump() {
        value += 1
        let satisfiedTargets = waiters.keys.filter { $0 <= value }
        for target in satisfiedTargets {
            let satisfied = waiters.removeValue(forKey: target) ?? []
            for waiter in satisfied {
                waiter.resume()
            }
        }
    }

    func waitUntil(atLeast target: Int) async {
        guard value < target else { return }
        await withCheckedContinuation { continuation in
            waiters[target, default: []].append(continuation)
        }
    }
}

private actor SuspendedTickProbe {
    private(set) var value = 0
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func tick() async {
        value += 1
        let observers = startedWaiters
        startedWaiters.removeAll()
        for observer in observers {
            observer.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard value == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
