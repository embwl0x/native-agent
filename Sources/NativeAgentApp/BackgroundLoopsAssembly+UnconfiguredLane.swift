import Foundation
import BackgroundLoops

// C8 (2026-08-28): a surface lane that is not configured used to be ABSENT
// from the scheduler entirely — `assembleAllLoops` appended it only when the
// config existed. Absence is indistinguishable from "we forgot to build it":
// Doctor has nothing to report on, the loops list in the app shows nothing, and
// the honest answer ("Telegram is off because there is no token on disk") is
// visible nowhere.
//
// The placeholder registers the real loop id and skips every tick with the
// reason, so the lane appears in `status()` and in Doctor. It never completes
// work, so `DoctorLoopHealth.dormancyVerdict` promotes it to a warn once the
// dormancy bound elapses — which is exactly the "running, zero successful work
// in N days" signal. The skip is NOT health-neutral: it is a truthful outcome,
// and clearing a stale error on it is correct.

extension BackgroundLoopsAssembly {
    /// Placeholder for a surface lane whose configuration is missing.
    struct UnconfiguredLaneLoop: LoopRunner {
        let loopId: String
        let interval: TimeInterval
        let reason: String

        var tickTimeoutOverride: TimeInterval? { 5 }

        func tickOutcome() async -> LoopTickOutcome {
            .skipped(reason: reason)
        }

        func tick() async { _ = await tickOutcome() }
    }

    /// Hourly is deliberate: the placeholder does nothing, so the only cost of
    /// a tick is the outcome record, and an hourly cadence keeps `lastRun`
    /// fresh enough that the lane reads as ALIVE-but-idle rather than stalled.
    static let unconfiguredLaneInterval: TimeInterval = 60 * 60

    static func unconfiguredLanePlaceholder(
        loopId: String,
        reason: String
    ) -> UnconfiguredLaneLoop {
        UnconfiguredLaneLoop(
            loopId: loopId,
            interval: unconfiguredLaneInterval,
            reason: reason
        )
    }

    static let telegramUnconfiguredReason =
        "telegram not configured (no enabled bot token in telegram/config.json)"
    static let slackUnconfiguredReason =
        "slack not configured (no enabled Socket Mode config in slack/)"
}
