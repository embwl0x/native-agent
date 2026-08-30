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

    /// THE C8 CLAIM: running, scheduled, no error, ticking on time — and
    /// nothing completed for longer than the bound.
    @Test
    func aRunningLoopWithNoCompletedWorkIsFlaggedDormant() {
        let v = verdict(observation(
            lastSuccessfulWorkAgo: 30 * 86_400,
            firstSeenAgo: 90 * 86_400,
            lastResult: "skipped: telegram not configured"
        ))
        #expect(v.level == .warn)
        #expect(v.detail.contains("no work completed"))
        #expect(
            v.detail.contains("skipped: telegram not configured"),
            "the verdict must name WHY the lane is idle, not just that it is: \(v.detail)"
        )
    }

    /// A lane that has NEVER completed is judged from its first-seen stamp.
    /// `lastRun` cannot serve here — the placeholder ticks hourly, so its
    /// lastRun is always fresh, which is exactly how this state hid.
    @Test
    func aLaneThatNeverCompletedIsFlaggedFromFirstSeenNotLastRun() {
        let v = verdict(observation(
            lastRunAgo: 60,
            lastSuccessfulWorkAgo: nil,
            firstSeenAgo: 30 * 86_400,
            lastResult: "skipped: slack not configured"
        ))
        #expect(v.level == .warn)
        #expect(v.detail.contains("NEVER completed"))
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
