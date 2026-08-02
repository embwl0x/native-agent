import Foundation
import Testing
@testable import NativeAgentCore

// Track C of docs/build_plans/lifecycle-prevention-design.md. Each test below
// encodes the exit path that the hand-rolled acquire/release pairs kept
// missing: a throw between acquire and the release site, a cancelled waiter, a
// registry insert with no removal, an await with no deadline.
@Suite("Lifecycle primitives")
struct LifecyclePrimitivesTests {
    private struct Boom: Error {}

    // MARK: ScopedSlotCounter

    @Test("a throw between acquire and the work still releases the slot")
    func throwReleasesSlot() async {
        let counter = ScopedSlotCounter(name: "test", limit: 2)

        func admitAndThrow() throws {
            guard counter.acquire() != nil else { return }
            // Stands in for the durable `.started` transition that unwound
            // past MacControlBridge's only release site.
            throw Boom()
        }

        for _ in 0..<5 {
            #expect(throws: Boom.self) { try admitAndThrow() }
        }
        // Pre-fix shape (a bare counter + a `defer` inside a block never
        // entered) pinned this at the limit forever.
        #expect(counter.activeCount == 0)
        #expect(counter.acquire() != nil)
    }

    @Test("the counter admits exactly `limit` concurrent holders")
    func counterBoundsConcurrency() {
        let counter = ScopedSlotCounter(name: "test", limit: 2)
        let first = counter.acquire()
        let second = counter.acquire()
        #expect(first != nil)
        #expect(second != nil)
        #expect(counter.acquire() == nil)
        #expect(counter.activeCount == 2)
        withExtendedLifetime(first) {}
    }

    @Test("dropping a handle frees exactly one slot")
    func handleDeathFreesOneSlot() {
        let counter = ScopedSlotCounter(name: "test", limit: 2)
        var held: ScopedSlot? = counter.acquire()
        let kept = counter.acquire()
        #expect(counter.activeCount == 2)
        held = nil
        #expect(held == nil)
        #expect(counter.activeCount == 1)
        withExtendedLifetime(kept) {}
    }

