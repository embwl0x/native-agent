import Testing
import Foundation
import BackgroundLoops
@testable import NativeAgentApp

// C8 + C5 (upgrade-sweep-2026-08), the app-side half.
//
// C8: a lane that is registered, scheduled, error-free and ticking on time —
// and that has never done a thing — read as "Healthy." in Doctor. Every field
// the health rules looked at was genuinely fine; the missing one was whether
// any tick ever COMPLETED. Unconfigured Telegram/Slack were worse than that:
// they were not registered at all, so there was nothing to be healthy about.
//
// C5: the jitter bound is pinned here against the REAL
// `DoctorLoopHealth.overdueTolerance`, so the module-side restatement of that
// formula in LoopJitterBoundsTests cannot silently drift away from it.
@Suite(.serialized)
struct LoopDormancyAndJitterDoctorTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(
        loopId: String = "lane",
        interval: TimeInterval = 3600,
        lastRunAgo: TimeInterval? = 60,
        lastError: String? = nil,
        running: Bool = true,
        lastSuccessfulWorkAgo: TimeInterval? = nil,
        firstSeenAgo: TimeInterval? = nil,
        lastResult: String? = nil
    ) -> LoopHealthObservation {
        LoopHealthObservation(
            loopId: loopId,
            lastRun: lastRunAgo.map { now.addingTimeInterval(-$0) },
            nextRun: now.addingTimeInterval(interval - (lastRunAgo ?? 0)),
            lastError: lastError,
            running: running,
            lastSuccessfulWorkAt: lastSuccessfulWorkAgo.map { now.addingTimeInterval(-$0) },
            lastResult: lastResult,
            firstSeenAt: firstSeenAgo.map { now.addingTimeInterval(-$0) }
        )
    }

    private func verdict(_ observation: LoopHealthObservation) -> LoopHealthVerdict {
        DoctorLoopHealth.evaluate(
            observations: [observation], recentFailureDates: [:], now: now
        )[0]
    }

    // MARK: C5 — the jitter bound, pinned against the real tolerance

    @Test
    func jitterCeilingStaysInsideTheRealDoctorTolerance() {
        for interval in [0.25, 2.0, 30.0, 300.0, 3600.0, 86_400.0, 604_800.0] {
            let tolerance = DoctorLoopHealth.overdueTolerance(
                for: observation(interval: interval)
            )
            let ceiling = SwiftNativeLoopScheduler.jitterCeiling(for: interval)
            #expect(
                ceiling < tolerance,
                "interval \(interval)s: jitter ceiling \(ceiling)s is not inside Doctor's \(tolerance)s tolerance"
            )
        }
    }

    /// The startup stagger is bounded by the same reasoning: its ceiling must
    /// never exceed the tolerance floor either.
    @Test
    func startupStaggerCeilingStaysInsideTheToleranceFloor() {
        let floor = DoctorLoopHealth.overdueTolerance(for: observation(interval: 0.25))
        #expect(floor == 60)
        #expect(SwiftNativeLoopScheduler.maximumStartupStagger <= floor)
    }

    // MARK: C8 — dormancy

    @Test
    func aHealthyRecentlyCompletedLoopIsStillOk() {
        let v = verdict(observation(lastSuccessfulWorkAgo: 120, firstSeenAgo: 90 * 86_400))
        #expect(v.level == .ok)
        #expect(v.detail == "Healthy.")
    }

    /// D3 (2026-09-10) RESTATES THE C8 CLAIM. A loop that ticks on time and
    /// legitimately skipped its last tick (nothing due, feature off) completed
    /// nothing because there was nothing to complete: that is HEALTHY, and a
    /// dormancy warning on it reports normal life as a fault.
    @Test
    func aLoopWhoseLastTickLegitimatelySkippedIsHealthyNotDormant() {
        let v = verdict(observation(
            lastSuccessfulWorkAgo: 30 * 86_400,
            firstSeenAgo: 90 * 86_400,
            lastResult: "skipped: telegram not configured"
        ))
        #expect(v.level == .ok)
        #expect(v.detail == "Ticking; nothing was due on the last check.")
    }

    /// The bound still bites a loop that WAS expected to complete work: the
    /// single-flight coalesce skip says another tick was already running, which
    /// proves nothing about what this loop achieved.
    @Test
    func aRunningLoopExpectedToCompleteWorkIsStillFlaggedDormant() {
        let v = verdict(observation(
            lastSuccessfulWorkAgo: 30 * 86_400,
            firstSeenAgo: 90 * 86_400,
            lastResult: "skipped: \(LoopTickOutcome.coalescedSkipReason)"
        ))
        #expect(v.level == .warn)
        #expect(v.detail.contains("no work completed"))
    }

    /// A skip taken inside the loop's own failure backoff leaves `lastError`
    /// standing, so it is not evidence of health and must not buy silence.
    @Test
    func aBackoffSkipIsNotALegitimateSkip() {
        let v = verdict(observation(
            lastError: "HTTP 401",
            lastSuccessfulWorkAgo: 30 * 86_400,
            firstSeenAgo: 90 * 86_400,
            lastResult: "skipped: backing off after failure"
        ))
        #expect(v.level == .warn)
        #expect(v.detail.contains("no work completed"))
    }

    /// A lane that has NEVER completed is judged from its first-seen stamp —
    /// but only when it was expected to complete something. The unconfigured
    /// Slack placeholder skips truthfully on every tick, so it reads healthy
    /// (D3, 2026-09-10); the same lane with a non-skip last outcome does not.
    @Test
    func aLaneThatNeverCompletedIsFlaggedFromFirstSeenNotLastRun() {
        let skipping = verdict(observation(
            lastRunAgo: 60,
            lastSuccessfulWorkAgo: nil,
            firstSeenAgo: 30 * 86_400,
            lastResult: "skipped: slack not configured"
        ))
        #expect(skipping.level == .ok)

        let expectedWork = verdict(observation(
            lastRunAgo: 60,
            lastSuccessfulWorkAgo: nil,
            firstSeenAgo: 30 * 86_400,
            lastResult: nil
        ))
        #expect(expectedWork.level == .warn)
        #expect(expectedWork.detail.contains("NEVER completed"))
    }

    /// A loop whose FIRST tick is still ahead (fresh install, long cadence) has
    /// had no chance to complete anything. It is healthy, and the page says so
    /// in one sentence instead of stacking a dormancy warning on it.
    @Test
    func aLoopWhoseFirstTickIsStillAheadIsHealthy() {
        let v = verdict(observation(
            lastRunAgo: nil,
            lastSuccessfulWorkAgo: nil,
            firstSeenAgo: 30 * 86_400
        ))
        #expect(v.level == .ok)
        #expect(v.detail == "First check in 60m.")
    }

    @Test
    func aFreshlyRegisteredLaneIsNotYetDormant() {
        let v = verdict(observation(
            lastSuccessfulWorkAgo: nil,
            firstSeenAgo: 3600,
            lastResult: "skipped: not configured"
        ))
        #expect(v.level == .ok)
    }

    /// A weekly loop must not be slandered: the bound scales to 3 × interval.
    @Test
    func aSlowLoopGetsThreePeriodsBeforeDormancy() {
        let weekly: TimeInterval = 7 * 86_400
        let threshold = DoctorLoopHealth.dormancyThreshold(
            for: observation(interval: weekly)
        )
        #expect(threshold == 3 * weekly)

        let justInside = verdict(observation(
            interval: weekly, lastSuccessfulWorkAgo: 20 * 86_400, firstSeenAgo: 90 * 86_400
        ))
        #expect(justInside.level == .ok)

        let past = verdict(observation(
            interval: weekly, lastSuccessfulWorkAgo: 25 * 86_400, firstSeenAgo: 90 * 86_400
        ))
        #expect(past.level == .warn)
    }

    @Test
    func aFastLoopStillGetsTheWeekFloor() {
        let threshold = DoctorLoopHealth.dormancyThreshold(for: observation(interval: 300))
        #expect(threshold == DoctorLoopHealth.dormancyFloor)
        #expect(threshold == 7 * 86_400)
    }

    /// A loop that is not running is the SCHEDULE rules' problem; dormancy must
    /// not pile a second, confusing verdict onto it.
    @Test
    func aStoppedLoopGetsTheScheduleVerdictNotADormancyOne() {
        let v = verdict(observation(
            running: false, lastSuccessfulWorkAgo: 90 * 86_400, firstSeenAgo: 90 * 86_400
        ))
        #expect(v.level == .fail)
        #expect(v.detail.contains("Not running"))
        #expect(v.detail.contains("no work completed") == false)
    }

    /// A loop registered by an older build carries no first-seen stamp. Guess
    /// nothing: stay silent rather than manufacture a verdict.
    @Test
    func aLoopWithNoStampsIsNotJudgedDormant() {
        let v = verdict(observation(lastSuccessfulWorkAgo: nil, firstSeenAgo: nil))
        #expect(v.level == .ok)
    }

    /// Dormancy never downgrades a worse verdict; it merges like the listener
    /// lane does.
    @Test
    func dormancyDoesNotMaskAFailure() {
        let v = DoctorLoopHealth.evaluate(
            observations: [observation(
                lastError: "boom",
                lastSuccessfulWorkAgo: 90 * 86_400,
                firstSeenAgo: 90 * 86_400
            )],
            recentFailureDates: ["lane": (0..<5).map { now.addingTimeInterval(-Double($0) * 60) }],
            now: now
        )[0]
        #expect(v.level == .fail)
        #expect(v.detail.contains("Failing persistently"))
        #expect(v.detail.contains("no work completed"))
    }

    // MARK: C8 — the unconfigured-lane placeholders

    @Test
    func unconfiguredLanePlaceholdersSkipWithANamedReason() async {
        let telegram = BackgroundLoopsAssembly.unconfiguredLanePlaceholder(
            loopId: "telegram_poll",
            reason: BackgroundLoopsAssembly.telegramUnconfiguredReason
        )
        #expect(telegram.loopId == "telegram_poll")
        let outcome = await telegram.tickOutcome()
        guard case .skipped(let reason, let healthNeutral) = outcome else {
            Issue.record("placeholder did not skip: \(outcome)")
            return
        }
        #expect(reason == BackgroundLoopsAssembly.telegramUnconfiguredReason)
        #expect(reason.contains("not configured"))
        // NOT health-neutral: this is a truthful outcome about the lane, and a
        // health-neutral skip would neither clear a stale error nor advance the
        // durable clock.
        #expect(healthNeutral == false)
    }

    /// The placeholder must never look like work. If a skip ever counted as a
    /// completion, dormancy could never fire and C8 would be inert.
    @Test
    func aPlaceholderNeverCompletesWork() async {
        let slack = BackgroundLoopsAssembly.unconfiguredLanePlaceholder(
            loopId: "slack_socket_mode",
            reason: BackgroundLoopsAssembly.slackUnconfiguredReason
        )
        for _ in 0..<5 {
            let outcome = await slack.tickOutcome()
            if case .completed = outcome {
                Issue.record("the placeholder completed a tick")
            }
        }
    }

    /// A data root with no Telegram/Slack config must still REGISTER both lanes.
    @Test
    func assemblyRegistersBothSurfaceLanesWithNoConfigOnDisk() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assembly-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = Set(BackgroundLoopsAssembly.assembleAllLoops(dataRoot: root).map(\.loopId))
        #expect(ids.contains("telegram_poll"))
        #expect(ids.contains("slack_socket_mode"))
    }
}
