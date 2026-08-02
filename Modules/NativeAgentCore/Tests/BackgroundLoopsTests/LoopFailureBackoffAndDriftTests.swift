import Testing
import Foundation
@testable import BackgroundLoops

// Regression cover for the 2026-08-02 background-loop audit:
//
//   1. a loop that backs off from its OWN failures must not clear the
//      scheduler's consecutive-failure streak (health-neutral skip);
//   2. the FAILURE path must back off exponentially instead of re-firing at
//      the loop's normal interval forever;
//   3. the next tick is scheduled relative to the tick's START (no drift);
//   4. a TIMED-OUT tick must not book a durable run stamp.
//
// Each test is written so it FAILS against the pre-fix scheduler.

private final class BackoffTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func time() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

private actor BackoffPushSpy {
    private(set) var events: [(loopId: String, error: String)] = []
    func record(_ id: String, _ error: String) { events.append((id, error)) }
    var count: Int { events.count }
}

/// Alternates real failure / "I am backing off because I am failing" skip —
/// exactly TelegramPollLoop's shape when its poll backoff window is open.
private struct SelfBackingOffLoop: LoopRunner {
    let loopId = "self_backoff"
    let interval: TimeInterval = 2
    let ticks: TickCounter

    actor TickCounter {
        private var n = 0
        func next() -> Int { n += 1; return n }
    }

    func tickOutcome() async -> LoopTickOutcome {
        // odd tick → real failure, even tick → backoff-window skip
        await ticks.next() % 2 == 1
            ? .failed(error: "telegram: 401 unauthorized")
            : .backingOff(reason: "Telegram poll backoff active")
    }
}

/// Plain "nothing to do" skip — still a genuine health signal.
private struct BenignSkipLoop: LoopRunner {
    let loopId = "benign_skip"
    let interval: TimeInterval = 2
    func tickOutcome() async -> LoopTickOutcome { .skipped(reason: "nothing due") }
}

private struct AlwaysFailingLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval
    var failureBackoffPolicy: LoopFailureBackoffPolicy?
    func tickOutcome() async -> LoopTickOutcome { .failed(error: "boom") }
}

private struct WedgedLoop: LoopRunner {
    let loopId = "wedged"
    let interval: TimeInterval = 604_800   // weekly
    var tickTimeoutOverride: TimeInterval? { 0.05 }
    func tickOutcome() async -> LoopTickOutcome {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return .completed(result: "never observed")
    }
}

// MARK: - 1. health-neutral skip must not reset the failure streak

@Test func healthNeutralSkip_doesNotResetFailureStreak() async {
    // Pre-fix: `case .completed, .skipped:` reset the streak on EVERY
    // non-coalesced skip, so a loop alternating failure→backoff-skip→failure
    // never got past streak 1 and the failure push could never fire. The Mac
    // stayed silent through a revoked-token outage.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = BackoffPushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    let loop = SelfBackingOffLoop(ticks: SelfBackingOffLoop.TickCounter())
    await sched.register(loop)

    // 6 ticks: F, skip, F, skip, F, skip — 3 real failures with a
    // health-neutral skip between every one of them.
    var failures = 0
    for i in 1...6 {
        await sched._testRunOneTick(loopId: loop.loopId)
        if i % 2 == 1 { failures += 1 }
        // Streak must equal the number of real failures so far — never reset
        // by the interleaved skips.
        #expect(await sched._testConsecutiveFailures(loopId: loop.loopId) == failures)
        clock.advance(150)
    }

    // Threshold (2 consecutive) AND minimum streak duration (120s) both met.
    #expect(await spy.count >= 1)

    // The loop's last observed state is still the honest skip text.
    let st = await sched.loopState(loopId: loop.loopId)
    #expect(st?.lastResult == "skipped: Telegram poll backoff active")
}

@Test func benignSkip_stillResetsFailureStreak() async {
    // The flag is opt-in: an ordinary "nothing to do" skip is still evidence
    // the loop is alive and must keep clearing the streak.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    await sched.register(BenignSkipLoop())

    await sched.recordFailure(loopId: "benign_skip", error: "e1")
    #expect(await sched._testConsecutiveFailures(loopId: "benign_skip") == 1)
    await sched._testRunOneTick(loopId: "benign_skip")
    #expect(await sched._testConsecutiveFailures(loopId: "benign_skip") == 0)
}