    @Test("an escaping capture owns the release")
    func escapingCaptureOwnsRelease() async {
        let counter = ScopedSlotCounter(name: "test", limit: 1)
        let done = ScopedWaiter()
        do {
            guard let slot = counter.acquire() else {
                Issue.record("expected a slot")
                return
            }
            // The exec handler's shape: the background block captures the
            // handle, so the slot stays held past the enclosing scope.
            DispatchQueue.global().async { [slot] in
                defer { withExtendedLifetime(slot) {} }
                Thread.sleep(forTimeInterval: 0.05)
                done.resume()
            }
            #expect(counter.activeCount == 1)
        }
        // Enclosing scope gone; the block still holds it.
        #expect(counter.activeCount == 1)
        await done.park(timeoutSeconds: 5, reason: "escaping block")
        // Give the block's context time to be torn down after it returns.
        var settled = false
        for _ in 0..<200 where !settled {
            if counter.activeCount == 0 { settled = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(settled)
    }

    @Test("the counter survives concurrent acquire/release without drift")
    func counterIsThreadSafe() async {
        let counter = ScopedSlotCounter(name: "test", limit: 8)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    if let slot = counter.acquire() {
                        withExtendedLifetime(slot) {}
                    }
                }
            }
        }
        #expect(counter.activeCount == 0)
    }

    // MARK: ScopedSlotSet

    @Test("a registered key is removed when its handle dies")
    func setRemovesOnHandleDeath() {
        let registry = ScopedSlotSet<String>(name: "test")
        do {
            guard let slot = registry.acquire("root-a") else {
                Issue.record("expected a handle")
                return
            }
            #expect(registry.contains("root-a"))
            #expect(registry.acquire("root-a") == nil)
            withExtendedLifetime(slot) {}
        }
        #expect(!registry.contains("root-a"))
        #expect(registry.count == 0)
    }

    @Test("a throw past the registration still removes the key")
    func setRemovesOnThrow() {
        let registry = ScopedSlotSet<String>(name: "test")
        func registerAndThrow() throws {
            guard registry.acquire("k") != nil else { return }
            throw Boom()
        }
        #expect(throws: Boom.self) { try registerAndThrow() }
        #expect(registry.count == 0)
    }

    // MARK: ScopedWaiter

    @Test("a resume that beats the park does not strand the waiter")
    func resumeBeforeParkDoesNotHang() async {
        let waiter = ScopedWaiter()
        #expect(waiter.resume())
        // Pre-fix (a bare continuation appended to a list), a resume racing
        // registration was the leak: this park would never return.
        await waiter.park()
        #expect(waiter.isResolved)
    }

    @Test("exactly one resume wins")
    func resumeIsOneShot() async {
        let waiter = ScopedWaiter()
        let first = waiter.resume()
        let second = waiter.resume()
        let cancelled = waiter.cancel()
        #expect(first)
        #expect(!second)
        #expect(!cancelled)
        await waiter.park()
    }

    @Test("a parked waiter with no resumer times out instead of hanging")
    func parkIsBounded() async {
        let waiter = ScopedWaiter()
        let start = Date()
        let joined = await waiter.park(timeoutSeconds: 0.2, reason: "nobody is coming")
        #expect(!joined)
        #expect(waiter.isCancelled)
        // The claim is "returns instead of hanging forever" — the pre-fix
        // behaviour is unbounded, so ANY finite bound proves it. Sized for the
        // full parallel suite, not for an isolated run: at 0.2s nominal this
        // measured 6.0s under a loaded 5265-test run and 0.21s alone, so a 5s
        // bound was asserting machine load, not the primitive.
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test("a deadline firing after a real resume does not relabel it a timeout")
    func lateCancelDoesNotRelabelResume() async {
        let waiter = ScopedWaiter()
        #expect(waiter.resume())
        #expect(!waiter.cancel())
        #expect(!waiter.isCancelled)
        #expect(await waiter.park(timeoutSeconds: 5, reason: "already resumed"))
    }

    @Test("a real resume beats the deadline")
    func parkReturnsTrueOnResume() async {
        let waiter = ScopedWaiter()
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waiter.resume()
        }
        #expect(await waiter.park(timeoutSeconds: 5, reason: "resumed"))
        #expect(!waiter.isCancelled)
    }

    // MARK: OnceByKey

    @Test("the operation runs once per key no matter how many callers race")
    func onceRunsOncePerKey() async {
        let once = OnceByKey<String>(name: "test")
        let runs = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await once.run("a") { await runs.bump() } }
                group.addTask { await once.run("b") { await runs.bump() } }
            }
        }
        #expect(await runs.value == 2)
        #expect(await once.hasCompleted("a"))
        #expect(await once.trackedKeys == 2)
    }

    @Test("the completed run's captures are released, and reset clears the table")
    func onceDropsCapturesAndResets() async {
        final class Captured: @unchecked Sendable {}
        let once = OnceByKey<String>(name: "test")
        weak var observed: Captured?
        do {
            let captured = Captured()
            observed = captured
            // The pre-fix `[String: Task]` memo kept this Task — and therefore
            // this capture — alive for the process lifetime.
            await once.run("root") { withExtendedLifetime(captured) {} }
        }
        #expect(observed == nil)
        #expect(await once.trackedKeys == 1)
        await once.reset()
        #expect(await once.trackedKeys == 0)
        #expect(!(await once.hasCompleted("root")))
    }

    // MARK: BoundedWait

    @Test("an await with no answer throws a typed, named timeout")
    func boundedWaitThrowsTyped() async {
        let start = Date()
        do {
            _ = try await BoundedWait.run(seconds: 0.2, reason: "canonical record") {
                // The unbounded-await shape: a stream nobody will ever feed.
                let stream = AsyncStream<Int> { _ in }
                for await _ in stream {}
                return 1
            }
            Issue.record("expected a timeout")
        } catch let error as BoundedWaitTimeout {
            #expect(error.reason == "canonical record")
            #expect(error.seconds == 0.2)
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // Bounded for the parallel suite — see `parkIsBounded`. The typed
        // timeout above is the real assertion; this only proves it returned.
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test("a fast operation returns its value and is never timed out")
    func boundedWaitPassesValueThrough() async throws {
        let value = try await BoundedWait.run(seconds: 5, reason: "fast") { 42 }
        #expect(value == 42)
    }

    @Test("the operation's own error propagates unchanged")
    func boundedWaitPreservesErrorClass() async {
        await #expect(throws: Boom.self) {
            _ = try await BoundedWait.run(seconds: 5, reason: "throwing") {
                throw Boom()
            }
        }
    }

    @Test("cancellation is not laundered into a timeout")
    func boundedWaitPropagatesCancellation() async {
        let task = Task {
            try await BoundedWait.run(seconds: 30, reason: "long") {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            Issue.record("expected cancellation")
        case .failure(let error):
            #expect(!(error is BoundedWaitTimeout))
        }
    }

    @Test("a non-positive deadline is refused, never treated as forever")
    func boundedWaitRefusesZeroDeadline() async {
        await #expect(throws: BoundedWaitTimeout.self) {
            _ = try await BoundedWait.run(seconds: 0, reason: "no deadline") { 1 }
        }
    }

    @Test("env overrides supply the deadline, bad values fall back")
    func boundedWaitEnvOverride() {
        let key = "NATIVE_AGENT_TEST_BOUNDED_WAIT_SECONDS"
        #expect(BoundedWait.seconds(fromEnv: key, fallback: 300) == 300)
        setenv(key, "12.5", 1)
        #expect(BoundedWait.seconds(fromEnv: key, fallback: 300) == 12.5)
        setenv(key, "-3", 1)
        #expect(BoundedWait.seconds(fromEnv: key, fallback: 300) == 300)
        setenv(key, "nonsense", 1)
        #expect(BoundedWait.seconds(fromEnv: key, fallback: 300) == 300)
        unsetenv(key)
    }

    // MARK: BoundedWait — the deadline is real, not cooperative-only

    /// BLOCKING (gpt-5.5, 2026-08-02): the old task-group implementation
    /// AWAITED its children at scope exit, so an operation that ignores
    /// cancellation hung forever despite the bound. This is that operation:
    /// a raw `withCheckedContinuation` resumed off-actor on a timer, which
    /// `Task.cancel()` cannot touch. Bounded on both sides so a regression
    /// fails the test instead of wedging the suite.
    @Test("the deadline fires even when the operation ignores cancellation")
    func boundedWaitBoundsNonCooperativeWork() async {
        // This test's teeth are the GAP between the deadline and the
        // uncancellable child, so it cannot be deflaked by widening the bound
        // the way its siblings can — a bound loose enough to survive suite
        // contention would also pass on the pre-fix code that waits out the
        // child. Widen the GAP instead: the child outlives the deadline by
        // 60x, and the assertion sits at the midpoint. Pre-fix (waits for the
        // child) needs 60s and fails; post-fix returns at ~0.3s and passes
        // with room for the 6s stalls a loaded 5265-test run actually
        // produces.
        let childSeconds: TimeInterval = 60
        let deadlineSeconds: TimeInterval = 1
        let start = Date()
        var timedOut = false
        do {
            _ = try await BoundedWait.run(seconds: deadlineSeconds, reason: "non-cooperative") {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // Self-releasing so the abandoned task cannot outlive the
                    // suite; nothing here observes cancellation.
                    DispatchQueue.global().asyncAfter(deadline: .now() + childSeconds) {
                        continuation.resume()
                    }
                }
                return 1
            }
            Issue.record("expected a timeout")
        } catch let error as BoundedWaitTimeout {
            timedOut = true
            #expect(error.reason == "non-cooperative")
        } catch {
            Issue.record("wrong error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(timedOut)
        // Midpoint of the gap: far above the deadline, far below the child.
        let bound = childSeconds / 2
        #expect(elapsed < bound, "bound did not hold: returned after \(elapsed)s")
    }

    @Test("a huge deadline is clamped instead of trapping the nanosecond conversion")
    func boundedWaitClampsHugeDeadline() async throws {
        // Pre-fix `UInt64(seconds * 1_000_000_000)` on this value TRAPPED the
        // process rather than throwing.
        #expect(BoundedWait.nanoseconds(.greatestFiniteMagnitude)
            == UInt64(BoundedWait.maxDeadlineSeconds * 1_000_000_000))
        #expect(BoundedWait.clampedDeadline(1_000_000, reason: "huge") == BoundedWait.maxDeadlineSeconds)
        let value = try await BoundedWait.run(seconds: .greatestFiniteMagnitude, reason: "huge") { 7 }
        #expect(value == 7)
    }

    @Test("an out-of-range env override is rejected, not honored")
    func boundedWaitRejectsOutOfRangeOverride() {
        let key = "NATIVE_AGENT_TEST_BOUNDED_WAIT_MAX_SECONDS"
        // The wedge shape: stretching the 300s Workshop guard to hours would
        // hold the invocation flock for hours in every other process.
        setenv(key, "36000", 1)
        #expect(BoundedWait.seconds(fromEnv: key, fallback: 300) == 300)
        setenv(key, "\(BoundedWait.maxDeadlineSeconds)", 1)
        #expect(BoundedWait.seconds(fromEnv: key, fallback: 300) == BoundedWait.maxDeadlineSeconds)
        unsetenv(key)
    }

    // MARK: ScopedWaiter — cancellation safety lives in the primitive

    @Test("a cancelled parker is unparked by the waiter itself")
    func parkIsCancellationSafe() async {
        let waiter = ScopedWaiter()
        let parked = Task { await waiter.park() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        parked.cancel()
        // Pre-fix `park()` ignored cancellation entirely and this never
        // returned. The bound keeps a regression to one failing test.
        let returned = await BoundedWait.runReportingTimeout(
            seconds: 2,
            reason: "cancelled park returns"
        ) {
            await parked.value
            return true
        }
        #expect(returned == true)
        // Unparking one cancelled parker must not resolve the shared waiter.
        #expect(!waiter.isResolved)
        #expect(!waiter.isCancelled)
        waiter.resume()
    }

    @Test("cancelling one parker leaves a sibling parked until a real resume")
    func cancelledParkerDoesNotResumeSiblings() async {
        let waiter = ScopedWaiter()
        let sibling = Task { await waiter.park() }
        let doomed = Task { await waiter.park() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        doomed.cancel()
        _ = await BoundedWait.runReportingTimeout(seconds: 2, reason: "doomed park") {
            await doomed.value
            return true
        }
        #expect(!waiter.isResolved)
        waiter.resume()
        let siblingReturned = await BoundedWait.runReportingTimeout(
            seconds: 2,
            reason: "sibling park"
        ) {
            await sibling.value
            return true
        }
        #expect(siblingReturned == true)
    }

    @Test("a bounded park reports false when its own task is cancelled")
    func boundedParkReportsCancellation() async {
        let waiter = ScopedWaiter()
        let parked = Task {
            await waiter.park(timeoutSeconds: 30, reason: "cancelled parker")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        parked.cancel()
        let joined = await BoundedWait.runReportingTimeout(
            seconds: 2,
            reason: "bounded park returns"
        ) {
            await parked.value
        }
        #expect(joined == false)
        waiter.resume()
    }

    // MARK: OnceByKey — the run owns its own completion marker

    @Test("a reset during a run is not resurrected by the completing run")
    func onceResetIsNotResurrectedByLateCompletion() async {
        let once = OnceByKey<String>(name: "test")
        let gate = ScopedWaiter()
        let runner = Task { await once.run("k") { await gate.park() } }
        // Wait for the run to register.
        for _ in 0..<200 where await once.trackedKeys == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await once.trackedKeys == 1)
        await once.reset()
        #expect(await once.trackedKeys == 0)
        gate.resume()
        await runner.value
        // Pre-fix the AWAITING caller wrote `.done` after `task.value`
        // returned — re-inserting a key `reset()` had just dropped, so the
        // table could never actually be cleared while a run was in flight.
        #expect(await once.trackedKeys == 0)
        #expect(!(await once.hasCompleted("k")))
    }

    @Test("the marker still lands when the awaiting caller is cancelled")
    func onceMarksDoneDespiteCallerCancellation() async {
        let once = OnceByKey<String>(name: "test")
        let caller = Task {
            await once.run("k") { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        caller.cancel()
        _ = await BoundedWait.runReportingTimeout(seconds: 3, reason: "cancelled once caller") {
            await caller.value
            return true
        }
        var completed = false
        for _ in 0..<200 where !completed {
            if await once.hasCompleted("k") { completed = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(completed)
        #expect(await once.trackedKeys == 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
