import Foundation
import Testing
@testable import CognitiveSubstrate

// Ledger row `setting.dynamics.personaValenceLift` (core.substrate.affect).
//
// A constant positive bias added to fingerprint valence, faded out only as the
// moment goes negative. It is the same shape as the 2026-08-02 warmth-remap
// defect: raise it and every neutral working turn reads mildly positive —
// wrong-but-plausible, expressed as an agent who is always a bit pleased.
// PersonalityDynamicsGoldenTests pins the LITERAL; nothing pinned its BEHAVIOR.
//
// So this suite pins the shape instead of the number: bounded by the knob,
// never negative, monotonically fading as the moment darkens, and ZERO once the
// moment is genuinely negative — a real sting is never cushioned.
@Suite("PersonaValenceLift")
struct PersonaValenceLiftTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let moods = stride(from: -0.40, through: 0.40, by: 0.05).map { $0 }

    private func substrate(lift: Double) -> CognitiveSubstrate {
        var dyn = PersonalityDynamicsConfiguration.default
        dyn.personaValenceLift = lift
        return AffectFenceFixture.substrate(clock: AffectFenceClock(now), dynamics: dyn)
    }

    /// Sweep the mood axis with everything else held constant and read the lift's
    /// actual contribution as (with lift) − (without lift).
    private func liftDeltas(
        items: [CognitiveWorkspaceItem]
    ) async -> [(mood: Double, delta: Double)] {
        let lift = PersonalityDynamicsConfiguration.default.personaValenceLift
        let withLift = substrate(lift: lift)
        let without = substrate(lift: 0)
        let request = AffectFenceFixture.capsuleRequest("keep going", mode: .inspectOnly)
        var out: [(mood: Double, delta: Double)] = []
        for mood in moods {
            let reading = CognitiveMoodReading(valence: mood, basis: 6)
            let a = await withLift.feltSignalsForCapsule(
                from: items, request: request, at: now,
                affect: CognitiveAffectState(), mood: reading).valence
            let b = await without.feltSignalsForCapsule(
                from: items, request: request, at: now,
                affect: CognitiveAffectState(), mood: reading).valence
            out.append((mood: mood, delta: a - b))
        }
        return out
    }

    private func feltItem(valence: Double) -> [CognitiveWorkspaceItem] {
        [CognitiveWorkspaceItem(
            node: AffectFenceFixture.node(
                summary: "we are still working the same thing through",
                valence: valence, arousal: 0.4, warmth: 0.4, createdAt: now),
            score: 0.9, reasons: ["recent"])]
    }

    /// The mood-only branch (nothing felt in the workspace) and the
    /// workspace-tinted branch both carry the lift, and BOTH must obey the same
    /// envelope. Run the sweep against each.
    @Test func theLiftIsBoundedNeverNegativeAndFadesMonotonically() async {
        let knob = PersonalityDynamicsConfiguration.default.personaValenceLift
        let epsilon = 1e-9
        for (label, items) in [("mood-only", [CognitiveWorkspaceItem]()),
                               ("workspace-tinted", feltItem(valence: 0.05))] {
            let deltas = await liftDeltas(items: items)
            for (mood, delta) in deltas {
                #expect(delta >= -epsilon,
                        "\(label): the lift inverted sign at mood \(mood) (delta \(delta))")
                #expect(delta <= knob + epsilon,
                        "\(label): the lift exceeded its own knob at mood \(mood) (delta \(delta))")
            }
            // Monotone in mood: as the moment darkens the lift fades, never grows.
            for pair in zip(deltas, deltas.dropFirst()) {
                #expect(pair.1.delta >= pair.0.delta - epsilon,
                        "\(label): the lift GREW as mood fell (\(pair.0.mood) -> \(pair.1.mood))")
            }
            // And it is not inert: somewhere in an ordinary neutral/positive
            // range it actually contributes, or this whole suite is vacuous.
            #expect(deltas.contains { $0.delta > 0.5 * knob },
                    "\(label): the lift never contributed anything — negative control is inert")
        }
    }

    /// A GENUINE STING IS NEVER CUSHIONED. Once the moment is negative past the
    /// fade band the lift must be exactly gone — not small, gone — and the
    /// rendered fingerprint must be byte-identical with and without it.
    @Test func aNegativeMomentGetsNoLiftAtAll() async {
        let knob = PersonalityDynamicsConfiguration.default.personaValenceLift
        let withLift = substrate(lift: knob)
        let without = substrate(lift: 0)
        let request = AffectFenceFixture.capsuleRequest("that was wrong", mode: .inspectOnly)
        let items = feltItem(valence: -0.55)

        for mood in [-0.40, -0.30, -0.25] {
            let reading = CognitiveMoodReading(valence: mood, basis: 6)
            let a = await withLift.feltSignalsForCapsule(
                from: items, request: request, at: now,
                affect: CognitiveAffectState(), mood: reading)
            let b = await without.feltSignalsForCapsule(
                from: items, request: request, at: now,
                affect: CognitiveAffectState(), mood: reading)
            #expect(abs(a.valence - b.valence) < 1e-9,
                    "a sting was cushioned at mood \(mood): \(a.valence) vs \(b.valence)")
            #expect(CognitiveSubstrate.feltFingerprint(a) == CognitiveSubstrate.feltFingerprint(b),
                    "the lift changed the word she reads on a negative moment")
        }
    }

    /// The lift alone must not talk a NEUTRAL moment into the positive register.
    /// At mood zero the family she is handed is the same with and without it.
    @Test func aNeutralMomentIsNotPromotedIntoThePositiveRegister() async {
        let knob = PersonalityDynamicsConfiguration.default.personaValenceLift
        let withLift = substrate(lift: knob)
        let without = substrate(lift: 0)
        let request = AffectFenceFixture.capsuleRequest("keep going", mode: .inspectOnly)
        let reading = CognitiveMoodReading(valence: 0, basis: 6)

        for items in [[CognitiveWorkspaceItem](), feltItem(valence: 0)] {
            let a = await withLift.feltSignalsForCapsule(
                from: items, request: request, at: now,
                affect: CognitiveAffectState(), mood: reading)
            let b = await without.feltSignalsForCapsule(
                from: items, request: request, at: now,
                affect: CognitiveAffectState(), mood: reading)
            #expect(CognitiveSubstrate.feltFamily(a) == CognitiveSubstrate.feltFamily(b),
                    "the lift alone moved a neutral moment from \(CognitiveSubstrate.feltFamily(b)) to \(CognitiveSubstrate.feltFamily(a))")
        }
    }
}
