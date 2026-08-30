import Testing
import Foundation
@testable import BackgroundLoops

// C5 (upgrade-sweep-2026-08): jitter on the healthy periodic branch and a
// randomized startup stagger, both of which MUST stay inside Doctor's
// overdue tolerance or the spread itself would page.
//
// Doctor's rule (Sources/NativeAgentApp/DoctorLoopHealth.swift): a loop is
// overdue when it drifts past `nextRun` by more than
// `max(estimatedInterval / 2, 60)`. That tolerance is app-side; this module
// cannot import it, so the bound is restated here AND pinned in
// `LoopDormancyAndJitterDoctorTests` on the app side against the real
// function. Both must agree — if the app-side tolerance ever shrinks, that
// test fails.
private func doctorOverdueTolerance(interval: TimeInterval) -> TimeInterval {
    max(interval / 2, 60)
}

@Suite(.serialized)
struct LoopJitterBoundsTests {

    /// Intervals spanning every real loop: the 0.25s Telegram poll, the 2s
    /// Slack reconnect, 5m maintenance, 6h, and the weekly self-improvement.
    private static let intervals: [TimeInterval] = [
        0.25, 2, 30, 300, 900, 3600, 6 * 3600, 24 * 3600, 7 * 24 * 3600,
    ]

    @Test
    func jitterCeilingIsStrictlyInsideDoctorsOverdueTolerance() {
        for interval in Self.intervals {
            let ceiling = SwiftNativeLoopScheduler.jitterCeiling(for: interval)
            let tolerance = doctorOverdueTolerance(interval: interval)
            #expect(
                ceiling < tolerance,
                "jitter ceiling \(ceiling)s must stay strictly inside Doctor's \(tolerance)s tolerance at interval \(interval)s"
            )
        }
    }

    /// The bound must hold for EVERY interval, not just the sampled ones. The
    /// two caps are `interval * 0.1` and the 30s absolute ceiling; the
    /// tolerance floor is 60s. So the ceiling is below the tolerance whenever
    /// 0.1 < 0.5 and 30 < 60 — assert those constants directly so a future
    /// edit to either one trips here.
    @Test
    func jitterConstantsCannotEscapeTheToleranceFloor() {
        #expect(SwiftNativeLoopScheduler.healthyJitterFraction < 0.5)
        #expect(SwiftNativeLoopScheduler.maximumHealthyJitter < 60)
        #expect(SwiftNativeLoopScheduler.healthyJitterFraction > 0)
        #expect(SwiftNativeLoopScheduler.maximumHealthyJitter > 0)
    }

    @Test
    func jitteredDelayStaysWithinBaseAndBasePlusCeiling() {
        // Drive the extremes of the range the scheduler hands the jitter
        // closure, plus a draw that lies OUTSIDE it (a misbehaving injected
        // generator must be clamped, not trusted).
        let draws: [(String, (ClosedRange<Double>) -> Double)] = [
            ("lowest", { $0.lowerBound }),
            ("highest", { $0.upperBound }),
            ("midpoint", { ($0.lowerBound + $0.upperBound) / 2 }),
            ("below range", { _ in -1_000 }),
            ("above range", { _ in 1_000_000 }),
        ]
        for interval in Self.intervals {
            let base = interval
            let ceiling = SwiftNativeLoopScheduler.jitterCeiling(for: interval)
            for (label, jitter) in draws {
                let delay = SwiftNativeLoopScheduler.jitteredHealthyDelay(
                    base: base, interval: interval, jitter: jitter
                )
                #expect(
                    delay >= base,
                    "\(label) draw made the tick EARLY at interval \(interval)s (\(delay) < \(base))"
                )
                #expect(
                    delay <= base + ceiling,
                    "\(label) draw exceeded the ceiling at interval \(interval)s (\(delay) > \(base + ceiling))"
                )
            }
        }
    }

    /// Random draws, many of them: the bound is a property, not a sample.
    @Test
    func randomDrawsNeverLeaveTheBound() {
        var generator = SystemRandomNumberGenerator()
        for interval in Self.intervals {
            let ceiling = SwiftNativeLoopScheduler.jitterCeiling(for: interval)
            let tolerance = doctorOverdueTolerance(interval: interval)
            for _ in 0..<500 {
                let delay = SwiftNativeLoopScheduler.jitteredHealthyDelay(
                    base: interval,
                    interval: interval,
                    jitter: { Double.random(in: $0, using: &generator) }
                )
                let added = delay - interval
                #expect(added >= 0 && added <= ceiling)
                #expect(added < tolerance)
            }
        }
    }

    /// Zero-interval loops (an event-only runner registered with interval 0)
    /// must get no jitter at all rather than a negative or NaN ceiling.
    @Test
    func zeroIntervalGetsNoJitter() {
        #expect(SwiftNativeLoopScheduler.jitterCeiling(for: 0) == 0)
        #expect(SwiftNativeLoopScheduler.jitterCeiling(for: -5) == 0)
        let delay = SwiftNativeLoopScheduler.jitteredHealthyDelay(
            base: 7, interval: 0, jitter: { $0.upperBound }
        )
        #expect(delay == 7)
    }

    // MARK: startup stagger

    @Test
    func randomizedStaggerStaysInsideItsSlotAndTheAbsoluteCeiling() {
        for slot in 1...40 {
            let ladder = min(5 * Double(slot), SwiftNativeLoopScheduler.maximumStartupStagger)
            for draw in [0.0, 0.5, 1.0] {
                let stagger = SwiftNativeLoopScheduler.randomizedStagger(
                    base: 5,
                    slot: slot,
                    jitter: { $0.lowerBound + ($0.upperBound - $0.lowerBound) * draw }
                )
                #expect(stagger >= 0)
                #expect(
                    stagger <= ladder,
                    "slot \(slot) draw \(draw) produced \(stagger)s, past its \(ladder)s window"
                )
                #expect(stagger <= SwiftNativeLoopScheduler.maximumStartupStagger)
            }
        }
    }

    /// The whole point of randomizing: two loops in DIFFERENT slots must not
    /// be pinned to the same deterministic offsets launch after launch. With a
    /// fixed generator the ladder was `5, 10, 15, …` every time.
    @Test
    func staggerActuallySpreadsRatherThanRepeatingTheLadder() {
        var generator = SystemRandomNumberGenerator()
        var observed: Set<Int> = []
        for _ in 0..<200 {
            let stagger = SwiftNativeLoopScheduler.randomizedStagger(
                base: 5, slot: 3, jitter: { Double.random(in: $0, using: &generator) }
            )
            observed.insert(Int(stagger * 1000))
        }
        #expect(
            observed.count > 100,
            "slot-3 stagger produced only \(observed.count) distinct values in 200 draws — it is not randomized"
        )
    }

    /// A misbehaving generator must not push a starved loop minutes out.
    @Test
    func staggerClampsAnOutOfRangeDraw() {
        let high = SwiftNativeLoopScheduler.randomizedStagger(
            base: 5, slot: 100, jitter: { _ in 1_000_000 }
        )
        #expect(high == SwiftNativeLoopScheduler.maximumStartupStagger)
        let low = SwiftNativeLoopScheduler.randomizedStagger(
            base: 5, slot: 100, jitter: { _ in -1_000 }
        )
        #expect(low == 0)
    }

    /// `firstTickDelay` still clamps the stagger to the loop's own period, so
    /// a 2s loop never waits a randomized 60s for its catch-up tick.
    @Test
    func firstTickDelayClampsStaggerToThePeriod() {
        let now = Date()
        let delay = SwiftNativeLoopScheduler.firstTickDelay(
            interval: 2,
            lastRun: now.addingTimeInterval(-3600),
            now: now,
            stagger: SwiftNativeLoopScheduler.maximumStartupStagger
        )
        #expect(delay == 2)
    }
}
