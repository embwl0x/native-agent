import Foundation
import Testing
@testable import BackgroundLoops

// fix-join-waiter-leak (2026-08-02), Track C of
// docs/build_plans/lifecycle-prevention-design.md.
//
// `LoopExecutionGate.waitForCoalescedRequest` used to append a BARE
// `CheckedContinuation` to `joinWaiters`, and `acquireOrJoin` was the ONLY
// resumer. Every other exit — the tick finishing with no join, the waiting Task
// being cancelled — left the continuation parked forever: the awaiting Task
// hung for the life of the process and the continuation leaked. `finish` never
// touched `joinWaiters` at all.
//
// Each test below drives an exit that the pre-fix code could not leave. They
// carry their own watchdog so a regression is a RED test, not a hung suite.
@Suite("Loop join-waiter lifecycle")
struct LoopJoinWaiterLifecycleTests {
    /// Fails the test instead of hanging it when `body` never returns.
    private func withWatchdog<T: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private struct IdleLoop: LoopRunner {
        let loopId: String
        var interval: TimeInterval { 3600 }
        func tickOutcome() async -> LoopTickOutcome { .completed(result: nil) }
    }

    /// Local latch so the tests never depend on wall-clock sleeps to sequence
    /// "tick started" / "tick may finish".
    private actor ScopedWaiterBox {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() {
            released = true
            let parked = continuations
            continuations.removeAll()
            parked.forEach { $0.resume() }
        }
    }

    private struct HeldLoop: LoopRunner {
        let loopId: String
        let started: ScopedWaiterBox
        let hold: ScopedWaiterBox
        var interval: TimeInterval { 3600 }
        func tickOutcome() async -> LoopTickOutcome {
            await started.release()
            await hold.wait()
            return .completed(result: nil)
        }
    }

    @Test("a join that never arrives times out instead of parking forever")
    func joinWaitIsBounded() async {
        let manager = BackgroundLoopsManager()
        _ = await manager.start(loops: [IdleLoop(loopId: "idle_join")])
        defer { Task { await manager.stop() } }

        // No tick is active and nothing will ever coalesce. Pre-fix this
        // parked a continuation that nobody could resume — forever.
        let joined = await withWatchdog(seconds: 20) {
            await manager._testWaitForCoalescedRequest(loopId: "idle_join", timeoutSeconds: 0.3)
        }
        #expect(joined == false, "expected a bounded false, got \(String(describing: joined))")
    }

    @Test("a real coalescing request still resolves the wait")
    func joinWaitSeesRealJoin() async {
        let started = ScopedWaiterBox()
        let hold = ScopedWaiterBox()
        let loop = HeldLoop(loopId: "held_join", started: started, hold: hold)
        let manager = BackgroundLoopsManager()
        _ = await manager.start(loops: [loop])

        let periodic = Task { _ = await manager.runTickOnce(loopId: "held_join") }
        await started.wait()
        let joiner = Task { _ = await manager.runTickOnce(loopId: "held_join") }

        let joined = await withWatchdog(seconds: 20) {
            await manager._testWaitForCoalescedRequest(loopId: "held_join", timeoutSeconds: 10)
        }
        #expect(joined == true)

        await hold.release()
        _ = await periodic.value
        _ = await joiner.value
        await manager.stop()
    }

    @Test("a tick that finishes with no join releases its parked waiters")
    func finishReleasesParkedJoinWaiters() async {
        let started = ScopedWaiterBox()
        let hold = ScopedWaiterBox()
        let loop = HeldLoop(loopId: "finish_join", started: started, hold: hold)
        let manager = BackgroundLoopsManager()
        _ = await manager.start(loops: [loop])

        let periodic = Task { _ = await manager.runTickOnce(loopId: "finish_join") }
        await started.wait()

        // Park a waiter with a generous deadline, then let the tick finish
        // WITHOUT any coalescing request. `finish` must release it: nothing can
        // join a completed tick, so waiting further is a guaranteed hang.
        let waiting = Task {
            await manager._testWaitForCoalescedRequest(loopId: "finish_join", timeoutSeconds: 120)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await hold.release()
        _ = await periodic.value

        let joined = await withWatchdog(seconds: 20) { await waiting.value }
        #expect(joined == false, "finish() must release parked join-waiters")
        await manager.stop()
    }

    @Test("cancelling the waiting Task resumes it instead of stranding it")
    func cancelledJoinWaitResumes() async {
        let manager = BackgroundLoopsManager()
        _ = await manager.start(loops: [IdleLoop(loopId: "cancel_join")])

        let waiting = Task {
            await manager._testWaitForCoalescedRequest(loopId: "cancel_join", timeoutSeconds: 120)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()

        let joined = await withWatchdog(seconds: 20) { await waiting.value }
        #expect(joined == false, "a cancelled join-wait must return, not park forever")
        await manager.stop()
    }
}
