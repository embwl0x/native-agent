import Foundation
import Testing
@testable import CognitiveSubstrate

// Ledger row `capsule.line.sessionBridge` (core.substrate.affect).
//
// The "- Since:" line — one line on the first turn after a real gap, saying what
// she was left holding. It was REPORTS-ONLY: the instrument prints its rate and
// asserts nothing, and a grep for `feltSessionBridgeLine` / `sessionBridgeGapHours`
// across every test dir returned zero hits.
//
// It has FOUR independent silent-nil paths (no prior capsule, gap not reached,
// already spoken this gap, no strongly-felt pre-gap node) and every one of them
// reads in production as "nothing to pick back up". A permanently-nil bridge and
// correct gap-gating are the same observation. Each path is separated here, and
// the SPEAKING case is pinned so nil is never the only thing proven.
@Suite("SessionBridgeLine")
struct SessionBridgeLineTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func substrate(_ clock: AffectFenceClock) -> CognitiveSubstrate {
        AffectFenceFixture.substrate(clock: clock)
    }

    /// One strongly-felt live conversation node from BEFORE the gap opened.
    private func preGapNodes(at when: Date) -> [CognitiveNode] {
        [AffectFenceFixture.node(
            summary: "we left the migration half-done and it was bothering both of us",
            valence: -0.62, arousal: 0.45, warmth: 0.30,
            createdAt: when)]
    }

    /// The line SPEAKS after a real gap — shape, not wording: the "- Since:"
    /// prefix, the felt word from `feltDirection`, and the resolution clause.
    /// And the one-per-gap stamp lands.
    @Test func itSpeaksOnceOnTheFirstTurnAfterARealGap() async throws {
        let clock = AffectFenceClock(t0)
        let s = substrate(clock)
        let dyn = PersonalityDynamicsConfiguration.default
        let gap = dyn.sessionBridgeGapHours * 3_600
        try #require(gap > 0)
        var state = CognitiveCapsulePresentationState()

        // A fresh process has no prior capsule: honest silence, and the anchor
        // is stamped so the NEXT turn can measure a gap.
        let fresh = await s.feltSessionBridgeLine(
            at: t0, dynamics: dyn, presentationState: &state,
            fieldNodes: preGapNodes(at: t0.addingTimeInterval(-600)),
            pendingCompletionOpen: false)
        #expect(fresh == nil, "a fresh process must not claim to pick a thread back up")
        #expect(state.lastLiveCapsuleAt == t0, "the anchor must still be stamped")

        // ...now the gap.
        let after = t0.addingTimeInterval(gap + 60)
        let line = try #require(await s.feltSessionBridgeLine(
            at: after, dynamics: dyn, presentationState: &state,
            fieldNodes: preGapNodes(at: t0.addingTimeInterval(-600)),
            pendingCompletionOpen: true))
        #expect(line.hasPrefix("- Since:"))
        #expect(line.contains("stung"), "the felt word must come from feltDirection: \(line)")
        #expect(line.hasSuffix("left open"), "an unresolved thread must read as left open: \(line)")
        #expect(state.lastSessionBridgeAt == after, "the one-per-gap stamp must land")

        // A third compile inside the same gap carries none: the anchor moved to
        // `after`, so the gap is no longer open.
        let again = await s.feltSessionBridgeLine(
            at: after.addingTimeInterval(30), dynamics: dyn, presentationState: &state,
            fieldNodes: preGapNodes(at: t0.addingTimeInterval(-600)),
            pendingCompletionOpen: true)
        #expect(again == nil, "a recompile of the same first turn must not speak twice")
    }

    /// ONE BRIDGE PER GAP, independently of the live-capsule anchor. A turn whose
    /// anchor is still pre-gap (an unaccepted capsule never advances it) but whose
    /// bridge stamp is recent must stay quiet — otherwise the line repeats inside
    /// a single morning and stops being a bridge at all.
    @Test func aRecentBridgeStampSilencesTheLineEvenWithTheGapStillOpen() async throws {
        let dyn = PersonalityDynamicsConfiguration.default
        let gap = dyn.sessionBridgeGapHours * 3_600
        let after = t0.addingTimeInterval(gap + 60)
        let s = substrate(AffectFenceClock(t0))

        // Anchor still pre-gap (so `elapsed >= gap` holds) but the bridge already
        // spoke a minute ago.
        var state = CognitiveCapsulePresentationState(
            lastLiveCapsuleAt: t0,
            lastSessionBridgeAt: after.addingTimeInterval(-60))
        let repeated = await s.feltSessionBridgeLine(
            at: after, dynamics: dyn, presentationState: &state,
            fieldNodes: preGapNodes(at: t0.addingTimeInterval(-600)),
            pendingCompletionOpen: true)
        #expect(repeated == nil, "the bridge spoke twice inside one gap: \(String(describing: repeated))")

        // Negative control: the very same call with a STALE bridge stamp speaks,
        // so the assertion above is about the stamp and not about some other gate.
        var stale = CognitiveCapsulePresentationState(
            lastLiveCapsuleAt: t0,
            lastSessionBridgeAt: t0.addingTimeInterval(-gap))
        let spoken = await s.feltSessionBridgeLine(
            at: after, dynamics: dyn, presentationState: &stale,
            fieldNodes: preGapNodes(at: t0.addingTimeInterval(-600)),
            pendingCompletionOpen: true)
        #expect(spoken != nil, "negative control is inert — nothing speaks in this shape at all")
    }

    /// The resolution clause is the other half of the sentence and flips with
    /// `pendingCompletion` — a silently stuck clause would make every morning
    /// read the same way.
    @Test func theResolutionClauseTracksThePendingCompletion() async throws {
        let dyn = PersonalityDynamicsConfiguration.default
        let gap = dyn.sessionBridgeGapHours * 3_600
        let after = t0.addingTimeInterval(gap + 60)

        func line(pendingOpen: Bool) async throws -> String {
            let s = substrate(AffectFenceClock(t0))
            var state = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
            return try #require(await s.feltSessionBridgeLine(
                at: after, dynamics: dyn, presentationState: &state,
                fieldNodes: preGapNodes(at: t0.addingTimeInterval(-600)),
                pendingCompletionOpen: pendingOpen))
        }
        let openLine = try await line(pendingOpen: true)
        let closedLine = try await line(pendingOpen: false)
        #expect(openLine.hasSuffix("left open"), "\(openLine)")
        #expect(closedLine.hasSuffix("where you left it"), "\(closedLine)")
    }

    /// The four silent-nil paths, separated. Each is a legitimate reason for the
    /// line to be absent; conflating them is what makes a dead bridge invisible.
    @Test func eachSilentPathIsSilentForItsOwnReason() async throws {
        let dyn = PersonalityDynamicsConfiguration.default
        let gap = dyn.sessionBridgeGapHours * 3_600
        let after = t0.addingTimeInterval(gap + 60)
        let felt = preGapNodes(at: t0.addingTimeInterval(-600))

        // 1. gap not reached
        do {
            let s = substrate(AffectFenceClock(t0))
            var state = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
            let tooSoon = t0.addingTimeInterval(gap - 60)
            #expect(await s.feltSessionBridgeLine(
                at: tooSoon, dynamics: dyn, presentationState: &state,
                fieldNodes: felt, pendingCompletionOpen: false) == nil)
            #expect(state.lastLiveCapsuleAt == tooSoon,
                    "the anchor advances every capsule, spoken or not")
        }

        // 2. nothing strongly felt before the gap (only neutral machinery-free chat)
        do {
            let s = substrate(AffectFenceClock(t0))
            var state = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
            let bland = [AffectFenceFixture.node(
                summary: "we agreed on the file layout",
                valence: 0, arousal: 0.1, warmth: 0.0,
                createdAt: t0.addingTimeInterval(-600))]
            #expect(await s.feltSessionBridgeLine(
                at: after, dynamics: dyn, presentationState: &state,
                fieldNodes: bland, pendingCompletionOpen: false) == nil,
                "an unfelt thread is not a thread to pick back up")
        }

        // 3. the only felt node is AFTER the gap opened — that is the present,
        //    not the thread being resumed.
        do {
            let s = substrate(AffectFenceClock(t0))
            var state = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
            #expect(await s.feltSessionBridgeLine(
                at: after, dynamics: dyn, presentationState: &state,
                fieldNodes: preGapNodes(at: after.addingTimeInterval(-30)),
                pendingCompletionOpen: false) == nil)
        }

        // 4. cognition/affect off — the whole felt layer is quiet by configuration.
        do {
            let off = AffectFenceFixture.substrate(
                clock: AffectFenceClock(t0),
                configuration: AffectFenceFixture.configuration(affectEnabled: false))
            var state = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
            #expect(await off.feltSessionBridgeLine(
                at: after, dynamics: dyn, presentationState: &state,
                fieldNodes: felt, pendingCompletionOpen: false) == nil)
        }
    }

    /// The gap knob is load-bearing, not decorative: shrinking it lets the line
    /// fire sooner, and zero disables the bridge entirely.
    @Test func theGapKnobActuallyGatesTheLine() async throws {
        let felt = preGapNodes(at: t0.addingTimeInterval(-600))
        let at = t0.addingTimeInterval(2 * 3_600 + 60)

        var tight = PersonalityDynamicsConfiguration.default
        tight.sessionBridgeGapHours = 2
        let s = substrate(AffectFenceClock(t0))
        var state = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
        #expect(await s.feltSessionBridgeLine(
            at: at, dynamics: tight, presentationState: &state,
            fieldNodes: felt, pendingCompletionOpen: false) != nil,
            "a 2h gap knob must let a 2h gap speak")

        var disabled = PersonalityDynamicsConfiguration.default
        disabled.sessionBridgeGapHours = 0
        var offState = CognitiveCapsulePresentationState(lastLiveCapsuleAt: t0)
        #expect(await s.feltSessionBridgeLine(
            at: at, dynamics: disabled, presentationState: &offState,
            fieldNodes: felt, pendingCompletionOpen: false) == nil,
            "a zero gap knob must disable the bridge, not fire it every turn")
    }
}
