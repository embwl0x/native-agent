// A1/FIX-3 pinning tests — durable loop-state flush coalescing.
//
// `flushLoopState` serializes EVERY registered loop and atomically rewrites the
// whole file. It used to run on every durable record, so the 2s telegram_poll
// loop alone rewrote the file ~3,400 times a day.
//
// The property the durable clock actually exists for is restart starvation
// detection for long-period loops (LOOPS-4). These pin that this property is
// untouched — long-interval stamps still land synchronously, and restart
// catch-up still reads them — while a burst of sub-minute records collapses to
// a single write.

import Foundation
import Testing
@testable import BackgroundLoops
import PersistenceCore

private actor NoopSpy {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct FlushProbeLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval
    let spy: NoopSpy
    func tickOutcome() async -> LoopTickOutcome {
        await spy.bump()
        return .completed(result: "ok")
    }
}

private func flushTempRoot(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func readStamps(_ path: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let loops = obj["loops"] as? [String: String]
    else { return [:] }
    return loops
}

/// Bounded wait for the trailing window to drain — never an unbounded chain.
private func waitForFlushCount(
    _ sched: SwiftNativeLoopScheduler, atLeast target: Int, timeout: TimeInterval
) async -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let n = await sched._testDurableFlushCount()
        if n >= target { return n }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await sched._testDurableFlushCount()
}

@Test("a long-interval loop still flushes its durable stamp synchronously")
func longIntervalLoopFlushesImmediately() async {
    let root = flushTempRoot("FlushLongInterval")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let sched = SwiftNativeLoopScheduler(
        loopStatePath: statePath, durableFlushWindow: 5, durableFlushImmediateInterval: 60
    )
    await sched.register(FlushProbeLoop(loopId: "hourly", interval: 3_600, spy: NoopSpy()))
    let afterRegister = await sched._testDurableFlushCount()

    await sched.recordResult(loopId: "hourly", result: "ok")

    // No window was opened and the bytes are on disk BEFORE we yield anywhere.
    #expect(await sched._testHasPendingDurableFlush() == false)
    #expect(await sched._testDurableFlushCount() == afterRegister + 1)
    #expect(readStamps(statePath)["hourly"] != nil)
    await sched.stop()
}

@Test("a burst of short-interval records coalesces to ONE whole-file write")
func shortIntervalBurstCoalescesToOneWrite() async {
    let root = flushTempRoot("FlushShortBurst")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let sched = SwiftNativeLoopScheduler(
        loopStatePath: statePath,
        durableFlushWindow: 0.4,
        durableFlushImmediateInterval: 60
    )
    await sched.register(FlushProbeLoop(loopId: "telegram_poll", interval: 2, spy: NoopSpy()))
    let baseline = await sched._testDurableFlushCount()

    for _ in 0..<25 {
        await sched.recordResult(loopId: "telegram_poll", result: "ok")
    }
    // Pre-fix this was 25 full serialize + atomic-rename cycles.
    #expect(await sched._testDurableFlushCount() == baseline)
    #expect(await sched._testHasPendingDurableFlush() == true)
    // The in-memory stamp is NOT delayed — only the disk write is.
    #expect(await sched._testPersistedLastRun(loopId: "telegram_poll") != nil)

    let settled = await waitForFlushCount(sched, atLeast: baseline + 1, timeout: 5)
    #expect(settled == baseline + 1)
    #expect(await sched._testHasPendingDurableFlush() == false)
    #expect(readStamps(statePath)["telegram_poll"] != nil)
    await sched.stop()
}

@Test("stop() drains a pending coalesced write")
func stopDrainsPendingDurableWrite() async {
    let root = flushTempRoot("FlushStopDrain")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let sched = SwiftNativeLoopScheduler(
        clock: { now },
        loopStatePath: statePath,
        durableFlushWindow: 30,          // long enough that only stop() can land it
        durableFlushImmediateInterval: 60
    )
    await sched.register(FlushProbeLoop(loopId: "fast", interval: 2, spy: NoopSpy()))
    // Clear the registration seed so the assertion below is about the burst.
    let baseline = await sched._testDurableFlushCount()
    await sched.recordResult(loopId: "fast", result: "ok")
    #expect(await sched._testDurableFlushCount() == baseline)

    await sched.stop()
    #expect(await sched._testDurableFlushCount() == baseline + 1)
    #expect(await sched._testHasPendingDurableFlush() == false)
    let stamp = readStamps(statePath)["fast"]
    #expect(stamp == ISO8601DateFormatter().string(from: now))
}

@Test("restart catch-up is unaffected: a stopped process leaves the stamps behind")
func restartCatchUpSurvivesCoalescing() async {
    let root = flushTempRoot("FlushRestartCatchUp")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let launch = Date(timeIntervalSince1970: 1_784_200_000)

    let first = SwiftNativeLoopScheduler(
        clock: { launch },
        loopStatePath: statePath,
        durableFlushWindow: 0.2,
        durableFlushImmediateInterval: 60
    )
    await first.register(FlushProbeLoop(loopId: "weekly", interval: 604_800, spy: NoopSpy()))
    await first.register(FlushProbeLoop(loopId: "fast", interval: 2, spy: NoopSpy()))
    await first.recordResult(loopId: "weekly", result: "ok")
    await first.recordResult(loopId: "fast", result: "ok")
    await first.stop()

    // Both stamps are durable — the coalesced one because stop() drained it,
    // the long one because it never coalesced at all.
    let stamps = readStamps(statePath)
    #expect(stamps["weekly"] == ISO8601DateFormatter().string(from: launch))
    #expect(stamps["fast"] == ISO8601DateFormatter().string(from: launch))

    // A fresh process 8 days later reads the weekly stamp and treats the loop
    // as due NOW rather than sleeping another week.
    let later = launch.addingTimeInterval(8 * 86_400)
    let second = SwiftNativeLoopScheduler(
        clock: { later }, loopStatePath: statePath, startupStagger: 5
    )
    await second.register(FlushProbeLoop(loopId: "weekly", interval: 604_800, spy: NoopSpy()))
    #expect(await second._testPersistedLastRun(loopId: "weekly") == launch)
    await second.start()
    let next = await second.loopState(loopId: "weekly")?.nextTickAt
    await second.stop()
    #expect((next?.timeIntervalSince(later) ?? .infinity) <= 10)
}

@Test("an unregistered loop id always flushes immediately")
func unknownLoopIdFlushesImmediately() async {
    // recordFailure can be called for an id the scheduler does not hold a
    // registration for, so its interval is unknowable. Unknown must take the
    // safe branch — a starving hour+ loop must never lose its stamp because we
    // could not classify it.
    let root = flushTempRoot("FlushUnknownId")
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")
    let sched = SwiftNativeLoopScheduler(
        loopStatePath: statePath, durableFlushWindow: 30, durableFlushImmediateInterval: 60
    )
    let baseline = await sched._testDurableFlushCount()
    await sched.recordFailure(loopId: "never_registered", error: "boom")
    #expect(await sched._testDurableFlushCount() == baseline + 1)
    #expect(await sched._testHasPendingDurableFlush() == false)
    #expect(readStamps(statePath)["never_registered"] != nil)
    await sched.stop()
}
