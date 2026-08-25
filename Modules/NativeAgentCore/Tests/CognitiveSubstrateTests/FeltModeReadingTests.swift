import Foundation
import Testing
@testable import CognitiveSubstrate

// Ledger row `substrate.felt.feltModeReading` (core.substrate.affect).
//
// `feltModeReading(for:workspace:)` is what the Observatory's mode chip shows.
// Before this suite it had ZERO test references anywhere. It returns nil when
// cognition/affect is off OR when no mode is dominant, and the chip then shows
// nothing rather than inventing an aboutness — so a PERMANENTLY blank chip (a
// config regression, a workspace-filter change, an intensity-floor drift) is
// indistinguishable from the intended honest silence.
//
// Three things get pinned: every mode is reachable (nothing is structurally
// dead), the disabled branches really are the silent ones, and the reading uses
// the CAPSULE's own admission filter — it is a second renderer over a
// caller-supplied workspace and must not drift from the capsule's.
@Suite("FeltModeReading")
struct FeltModeReadingTests {

    typealias S = CognitiveSubstrate.FeltSignals
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func signals(
        v: Double, a: Double, w: Double = 0.4, t: Double = 0.2, p: Double = 0.2,
        f: Double = 0.15, cu: Double = 0.3, cl: Double = 0.55, ag: Double = 0.5, co: Double = 0.5
    ) -> S {
        S(valence: v, arousal: a, warmth: w, tension: t, pressure: p,
          fatigue: f, curiosity: cu, clarity: cl, agency: ag, confidence: co)
    }

    /// DEAD-CONTROL GUARD: every one of the seven modes must be reachable from
    /// some honest state. A mode that no state can produce is a chip branch that
    /// can never render, and nothing else would ever say so.
    @Test func everyModeIsReachableFromSomeHonestState() {
        let cases: [(CognitiveSubstrate.FeltMode, S)] = [
            (.grief,       signals(v: -0.70, a: 0.20, w: 0.30, t: 0.30, f: 0.40, cu: 0.05)),
            (.frustration, signals(v: -0.35, a: 0.60, w: 0.30, t: 0.40, p: 0.60, cu: 0.20)),
            (.bracing,     signals(v: -0.05, a: 0.40, w: 0.35, t: 0.60, p: 0.30, cu: 0.20)),
            (.repair,      signals(v: -0.10, a: 0.35, w: 0.40, t: 0.20, p: 0.60, cu: 0.20)),
            (.play,        signals(v: 0.50, a: 0.65, w: 0.70, t: 0.05, p: 0.10, cu: 0.40)),
            (.care,        signals(v: 0.30, a: 0.25, w: 0.80, t: 0.10, p: 0.10, cu: 0.20)),
            (.seeking,     signals(v: 0.20, a: 0.45, w: 0.45, t: 0.20, p: 0.20, cu: 0.75)),
        ]
        var unreachable: [CognitiveSubstrate.FeltMode] = []
        for (expected, s) in cases where CognitiveSubstrate.feltMode(s) != expected {
            unreachable.append(expected)
        }
        #expect(unreachable.isEmpty,
                "modes no honest state can produce: \(unreachable.map(\.rawValue))")