@Test func backingOffFactory_isHealthNeutralAndCoalescedIsToo() {
    #expect(LoopTickOutcome.backingOff(reason: "x").isHealthNeutralSkip)
    #expect(!LoopTickOutcome.backingOff(reason: "x").isCoalescedSkip)
    let coalesced = LoopTickOutcome.skipped(reason: LoopTickOutcome.coalescedSkipReason)
    #expect(coalesced.isHealthNeutralSkip)
    #expect(coalesced.isCoalescedSkip)
    #expect(!LoopTickOutcome.skipped(reason: "nothing due").isHealthNeutralSkip)
    #expect(!LoopTickOutcome.completed(result: nil).isHealthNeutralSkip)
    // Default associated value keeps the old constructor spelling equal to the
    // explicit false form (the durable-clock gate relies on it).
    #expect(LoopTickOutcome.skipped(reason: "r") == .skipped(reason: "r", healthNeutral: false))
}

// MARK: - 2. failure backoff

@Test func failurePath_backsOffExponentiallyAndResetsOnSuccess() async {
    // Pre-fix: the tick task set `delay = interval` unconditionally, so a
    // 2s loop re-POSTed a revoked-token endpoint every 2s for the whole
    // outage. Jitter is pinned to 1.0 so the curve is exact.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(
        clock: { clock.time() },
        failureBackoff: LoopFailureBackoffPolicy(baseDelay: 5, maxDelay: 300, multiplier: 2),
        jitter: { _ in 1.0 }
    )
    let loop = AlwaysFailingLoop(loopId: "slackish", interval: 2, failureBackoffPolicy: nil)
    await sched.register(loop)

    let now = clock.time()
    // Healthy → normal cadence.
    #expect(await sched._testNextDelay(loopId: loop.loopId, tickStartedAt: now) == 2)

    // 5, 10, 20, 40, 80, 160, then the 300s cap holds.
    let expected: [TimeInterval] = [5, 10, 20, 40, 80, 160, 300, 300]
    for want in expected {
        await sched._testRunOneTick(loopId: loop.loopId)
        let got = await sched._testNextDelay(loopId: loop.loopId, tickStartedAt: clock.time())
        #expect(got == want)
    }

    // First real success resets the curve to the plain interval.
    await sched.recordResult(loopId: loop.loopId, result: "completed")
    #expect(await sched._testNextDelay(loopId: loop.loopId, tickStartedAt: clock.time()) == 2)
}

@Test func failureBackoff_neverShorterThanTheLoopsOwnInterval() async {
    // A 6h loop must not start ticking every 5s just because it failed.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() }, jitter: { _ in 1.0 })
    let loop = AlwaysFailingLoop(loopId: "sixhour", interval: 21_600, failureBackoffPolicy: nil)
    await sched.register(loop)
    await sched._testRunOneTick(loopId: loop.loopId)
    #expect(await sched._testNextDelay(loopId: loop.loopId, tickStartedAt: clock.time()) == 21_600)
}

@Test func failureBackoff_perLoopPolicyOverridesTheSchedulerDefault() async {
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(
        clock: { clock.time() },
        failureBackoff: LoopFailureBackoffPolicy(baseDelay: 5, maxDelay: 300, multiplier: 2),
        jitter: { _ in 1.0 }
    )
    let loop = AlwaysFailingLoop(
        loopId: "custom",
        interval: 1,
        failureBackoffPolicy: LoopFailureBackoffPolicy(baseDelay: 30, maxDelay: 45, multiplier: 3)
    )
    await sched.register(loop)
    await sched._testRunOneTick(loopId: loop.loopId)
    #expect(await sched._testNextDelay(loopId: loop.loopId, tickStartedAt: clock.time()) == 30)
    await sched._testRunOneTick(loopId: loop.loopId)
    // 30*3 = 90, clamped to the per-loop 45s cap (not the scheduler's 300).
    #expect(await sched._testNextDelay(loopId: loop.loopId, tickStartedAt: clock.time()) == 45)
}

