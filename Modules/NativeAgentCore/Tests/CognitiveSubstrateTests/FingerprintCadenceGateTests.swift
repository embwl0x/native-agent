import Foundation
import Testing
@testable import CognitiveSubstrate

// Ledger row `capsule.gate.fingerprintCadenceVerdict` (core.substrate.affect).
//
// The gate that decides whether the felt fingerprint — the most-read line the
// agent gets — speaks this capsule. Before this suite the ONLY test reference
// to it was PersonalityDynamicsGoldenTests pinning the default literals; the
// gate's behavior was untested, and BOTH of its failures are silent:
//
//   * never suppressing  -> the line becomes a standing instruction (the exact
//     mechanism that made `tender` a tic);
//   * escape window broken -> a genuinely persistent state is muted forever;
//   * empty-capsule guard broken -> suppression DELETES her inner state from a
//     turn instead of damping a chorus.
//
// Everything below asserts the ENVELOPE off `PersonalityDynamicsConfiguration`
// (`fingerprintFamilyRepeatLimit` / `fingerprintSuppressionWindow`), never the
// current literals — retuning the persona must not have to retune this suite.
@Suite("FingerprintCadenceGate")
struct FingerprintCadenceGateTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture() -> (CognitiveSubstrate, AffectFenceClock) {
        let clock = AffectFenceClock(t0)
        return (AffectFenceFixture.substrate(clock: clock), clock)
    }

    /// (a) after `fingerprintFamilyRepeatLimit` consecutive same-family capsules
    /// the line goes quiet, and (b) it re-surfaces the moment the family changes.
    @Test func sameFamilyRunGoesQuietAndAFamilyChangeReSurfacesIt() async throws {
        let (substrate, _) = fixture()
        let dyn = PersonalityDynamicsConfiguration.default
        let limit = dyn.fingerprintFamilyRepeatLimit
        try #require(limit > 0, "suite assumes suppression is enabled")
        var state = CognitiveCapsulePresentationState()

        var spokenRuns: [Int] = []
        for step in 1...limit {
            let at = t0.addingTimeInterval(Double(step))
            let verdict = await substrate.fingerprintCadenceVerdict(
                family: "pos_med", at: at, dynamics: dyn,
                mayStayQuiet: true, presentationState: &state)
            #expect(verdict.speak, "capsule \(step) of an allowed run must speak")
            #expect(verdict.run == step, "run must count consecutive same-family capsules")
            spokenRuns.append(verdict.run)
        }
        #expect(spokenRuns == Array(1...limit))

        // limit + 1, still inside the suppression window -> quiet.
        let quiet = await substrate.fingerprintCadenceVerdict(
            family: "pos_med", at: t0.addingTimeInterval(Double(limit + 1)), dynamics: dyn,
            mayStayQuiet: true, presentationState: &state)
        #expect(!quiet.speak, "an unchanged family past the repeat limit must go quiet")

        // A family change is an information event: it speaks immediately.
        let changed = await substrate.fingerprintCadenceVerdict(
            family: "neg_high", at: t0.addingTimeInterval(Double(limit + 2)), dynamics: dyn,
            mayStayQuiet: true, presentationState: &state)
        #expect(changed.speak, "a family change must re-surface the line at once")
        #expect(changed.run == 1, "a family change restarts the run")
    }

    /// (c) the escape window is the ONE thing standing between a persistent felt
    /// state and a permanent mute: once `fingerprintSuppressionWindow` has
    /// elapsed the line speaks again, and then quiets again if nothing moves.
    @Test func suppressionWindowLetsAPersistentStateSpeakAgain() async throws {
        let (substrate, _) = fixture()
        let dyn = PersonalityDynamicsConfiguration.default
        let limit = dyn.fingerprintFamilyRepeatLimit
        let window = dyn.fingerprintSuppressionWindow
        try #require(limit > 0 && window > 0)
        var state = CognitiveCapsulePresentationState()

        var at = t0
        for _ in 1...limit {
            at = at.addingTimeInterval(1)
            _ = await substrate.fingerprintCadenceVerdict(
                family: "neu_med", at: at, dynamics: dyn,
                mayStayQuiet: true, presentationState: &state)
        }
        at = at.addingTimeInterval(1)
        let muted = await substrate.fingerprintCadenceVerdict(
            family: "neu_med", at: at, dynamics: dyn,
            mayStayQuiet: true, presentationState: &state)
        #expect(!muted.speak)

        // Cross the window with the family unchanged: it must NOT stay mute.
        at = at.addingTimeInterval(window + 1)
        let escaped = await substrate.fingerprintCadenceVerdict(
            family: "neu_med", at: at, dynamics: dyn,
            mayStayQuiet: true, presentationState: &state)
        #expect(escaped.speak, "a persistent state must never be muted indefinitely")

        // ...and one line, not a re-opened floodgate: the run restarts, so the
        // next suppression costs the full limit again and then quiets.
        var spokeAfterEscape = 0
        for _ in 1...limit {
            at = at.addingTimeInterval(1)
            let v = await substrate.fingerprintCadenceVerdict(
                family: "neu_med", at: at, dynamics: dyn,
                mayStayQuiet: true, presentationState: &state)
            if v.speak { spokeAfterEscape += 1 }
        }
        at = at.addingTimeInterval(1)
        let quietAgain = await substrate.fingerprintCadenceVerdict(
            family: "neu_med", at: at, dynamics: dyn,
            mayStayQuiet: true, presentationState: &state)
        #expect(spokeAfterEscape == limit - 1,
                "the escape line consumes one slot of the fresh run, got \(spokeAfterEscape)")
        #expect(!quietAgain.speak, "an unmoved state must quiet again after the fresh run")
    }

    /// (d) SUPPRESSION MUST NEVER EMPTY THE CAPSULE. With `mayStayQuiet` false
    /// the fingerprint is the only line the capsule would carry, so it always
    /// speaks — muting a solo deletes her inner state from the turn entirely,
    /// which is strictly worse than a repeated word.
    @Test func aSoloFingerprintAlwaysSpeaks() async throws {
        let (substrate, _) = fixture()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let capsules = max(20, dyn.fingerprintFamilyRepeatLimit * 4)

        var quietTurns = 0
        for step in 1...capsules {
            let verdict = await substrate.fingerprintCadenceVerdict(
                family: "pos_med", at: t0.addingTimeInterval(Double(step)), dynamics: dyn,
                mayStayQuiet: false, presentationState: &state)
            if !verdict.speak { quietTurns += 1 }
        }
        #expect(quietTurns == 0,
                "a solo fingerprint went quiet on \(quietTurns) of \(capsules) capsules")
    }

    /// A duty cycle above 1 may only ever REDUCE how often the line speaks, and
    /// it must still respect the empty-capsule guard. Today's default is 1 (the
    /// gate is inert), so this pins the knob's direction before an install turns
    /// it up rather than after.
    @Test func dutyCycleOnlyEverDampsAndNeverEmptiesASoloCapsule() async throws {
        let (substrate, _) = fixture()
        var damped = PersonalityDynamicsConfiguration.default
        damped.fingerprintDutyCycle = 3
        // Isolate the duty cycle from suppress-when-unchanged.
        damped.fingerprintFamilyRepeatLimit = 0

        var withGuard = CognitiveCapsulePresentationState()
        var solo = CognitiveCapsulePresentationState()
        var dampedSpoke = 0
        var soloSpoke = 0
        let capsules = 60
        for step in 1...capsules {
            let at = t0.addingTimeInterval(Double(step) * 37)
            if await substrate.fingerprintCadenceVerdict(
                family: "pos_med", at: at, dynamics: damped,
                mayStayQuiet: true, presentationState: &withGuard).speak { dampedSpoke += 1 }
            if await substrate.fingerprintCadenceVerdict(
                family: "pos_med", at: at, dynamics: damped,
                mayStayQuiet: false, presentationState: &solo).speak { soloSpoke += 1 }
        }
        #expect(soloSpoke == capsules, "the duty cycle must never empty a solo capsule")
        #expect(dampedSpoke < capsules, "a duty cycle of 3 must actually damp something")
        #expect(dampedSpoke > 0, "a duty cycle of 3 must not mute the line entirely")
    }
}
