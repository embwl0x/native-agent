import Testing
import Foundation
import NativeAgentCore
import DreamREMCycle
@testable import NativeAgentApp

// MARK: - Per-job timeout race primitive

@Test
func timeoutRace_bodyPastDeadline_reportsTimeoutAndDoesNotBlockNextJob() async throws {
    // A body that sleeps far past a tiny injected deadline must resolve as
    // .timedOut, and a following job must still run to normal completion —
    // i.e. the hung body did not wedge the runner.
    let started = Date()
    let outcome = await raceAgainstTimeout(seconds: 0.05) { () -> String in
        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5s, well past 50ms
        return "should-never-surface"
    }
    guard case .timedOut = outcome else {
        Issue.record("expected .timedOut, got \(outcome)")
        return
    }
    // The race returned promptly (did not await the 5s body).
    #expect(Date().timeIntervalSince(started) < 2.0)

    // The NEXT job completes normally right after the timed-out one.
    let next = await raceAgainstTimeout(seconds: 5.0) { () -> String in
        "next-job-ran"
    }
    guard case .value(let v) = next else {
        Issue.record("expected .value, got \(next)")
        return
    }
    #expect(v == "next-job-ran")
}

@Test
func timeoutRace_bodyUnderDeadline_returnsValueUnchanged() async throws {
    let outcome = await raceAgainstTimeout(seconds: 5.0) { () -> Int in
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms, well under 5s
        return 42
    }
    guard case .value(let v) = outcome else {
        Issue.record("expected .value, got \(outcome)")
        return
    }
    #expect(v == 42)
}

@Test
func timeoutRace_bodyThrows_reportsFailureNotTimeout() async throws {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "kaboom" } }
    let outcome = await raceAgainstTimeout(seconds: 5.0) { () -> Int in
        throw Boom()
    }
    guard case .failure(let message) = outcome else {
        Issue.record("expected .failure, got \(outcome)")
        return
    }
    #expect(message == "kaboom")
}

@Test
func timeoutRace_cancelsAbandonedBodyOnTimeout() async throws {
    // On timeout the body Task is cancelled cooperatively; a cooperative body
    // observes Task.isCancelled.
    let observedCancellation = ObservedFlag()
    let outcome = await raceAgainstTimeout(seconds: 0.05) { () -> String in
        // Loop until cancelled or a generous cap, checking cooperatively.
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
            if Task.isCancelled {
                await observedCancellation.set()
                return "cancelled"
            }
        }
        return "ran-to-completion"
    }
    guard case .timedOut = outcome else {
        Issue.record("expected .timedOut, got \(outcome)")
        return
    }
    // Give the abandoned body a beat to observe the cancel.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(await observedCancellation.get())
}

// MARK: - Parent-cancellation propagation (W3b Finding 2)

@Test
func timeoutRace_parentCancellation_resolvesCancelledPromptly() async throws {
    // A long-running body under a huge deadline, then the ENCLOSING task (the
    // stand-in for the runDueJobs loop) is cancelled. The race must observe the
    // parent cancel, resolve `.cancelled`, and return PROMPTLY — not block until
    // the ~1h body or the ~1h deadline resolve on their own.
    let bodyStarted = ObservedFlag()
    let outcomeBox = OutcomeBox()
    let racer = Task {
        let outcome = await raceAgainstTimeout(seconds: 3600) { () -> String in
            await bodyStarted.set()
            try await Task.sleep(nanoseconds: 3_600_000_000_000)  // ~1h
            return "should-never-surface"
        }
        await outcomeBox.set(mapOutcomeToTag(outcome))
    }
    // Wait until the body is genuinely in flight before cancelling the parent.
    while await bodyStarted.get() == false {
        try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
    }
    let started = Date()
    racer.cancel()
    await racer.value
    // Returned promptly (did not await the ~1h body/deadline).
    #expect(Date().timeIntervalSince(started) < 2.0)
    guard case .cancelled? = await outcomeBox.get() else {
        Issue.record("expected .cancelled, got \(String(describing: await outcomeBox.get()))")
        return
    }
}

@Test
func timeoutRace_parentCancellation_winsOverBodyThrowAndDeadline() async throws {
    // Cancelling the parent while the body is parked must surface `.cancelled` —
    // NOT a `.failure` from the body's cancellation-throw, nor a `.timedOut`
    // from the deadline task's swallowed sleep. Proof the first-wins latch takes
    // the cancellation outcome and the losers are ignored.
    let bodyStarted = ObservedFlag()
    let outcomeBox = OutcomeBox()
    let racer = Task {
        let outcome = await raceAgainstTimeout(seconds: 0.20) { () -> Int in
            await bodyStarted.set()
            try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s, past the 0.2s deadline
            return 7
        }
        await outcomeBox.set(mapOutcomeToTag(outcome))
    }
    while await bodyStarted.get() == false {
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    racer.cancel()  // cancel BEFORE the 0.2s deadline elapses
    await racer.value
    guard case .cancelled? = await outcomeBox.get() else {
        Issue.record("expected .cancelled, got \(String(describing: await outcomeBox.get()))")
        return
    }
}

/// Collapse a generic outcome to a comparable String-tagged outcome so
/// `OutcomeBox` can hold results from bodies of any element type.
private func mapOutcomeToTag<T>(_ o: TimeoutRaceOutcome<T>) -> TimeoutRaceOutcome<String> {
    switch o {
    case .value: return .value("value")
    case .failure(let m): return .failure(m)
    case .timedOut: return .timedOut
    case .cancelled: return .cancelled
    }
}

private actor OutcomeBox {
    private var value: TimeoutRaceOutcome<String>?
    func set(_ o: TimeoutRaceOutcome<String>) { value = o }
    func get() -> TimeoutRaceOutcome<String>? { value }
}

// MARK: - Timeout table

@Test
func timeoutTable_defaultAndLongKinds() {
    #expect(SchedulerDueJobRunner.jobTimeoutSeconds(forKind: "notify") == 300)
    #expect(SchedulerDueJobRunner.jobTimeoutSeconds(forKind: "connector_action") == 300)
    #expect(SchedulerDueJobRunner.jobTimeoutSeconds(forKind: "proactive_scan") == 300)
    for long in ["dream", "rem", "improve", "harness_benchmark"] {
        #expect(SchedulerDueJobRunner.jobTimeoutSeconds(forKind: long) == 1800)
    }
}

// MARK: - REM constant single-source-of-truth

@Test
func remConstant_appConsumesCoreOwner() {
    // App-side scheduler must forward to Core's constant, not duplicate a literal.
    #expect(NativeAgentDreamCycleSchedule.remHour == DreamREMSchedule.remHour)
    #expect(NativeAgentDreamCycleSchedule.remMinute == DreamREMSchedule.remMinute)
}

private actor ObservedFlag {
    private var value = false
    func set() { value = true }
    func get() -> Bool { value }
}
