import Foundation
import Testing
@testable import NativeAgentApp

/// E3 (upgrade-sweep 2026-08): the Mac's CloudKit drain fallback used to run at
/// a flat 8s forever. The risk of making it adaptive is the opposite of the bug
/// it fixes: an idle interval that swallows a live exchange. These pin both
/// directions — fast while anything is in flight, idle only once both the
/// correlation set and peer activity have genuinely gone quiet.
@Suite(.serialized)
struct AdaptiveDrainPolicyTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func idleCadenceOnlyWhenNothingIsInFlight() {
        var policy = AdaptiveDrainPolicy()
        // No correlations, no peer activity ever recorded.
        #expect(policy.interval(now: t0) == policy.idleInterval)
        policy.prune(now: t0)
        #expect(policy.interval(now: t0) == 120)
    }

    @Test func anOutstandingCorrelationHoldsTheFastCadence() {
        var policy = AdaptiveDrainPolicy()
        policy.noteOutstanding("msg-1", at: t0)
        #expect(policy.interval(now: t0.addingTimeInterval(200)) == 8)
    }

    @Test func aResolvedCorrelationStopsHoldingItOncePeerActivityAges() {
        var policy = AdaptiveDrainPolicy()
        policy.noteOutstanding("msg-1", at: t0)
        policy.resolve("msg-1", at: t0.addingTimeInterval(3))
        // Still inside the peer-activity window: the follow-up traffic of this
        // exchange must not land on a 120s interval.
        #expect(policy.interval(now: t0.addingTimeInterval(60)) == 8)
        // Well past it, with nothing outstanding.
        #expect(policy.interval(now: t0.addingTimeInterval(600)) == 120)
    }

    @Test func anUnansweredCorrelationCannotPinFastForever() {
        var policy = AdaptiveDrainPolicy()
        policy.noteOutstanding("never-answered", at: t0)
        let later = t0.addingTimeInterval(policy.correlationMaxAge + 60)
        #expect(policy.interval(now: later) == 120)
        policy.prune(now: later)
        #expect(policy.outstanding.isEmpty)
    }

    @Test func aPushResetsTheCadenceToFast() {
        var policy = AdaptiveDrainPolicy()
        let quiet = t0.addingTimeInterval(10_000)
        #expect(policy.interval(now: quiet) == 120)
        policy.notePeerActivity(at: quiet)
        #expect(policy.interval(now: quiet) == 8)
    }

    @Test func drainIsDueOnlyAfterTheCurrentIntervalElapses() {
        var policy = AdaptiveDrainPolicy()
        policy.noteOutstanding("msg-1", at: t0)
        #expect(policy.isDrainDue(now: t0.addingTimeInterval(4), lastDrainAt: t0) == false)
        #expect(policy.isDrainDue(now: t0.addingTimeInterval(8), lastDrainAt: t0) == true)

        var idle = AdaptiveDrainPolicy()
        idle.notePeerActivity(at: t0.addingTimeInterval(-10_000))
        let now = t0
        // A tick every 8s must NOT spend a fetch while the policy says 120s.
        #expect(idle.isDrainDue(now: now, lastDrainAt: now.addingTimeInterval(-8)) == false)
        #expect(idle.isDrainDue(now: now, lastDrainAt: now.addingTimeInterval(-121)) == true)
    }

    @Test func prunePreservesFreshCorrelations() {
        var policy = AdaptiveDrainPolicy()
        policy.noteOutstanding("old", at: t0)
        policy.noteOutstanding("new", at: t0.addingTimeInterval(280))
        policy.prune(now: t0.addingTimeInterval(310))
        #expect(policy.outstanding.keys.sorted() == ["new"])
    }

    @Test func oneShotDelayPreservesBootstrapFastCheckThenSleepsToPolicyDeadline() {
        var policy = AdaptiveDrainPolicy()
        #expect(policy.nextDrainDelay(now: t0, lastDrainAt: .distantPast) == 8)

        let lastDrain = t0
        #expect(
            policy.nextDrainDelay(
                now: t0.addingTimeInterval(8),
                lastDrainAt: lastDrain
            ) == 112
        )

        policy.noteOutstanding("msg-1", at: t0.addingTimeInterval(8))
        #expect(
            policy.nextDrainDelay(
                now: t0.addingTimeInterval(8),
                lastDrainAt: lastDrain
            ) == 1
        )
    }
}
