// LOOPS-4 pinning tests.
//
// Before this fix the scheduler's tick task slept a FULL interval before its
// first tick and kept run history only in memory. A weekly loop on a machine
// restarted more often than weekly therefore never ran at all: every launch
// restarted the 7-day sleep from zero. These pin the two halves of the fix —
// durable per-loop last-run, and a first sleep that is the REMAINDER of the
// period (or a short startup stagger when the period already elapsed).

import Foundation
import Testing
@testable import BackgroundLoops
import PersistenceCore

private actor TickSpy {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct SpyLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval
    let spy: TickSpy
    func tickOutcome() async -> LoopTickOutcome {
        await spy.bump()
        return .completed(result: "ok")
    }
}

private func makeTempRoot(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Writes the durable state a PRIOR process would have left behind.
private func seedPriorRun(_ path: URL, loopId: String, at date: Date) throws {
    let stamp = ISO8601DateFormatter().string(from: date)
    let json = #"{"version":"1","loops":{"\#(loopId)":"\#(stamp)"}}"#
    try json.write(to: path, atomically: true, encoding: .utf8)
}

/// Bounded wait — never an unbounded sleep-chain.
private func waitForTick(_ spy: TickSpy, timeout: TimeInterval) async -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let n = await spy.count
        if n > 0 { return n }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return await spy.count
}

// MARK: - The pure first-sleep rule

@Test func firstTickDelay_noPersistedHistory_sleepsFullPeriod() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let delay = SwiftNativeLoopScheduler.firstTickDelay(
        interval: 604_800, lastRun: nil, now: now, stagger: 5
    )
    #expect(delay == 604_800)
}

@Test func firstTickDelay_periodAlreadyElapsed_usesStaggerNotFullPeriod() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // Weekly loop last ran 9 days ago: it is due NOW, not in another week.
    let delay = SwiftNativeLoopScheduler.firstTickDelay(
        interval: 604_800,
        lastRun: now.addingTimeInterval(-9 * 86_400),
        now: now,
        stagger: 5
    )
    #expect(delay == 5)
}

@Test func firstTickDelay_midPeriod_sleepsOnlyTheRemainder() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // Weekly loop that ran 2 days ago → 5 days remain, not 7.
    let delay = SwiftNativeLoopScheduler.firstTickDelay(
        interval: 604_800,
        lastRun: now.addingTimeInterval(-2 * 86_400),
        now: now,
        stagger: 5
    )
    #expect(delay == 5 * 86_400)
}

@Test func firstTickDelay_backwardsClockJumpNeverExceedsOnePeriod() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // Persisted stamp is in the FUTURE (clock moved backwards / restored
    // machine). The wait must still be capped at one interval.
    let delay = SwiftNativeLoopScheduler.firstTickDelay(
        interval: 600,
        lastRun: now.addingTimeInterval(9_999),
        now: now,
        stagger: 5
    )
    #expect(delay == 600)
}

// MARK: - (c) restart with the period elapsed ticks promptly

@Test func restartWithElapsedPeriod_ticksPromptlyInsteadOfSleepingFullInterval() async throws {
    let root = makeTempRoot("LoopStartupDue")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    // A prior process ran this loop an hour ago, then the app was relaunched.
    try seedPriorRun(statePath, loopId: "weekly", at: Date().addingTimeInterval(-3_600))

    let spy = TickSpy()
    let sched = SwiftNativeLoopScheduler(loopStatePath: statePath, startupStagger: 0.05)
    // 10-minute period, 60 minutes elapsed → overdue.
    await sched.register(SpyLoop(loopId: "weekly", interval: 600, spy: spy))
    await sched.start()

    let ticks = await waitForTick(spy, timeout: 3)
    await sched.stop()
    // Pre-fix this was 0: the task slept the full 600s before its first tick.
    #expect(ticks >= 1)
}

@Test func restartWithElapsedPeriod_seedsNextTickAtToTheStaggerNotTheInterval() async {
    let root = makeTempRoot("LoopStartupDueSeed")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    try? seedPriorRun(statePath, loopId: "weekly", at: now.addingTimeInterval(-9 * 86_400))

    let sched = SwiftNativeLoopScheduler(
        clock: { now },
        loopStatePath: statePath,
        startupStagger: 5
    )
    await sched.register(SpyLoop(loopId: "weekly", interval: 604_800, spy: TickSpy()))
    await sched.start()
    let state = await sched.loopState(loopId: "weekly")
    await sched.stop()

    let next = try? #require(state?.nextTickAt)
    // Due almost immediately (stagger slot 1), NOT a week out.
    #expect((next?.timeIntervalSince(now) ?? .infinity) <= 10)
}

// MARK: - (d) restart mid-period sleeps only the remainder