@Test func failureBackoffPolicy_jitterIsClampedToTheCap() {
    let policy = LoopFailureBackoffPolicy(baseDelay: 100, maxDelay: 100, multiplier: 2)
    #expect(policy.delay(forConsecutiveFailures: 9, jitter: { _ in 1.2 }) == 100)
    #expect(policy.delay(forConsecutiveFailures: 1, jitter: { _ in 0.8 }) == 80)
    #expect(policy.delay(forConsecutiveFailures: 0, jitter: { _ in 1.0 }) == 0)
}

// MARK: - 3. scheduler drift

@Test func nextDelay_isRelativeToTickStartNotTickEnd() async {
    // Pre-fix: `delay = interval` after the tick returned, so a 6h loop whose
    // tick takes 25 minutes became a 6h25m loop — permanently, and across
    // restarts via the durable last-run stamp.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    struct SixHourLoop: LoopRunner {
        let loopId = "sixhour"
        let interval: TimeInterval = 21_600
        func tickOutcome() async -> LoopTickOutcome { .completed(result: "ok") }
    }
    await sched.register(SixHourLoop())

    let started = clock.time()
    clock.advance(1_500)   // a 25-minute tick
    // Tolerance, not equality: `Date` is a Double and the epoch arithmetic in
    // the fake clock lands a few ULPs off an exact 1500s elapsed. The claim
    // under test is 20100 vs the pre-fix 21600 — 1500 seconds apart.
    let delay = await sched._testNextDelay(loopId: "sixhour", tickStartedAt: started) ?? -1
    #expect(abs(delay - (21_600 - 1_500)) < 0.001)

    // …and the advertised nextTickAt agrees, so Doctor and the scheduler
    // cannot disagree about when the loop is due.
    let st = await sched.loopState(loopId: "sixhour")
    let expectedNext = clock.time().addingTimeInterval(21_600 - 1_500)
    #expect(abs((st?.nextTickAt ?? .distantPast).timeIntervalSince(expectedNext)) < 0.001)
}

@Test func nextDelay_flooredWhenATickOutrunsItsInterval() async {
    // Telegram's shape: 2s interval, ~25s long poll. Start-relative arithmetic
    // goes negative; the floor keeps it from becoming a busy spin.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() }, minimumTickSpacing: 0.25)
    struct PollLoop: LoopRunner {
        let loopId = "poll"
        let interval: TimeInterval = 2
        func tickOutcome() async -> LoopTickOutcome { .completed(result: "ok") }
    }
    await sched.register(PollLoop())
    let started = clock.time()
    clock.advance(25)
    #expect(await sched._testNextDelay(loopId: "poll", tickStartedAt: started) == 0.25)
}

// MARK: - 4. timed-out tick must not book a durable run

@Test func timedOutTick_doesNotAdvanceTheDurableRunClock() async {
    // Pre-fix: the TickTimeoutError branch called recordDurableRun, so a
    // weekly loop that ALWAYS times out booked a fresh stamp every attempt and
    // was never overdue — the starvation was invisible to the restart
    // catch-up path. The coalesced-skip path already skipped the stamp for the
    // same reason.
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let loop = WedgedLoop()
    await sched.register(loop)                       // seeds the stamp at T0
    let seeded = await sched._testPersistedLastRun(loopId: loop.loopId)
    #expect(seeded == Date(timeIntervalSince1970: 1_000_000))

    clock.advance(700_000)                           // well past a week
    await sched._testRunOneTick(loopId: loop.loopId) // times out at 50ms

    // The failure is recorded honestly…
    let st = await sched.loopState(loopId: loop.loopId)
    #expect(st?.lastResult == "failed")
    #expect(st?.lastError?.hasPrefix("timeout after") == true)
    // …but the durable due clock is untouched, so the loop still reads overdue.
    #expect(await sched._testPersistedLastRun(loopId: loop.loopId) == seeded)
}

// MARK: - 5. the OUT-OF-BAND timeout path must agree with the periodic one

