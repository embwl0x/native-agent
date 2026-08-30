import Testing
import Foundation
@testable import BackgroundLoops
import PersistenceCore

// C8 (upgrade-sweep-2026-08), the scheduler half. Doctor's dormancy verdict is
// only as good as the two stamps it reads, and both must be DURABLE: an app
// that relaunches daily would otherwise reset the dormancy clock every morning
// and a lane could be dead for months without ever crossing the bound.
@Suite(.serialized)
struct LoopCompletionStampDurabilityTests {

    private struct OutcomeLoop: LoopRunner {
        let loopId: String
        let interval: TimeInterval
        let outcome: @Sendable () -> LoopTickOutcome
        func tickOutcome() async -> LoopTickOutcome { outcome() }
        func tick() async { _ = await tickOutcome() }
    }

    private func makeStatePath() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loopstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loops.json")
    }

    @Test
    func aCompletedTickStampsLastCompletedAt() async throws {
        let scheduler = SwiftNativeLoopScheduler(loopStatePath: try makeStatePath())
        await scheduler.register(OutcomeLoop(loopId: "worker", interval: 3600) {
            .completed(result: "did the thing")
        })
        await scheduler._testRunOneTick(loopId: "worker")
        let state = try #require(await scheduler.loopState(loopId: "worker"))
        #expect(state.lastCompletedAt != nil)
        #expect(state.lastResult == "did the thing")
    }

    /// The distinction the whole item rests on: a SKIP is a tick, not work.
    @Test
    func aSkippedTickNeverStampsLastCompletedAt() async throws {
        let scheduler = SwiftNativeLoopScheduler(loopStatePath: try makeStatePath())
        await scheduler.register(OutcomeLoop(loopId: "dormant", interval: 3600) {
            .skipped(reason: "not configured")
        })
        for _ in 0..<10 { await scheduler._testRunOneTick(loopId: "dormant") }
        let state = try #require(await scheduler.loopState(loopId: "dormant"))
        #expect(state.lastTickAt != nil, "it IS ticking — that is what made it look healthy")
        #expect(
            state.lastCompletedAt == nil,
            "a skip was recorded as completed work; dormancy could never fire"
        )
        #expect(state.lastResult == "skipped: not configured")
    }

    @Test
    func aFailedTickNeverStampsLastCompletedAt() async throws {
        let scheduler = SwiftNativeLoopScheduler(loopStatePath: try makeStatePath())
        await scheduler.register(OutcomeLoop(loopId: "broken", interval: 3600) {
            .failed(error: "nope")
        })
        await scheduler._testRunOneTick(loopId: "broken")
        let state = try #require(await scheduler.loopState(loopId: "broken"))
        #expect(state.lastCompletedAt == nil)
    }

    @Test
    func recordResultCanDeclineToCountAsWork() async throws {
        let scheduler = SwiftNativeLoopScheduler(loopStatePath: try makeStatePath())
        await scheduler.register(OutcomeLoop(loopId: "manual", interval: 3600) {
            .completed(result: nil)
        })
        await scheduler.recordResult(
            loopId: "manual", result: "skipped: nothing to do", completedWork: false
        )
        #expect(await scheduler.loopState(loopId: "manual")?.lastCompletedAt == nil)
        await scheduler.recordResult(loopId: "manual", result: "did work")
        #expect(await scheduler.loopState(loopId: "manual")?.lastCompletedAt != nil)
    }

    @Test
    func firstSeenIsStampedAtRegistration() async throws {
        let scheduler = SwiftNativeLoopScheduler(loopStatePath: try makeStatePath())
        await scheduler.register(OutcomeLoop(loopId: "fresh", interval: 3600) {
            .skipped(reason: "not configured")
        })
        let state = try #require(await scheduler.loopState(loopId: "fresh"))
        #expect(state.firstSeenAt != nil)
    }

    /// Across a relaunch: both stamps survive, and first-seen does NOT advance —
    /// otherwise every restart would reset the dormancy clock.
    @Test
    func bothStampsSurviveARelaunchAndFirstSeenDoesNotAdvance() async throws {
        let path = try makeStatePath()

        let first = SwiftNativeLoopScheduler(loopStatePath: path)
        await first.register(OutcomeLoop(loopId: "lane", interval: 3600) {
            .completed(result: "worked")
        })
        await first._testRunOneTick(loopId: "lane")
        let before = try #require(await first.loopState(loopId: "lane"))
        await first.stop()

        let second = SwiftNativeLoopScheduler(loopStatePath: path)
        await second.register(OutcomeLoop(loopId: "lane", interval: 3600) {
            .skipped(reason: "nothing to do")
        })
        let after = try #require(await second.loopState(loopId: "lane"))

        let firstSeenBefore = try #require(before.firstSeenAt)
        let firstSeenAfter = try #require(after.firstSeenAt)
        #expect(
            abs(firstSeenAfter.timeIntervalSince(firstSeenBefore)) < 1,
            "first-seen advanced across relaunch — the dormancy clock would reset on every launch"
        )
        let completedBefore = try #require(before.lastCompletedAt)
        let completedAfter = try #require(after.lastCompletedAt)
        #expect(abs(completedAfter.timeIntervalSince(completedBefore)) < 1)
    }

    /// A relaunched lane that only skips must not gain a completion stamp from
    /// the reload path.
    @Test
    func aRelaunchedNeverCompletedLaneStillHasNoCompletionStamp() async throws {
        let path = try makeStatePath()
        let first = SwiftNativeLoopScheduler(loopStatePath: path)
        await first.register(OutcomeLoop(loopId: "lane", interval: 3600) {
            .skipped(reason: "not configured")
        })
        await first._testRunOneTick(loopId: "lane")
        await first.stop()

        let second = SwiftNativeLoopScheduler(loopStatePath: path)
        await second.register(OutcomeLoop(loopId: "lane", interval: 3600) {
            .skipped(reason: "not configured")
        })
        let state = try #require(await second.loopState(loopId: "lane"))
        #expect(state.firstSeenAt != nil)
        #expect(state.lastCompletedAt == nil)
    }

    /// The existing loop-state file shape is preserved: a build that does not
    /// know the new keys still reads `loops`.
    @Test
    func theStateFileKeepsItsExistingLoopsKey() async throws {
        let path = try makeStatePath()
        let scheduler = SwiftNativeLoopScheduler(loopStatePath: path)
        await scheduler.register(OutcomeLoop(loopId: "lane", interval: 3600) {
            .completed(result: "ok")
        })
        await scheduler._testRunOneTick(loopId: "lane")
        await scheduler.stop()

        let raw = try Data(contentsOf: path)
        let value = try JSONValue.parse(raw)
        guard case .object(let root) = value else {
            Issue.record("state file is not an object")
            return
        }
        guard case .object(let loops)? = root["loops"],
              case .object(let completions)? = root["completions"],
              case .object(let firstSeen)? = root["firstSeen"] else {
            Issue.record("state file missing one of loops/completions/firstSeen")
            return
        }
        #expect(loops["lane"] != nil)
        #expect(completions["lane"] != nil)
        #expect(firstSeen["lane"] != nil)
    }
}