@Test func restartMidPeriod_sleepsOnlyTheRemainder() async {
    let root = makeTempRoot("LoopStartupRemainder")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // Ran 100s into a 600s period → 500s remain.
    try? seedPriorRun(statePath, loopId: "L", at: now.addingTimeInterval(-100))

    let spy = TickSpy()
    let sched = SwiftNativeLoopScheduler(
        clock: { now },
        loopStatePath: statePath,
        startupStagger: 5
    )
    await sched.register(SpyLoop(loopId: "L", interval: 600, spy: spy))
    await sched.start()

    let state = await sched.loopState(loopId: "L")
    let next = state?.nextTickAt
    // Remainder, not a fresh full interval and not "right now".
    #expect(abs((next?.timeIntervalSince(now) ?? 0) - 500) <= 2)

    // And it genuinely does not fire early.
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(await spy.count == 0)
    await sched.stop()
}

// MARK: - the durable half

@Test func tickPersistsLastRunSoTheNextProcessCanResume() async {
    let root = makeTempRoot("LoopStartupPersist")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let now = Date(timeIntervalSince1970: 1_784_200_000)

    let first = SwiftNativeLoopScheduler(clock: { now }, loopStatePath: statePath)
    await first.register(SpyLoop(loopId: "L", interval: 600, spy: TickSpy()))
    await first._testRunOneTick(loopId: "L")
    await first.stop()

    #expect(FileManager.default.fileExists(atPath: statePath.path))

    // A fresh process reading the same file sees the prior run.
    let second = SwiftNativeLoopScheduler(clock: { now }, loopStatePath: statePath)
    await second.register(SpyLoop(loopId: "L", interval: 600, spy: TickSpy()))
    let restored = await second._testPersistedLastRun(loopId: "L")
    await second.stop()
    #expect(restored != nil)
    #expect(abs(restored?.timeIntervalSince(now) ?? .infinity) <= 1)
}

@Test func firstEverRegistrationSeedsTheDurableClock() async {
    let root = makeTempRoot("LoopStartupSeedClock")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let launch = Date(timeIntervalSince1970: 1_784_200_000)

    // First ever launch: no history, so the loop sleeps its full period —
    // but the clock is seeded so the NEXT launch honors elapsed time.
    let first = SwiftNativeLoopScheduler(clock: { launch }, loopStatePath: statePath, startupStagger: 5)
    await first.register(SpyLoop(loopId: "weekly", interval: 604_800, spy: TickSpy()))
    await first.start()
    let firstNext = await first.loopState(loopId: "weekly")?.nextTickAt
    await first.stop()
    #expect(abs((firstNext?.timeIntervalSince(launch) ?? 0) - 604_800) <= 2)

    // Relaunch 8 days later without the loop ever having ticked: the seeded
    // clock has expired, so it is due now rather than sleeping another week.
    let later = launch.addingTimeInterval(8 * 86_400)
    let second = SwiftNativeLoopScheduler(clock: { later }, loopStatePath: statePath, startupStagger: 5)
    await second.register(SpyLoop(loopId: "weekly", interval: 604_800, spy: TickSpy()))
    await second.start()
    let secondNext = await second.loopState(loopId: "weekly")?.nextTickAt
    await second.stop()
    #expect((secondNext?.timeIntervalSince(later) ?? .infinity) <= 10)
}

@Test func concurrentRegistrationsAllSeeThePersistedHistory() async {
    // The durable read is a suspension point inside register(). If it were
    // gated by a plain "loaded" flag, a second concurrent register could spawn
    // against a still-empty map and sleep a full interval — reintroducing the
    // starvation for exactly the loops that restart together.
    let root = makeTempRoot("LoopStartupConcurrent")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * 86_400))
    let entries = (0..<8).map { "\"L\($0)\":\"\(stamp)\"" }.joined(separator: ",")
    try? #"{"version":"1","loops":{\#(entries)}}"#
        .write(to: statePath, atomically: true, encoding: .utf8)

    let sched = SwiftNativeLoopScheduler(
        clock: { now }, loopStatePath: statePath, startupStagger: 1
    )
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<8 {
            group.addTask {
                await sched.register(SpyLoop(loopId: "L\(i)", interval: 604_800, spy: TickSpy()))
            }
        }
    }
    await sched.start()
    let states = await sched.allLoopStates()
    await sched.stop()

    #expect(states.count == 8)
    // Every one of them is overdue, so none may be scheduled a week out.
    for state in states {
        let wait = state.nextTickAt?.timeIntervalSince(now) ?? .infinity
        #expect(wait <= 60, "\(state.loopId) waits \(wait)s")
    }
}

@Test func statePathDefaultsToTheReceiptsSibling() async throws {
    // Production wiring proof: BackgroundLoopsManager.shared constructs the
    // scheduler with ONLY a failureReceiptsPath, so durable run state must
    // land beside it without any extra injection.
    let root = makeTempRoot("LoopStartupSibling")
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

    let sched = SwiftNativeLoopScheduler(
        failureReceiptsPath: logs.appendingPathComponent("background_loop_failures.jsonl")
    )
    await sched.register(SpyLoop(loopId: "L", interval: 600, spy: TickSpy()))
    await sched.stop()

    let expected = logs.appendingPathComponent("background_loop_state.json")
    #expect(FileManager.default.fileExists(atPath: expected.path))
    let text = try String(contentsOf: expected, encoding: .utf8)
    #expect(text.contains("\"L\""))
}