/// gpt-5.5 BLOCKING (2026-08-02): the periodic path stopped stamping a durable
/// run on timeout, but `BackgroundLoopsManager.runTickOnce` still routed its
/// `TickTimeoutError` catch through `scheduler.recordFailure(...)`, which
/// stamped unconditionally. A wedged weekly loop timing out via the manual /
/// background-task path therefore persisted `lastRun = now` and restart
/// catch-up slept another week instead of treating it as overdue.
@Test func managerRunTickOnce_timeout_doesNotAdvanceTheDurableRunClock() async {
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let manager = BackgroundLoopsManager(scheduler: sched, clock: { clock.time() })
    let loop = WedgedLoop()
    #expect(await manager.start(loops: [loop]))
    let seeded = await sched._testPersistedLastRun(loopId: loop.loopId)
    #expect(seeded == Date(timeIntervalSince1970: 1_000_000))

    clock.advance(700_000)                       // well past a week
    let outcome = await manager.runTickOnce(loopId: loop.loopId)

    guard case .failed(let error) = outcome else {
        Issue.record("expected the wedged loop to time out, got \(outcome)")
        await manager.stop()
        return
    }
    #expect(error.hasPrefix("timeout after"))
    // Honest failure state…
    let st = await sched.loopState(loopId: loop.loopId)
    #expect(st?.lastResult == "failed")
    #expect(st?.lastError?.hasPrefix("timeout after") == true)
    // …and the durable stamp is UNCHANGED, exactly like the periodic path.
    #expect(await sched._testPersistedLastRun(loopId: loop.loopId) == seeded)
    await manager.stop()
}

/// A real out-of-band FAILURE (not a timeout) still books the run — only the
/// never-completed body is exempt. Guards the fix against over-reach.
@Test func recordFailure_stillAdvancesTheDurableClockByDefault() async {
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    await sched.register(AlwaysFailingLoop(loopId: "plain", interval: 60, failureBackoffPolicy: nil))
    clock.advance(500)
    await sched.recordFailure(loopId: "plain", error: "boom")
    #expect(
        await sched._testPersistedLastRun(loopId: "plain")
            == Date(timeIntervalSince1970: 1_000_500)
    )
}

// MARK: - 6. a health-neutral skip must not read as Healthy

/// gpt-5.5 NEEDS_FIX (2026-08-02): `.backingOff` landed in the `.skipped`
/// branch, which CLEARED `lastError` and (being non-coalesced) advanced the
/// durable run clock. `consecutiveFailures` stayed nonzero while the error slot
/// read nil, so Doctor's no-error path could report a loop Healthy in the
/// middle of its own failure-backoff window.
@Test func backingOffSkip_preservesLastErrorAndDoesNotAdvanceDurableClock() async {
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let loop = SelfBackingOffLoop(ticks: SelfBackingOffLoop.TickCounter())
    await sched.register(loop)
    let seeded = await sched._testPersistedLastRun(loopId: loop.loopId)

    clock.advance(10)
    await sched._testRunOneTick(loopId: loop.loopId)   // tick 1 → real failure
    let afterFailure = await sched.loopState(loopId: loop.loopId)
    #expect(afterFailure?.lastError == "telegram: 401 unauthorized")
    let stampAfterFailure = await sched._testPersistedLastRun(loopId: loop.loopId)
    #expect(stampAfterFailure != seeded)               // a real failure IS a run

    clock.advance(10)
    await sched._testRunOneTick(loopId: loop.loopId)   // tick 2 → backoff skip
    let afterSkip = await sched.loopState(loopId: loop.loopId)
    // The skip is reported honestly as a skip…
    #expect(afterSkip?.lastResult == "skipped: Telegram poll backoff active")
    // …but it is NOT evidence of health: the streak stands and so does the
    // error Doctor reads.
    #expect(await sched._testConsecutiveFailures(loopId: loop.loopId) == 1)
    #expect(afterSkip?.lastError == "telegram: 401 unauthorized")
    // …and a body that never ran must not book a durable run.
    #expect(await sched._testPersistedLastRun(loopId: loop.loopId) == stampAfterFailure)
}

/// The complement: an ordinary "nothing due" skip IS evidence of health, so it
/// still clears the error and still books the run.
@Test func benignSkip_clearsLastErrorAndAdvancesTheDurableClock() async {
    let clock = BackoffTestClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    await sched.register(BenignSkipLoop())
    await sched.recordFailure(loopId: "benign_skip", error: "e1")
    #expect(await sched.loopState(loopId: "benign_skip")?.lastError == "e1")

    clock.advance(60)
    await sched._testRunOneTick(loopId: "benign_skip")
    #expect(await sched.loopState(loopId: "benign_skip")?.lastError == nil)
    #expect(
        await sched._testPersistedLastRun(loopId: "benign_skip")
            == Date(timeIntervalSince1970: 1_000_060)
    )
}