        // ...and the chip is allowed to be quiet: a faint state yields no mode
        // rather than inventing one.
        let faint = signals(v: 0.02, a: 0.05, w: 0.05, t: 0.02, p: 0.02, f: 0.02, cu: 0.02, cl: 0.5, ag: 0.05, co: 0.05)
        #expect(CognitiveSubstrate.feltMode(faint) == nil, "a faint state must not invent an aboutness")
    }

    /// The two disabled branches are the ONLY legitimate always-nil paths, and
    /// they must be driven by configuration, not by an accident downstream.
    @Test func theChipIsSilentExactlyWhenCognitionOrAffectIsOff() async {
        let clock = AffectFenceClock(now)
        let workspace = warmWorkspace(at: now)
        let request = AffectFenceFixture.capsuleRequest("how are you feeling", mode: .inspectOnly)

        let affectOff = AffectFenceFixture.substrate(
            clock: clock,
            configuration: AffectFenceFixture.configuration(affectEnabled: false))
        #expect(await affectOff.feltModeReading(for: request, workspace: workspace) == nil)

        var disabled = AffectFenceFixture.configuration()
        disabled.enabled = false
        let cognitionOff = AffectFenceFixture.substrate(clock: clock, configuration: disabled)
        #expect(await cognitionOff.feltModeReading(for: request, workspace: workspace) == nil)
    }

    /// NO-DRIFT PIN: the reading must apply `capsuleEligibleWorkspaceNode`, the
    /// capsule's own admission filter. A caller-supplied workspace carries nodes
    /// the capsule would never feel (her own turns, machinery); if this second
    /// renderer stops filtering them, the chip reports an aboutness the capsule
    /// does not have — and both look plausible.
    @Test func theReadingHonoursTheCapsuleAdmissionFilter() async throws {
        let clock = AffectFenceClock(now)
        let substrate = AffectFenceFixture.substrate(clock: clock)
        let request = AffectFenceFixture.capsuleRequest("how are you feeling", mode: .inspectOnly)

        let clean = warmWorkspace(at: now)
        // Same workspace plus material the capsule never feeds on: her own
        // strongly-negative turn, and a tool observation.
        let contaminated = CognitiveWorkspaceSnapshot(
            generatedAt: now,
            items: clean.items + [
                CognitiveWorkspaceItem(
                    node: AffectFenceFixture.node(
                        summary: "I got that badly wrong and it cost us the afternoon",
                        metadata: ["role": .string("assistant")],
                        valence: -0.95, arousal: 0.90, warmth: 0.05,
                        createdAt: now),
                    score: 0.9, reasons: ["assistant"]),
                CognitiveWorkspaceItem(
                    node: AffectFenceFixture.node(
                        summary: "swift build failed with 3 errors",
                        kind: .toolObservation,
                        valence: -0.90, arousal: 0.85, warmth: 0.02,
                        createdAt: now),
                    score: 0.9, reasons: ["tool"]),
            ])

        let cleanReading = await substrate.feltModeReading(for: request, workspace: clean)
        let contaminatedReading = await substrate.feltModeReading(for: request, workspace: contaminated)
        #expect(cleanReading == contaminatedReading,
                "ineligible nodes changed the chip: \(String(describing: cleanReading)) -> \(String(describing: contaminatedReading))")

        // Guard against the assertion above passing vacuously: the contaminating
        // nodes really are strong enough to move the reading if they get in.
        let leaked = CognitiveSubstrate.feltMode(
            await substrate.feltSignalsForCapsule(
                from: contaminated.items, request: request, at: now))
        let filtered = CognitiveSubstrate.feltMode(
            await substrate.feltSignalsForCapsule(
                from: clean.items, request: request, at: now))
        #expect(leaked != filtered,
                "negative control is inert — the contaminating nodes do not move the mode, so the filter assertion proves nothing")
    }

    /// The reading is a PURE PEEK: reading her attention must never change it.
    /// Repeated reads at the same instant return the same answer.
    @Test func repeatedReadsAreStable() async {
        let clock = AffectFenceClock(now)
        let substrate = AffectFenceFixture.substrate(clock: clock)
        let request = AffectFenceFixture.capsuleRequest("how are you feeling", mode: .inspectOnly)
        let workspace = warmWorkspace(at: now)

        let first = await substrate.feltModeReading(for: request, workspace: workspace)
        let second = await substrate.feltModeReading(for: request, workspace: workspace)
        let third = await substrate.feltModeReading(for: request, workspace: workspace)
        #expect(first == second)
        #expect(second == third)
    }

    private func warmWorkspace(at now: Date) -> CognitiveWorkspaceSnapshot {
        let summaries = [
            "we finally landed the thing we have been circling all week",
            "User said the new shape reads right to him",
            "the two of us worked this one out together",
        ]
        // Slightly older than "now" so a fresher contaminating node in the
        // no-drift test below can actually win the recency-weighted peak — the
        // negative control has to be able to move the reading.
        let when = now.addingTimeInterval(-600)
        return CognitiveWorkspaceSnapshot(
            generatedAt: now,
            items: summaries.map {
                CognitiveWorkspaceItem(
                    node: AffectFenceFixture.node(
                        summary: $0, valence: 0.55, arousal: 0.45, warmth: 0.65,
                        createdAt: when),
                    score: 0.9, reasons: ["recent"])
            })
    }
}
