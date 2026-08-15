import Foundation
import Testing
import PersistenceCore
import NativeAgentCore
@testable import CognitiveSubstrate

// W4/P1 — THE NON-NEGOTIABLE PIN.
//
// Turning ~24 compile-time `static let`s into configuration is only safe if the
// DEFAULT configuration is byte-for-byte the old behavior. This suite pins that
// three ways:
//
//   1. Every default field equals the literal it replaced, asserted against
//      hand-typed numbers rather than against the code under test (a test that
//      reads the constant back from the config proves nothing).
//   2. Neutral trait dials derive EXACTLY `.default` — so an install with an
//      unremarkable persona gets the calibrated physics, not a rounding of it.
//   3. A fixture substrate compiles a BYTE-IDENTICAL capsule.
//
// The golden fixture deliberately runs with the ORGANISM ON and compiles exactly
// ONE capsule. That isolates P1: with all five optional dims supplied by
// chemistry, P2's optionality is a no-op, and with a single compile there is no
// consecutive-family run for P4 and no gap for P7. Any drift this fixture catches
// is a drift in the config threading itself, which is precisely what it guards.
//
// PROVENANCE OF THE GOLDEN STRING: captured by running this exact fixture against
// the pre-P1 tree (commit ca5b9c5f) and against the post-P1 tree; both produced
// the literal below. It is not a snapshot of "whatever the code does now".
@Suite("PersonalityDynamicsGolden")
struct PersonalityDynamicsGoldenTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    // MARK: - 1. the literals

    @Test func defaultConfigurationCarriesTodaysExactLiterals() {
        let d = PersonalityDynamicsConfiguration.default
        // Felt warmth range (2026-08-02 calibration).
        #expect(d.feltWarmthRest == 0.55)
        #expect(d.feltWarmthEarnedSpan == 0.30)
        #expect(d.feltWarmthUncertaintyCooling == 0.45)
        // Sound echo.
        #expect(d.soundEchoWindow == 604_800)
        #expect(d.soundEchoWarmthFloor == 0.25)
        #expect(d.soundEchoFragmentMaxCharacters == 90)
        #expect(d.soundEchoCount == 2)
        #expect(d.soundEchoRecencyHalfLife == 216_000)
        #expect(d.soundEchoDutyCycle == 4)
        #expect(d.soundRutRecentTurnLimit == 12)
        #expect(d.soundRutEdgeSentenceCount == 2)
        #expect(d.soundEchoRegisterTolerance == 0.35)
        #expect(d.wornEchoThreshold == 3)
        // Fingerprint.
        #expect(d.fingerprintTintHalfLife == 300)
        #expect(d.personaValenceLift == 0.10)
        #expect(d.feltIntensityFloor == 0.14)
        // Mood + disposition.
        #expect(d.moodRecencyHalfLife == 21_600)
        #expect(d.dispositionHalfLife == 108_000)
        #expect(d.dispositionNudgeMagnitude == 0.08)
        #expect(d.dispositionValenceCap == 0.35)
        // Affect decay.
        #expect(d.arousalHalfLife == 1_200)
        #expect(d.uncertaintyHalfLife == 2_700)
        #expect(d.taskPressureHalfLife == 2_700)
        #expect(d.socialWarmthHalfLife == 5_400)
        // W4 additions default to today's behavior: the fingerprint duty cycle is
        // 1 (every capsule), so only suppress-when-unchanged is a live change.
        #expect(d.fingerprintDutyCycle == 1)
    }

    /// The dependency default must BE the default config, or every substrate
    /// constructed without an explicit dynamics closure quietly gets something else.
    @Test func dependenciesDefaultToTheDefaultDynamics() {
        #expect(CognitiveSubstrateDependencies.live.dynamics() == .default)
        #expect(CognitiveSubstrateDependencies().dynamics() == .default)
        #expect(CognitiveSubstrate.defaultDynamics == .default)
    }

    // MARK: - 2. neutral dials are a no-op

    @Test func neutralTraitDialsDeriveExactlyTheDefault() {
        #expect(PersonalityDynamicsConfiguration.derived(from: .neutral) == .default)
        // And explicitly 0.5 on every dial, not just the `neutral` alias.
        let explicitlyNeutral = PersonalityTraitDials(
            warmth: 0.5, directness: 0.5, humor: 0.5, proactivity: 0.5,
            rigor: 0.5, autonomy: 0.5, creativity: 0.5, brevity: 0.5)
        #expect(PersonalityDynamicsConfiguration.derived(from: explicitlyNeutral) == .default)
    }

    /// Bounded in BOTH directions — the whole safety argument for letting a
    /// persona document touch the physics. A maxed warmth dial must not be able
    /// to walk the earned span anywhere near where `tender` becomes the resting
    /// state again (the 2026-08-02 defect).
    @Test func traitDerivationStaysInsideHonestBounds() {
        let base = PersonalityDynamicsConfiguration.default
        let hot = PersonalityDynamicsConfiguration.derived(from: PersonalityTraitDials(warmth: 1))
        let cold = PersonalityDynamicsConfiguration.derived(from: PersonalityTraitDials(warmth: 0))

        #expect(hot.feltWarmthEarnedSpan > base.feltWarmthEarnedSpan)
        #expect(cold.feltWarmthEarnedSpan < base.feltWarmthEarnedSpan)
        // ±50% of the default span, and never past it.
        #expect(abs(hot.feltWarmthEarnedSpan - 0.45) < 0.0001)
        #expect(abs(cold.feltWarmthEarnedSpan - 0.15) < 0.0001)

        // The `tender` word gate is 0.70. Even at a maxed warmth dial AND maxed
        // raw social warmth, resting warmth (raw 0) must stay clear of it.
        for dial in stride(from: 0.0, through: 1.0, by: 0.1) {
            let c = PersonalityDynamicsConfiguration.derived(from: PersonalityTraitDials(warmth: dial))
            let rest: Double = c.feltWarmthRest
            #expect(rest < 0.70)
            #expect(c.feltWarmthRest == base.feltWarmthRest)
            _ = dial
        }

        // Out-of-range dials clamp rather than escaping the band.
        let overdriven = PersonalityDynamicsConfiguration.derived(from: PersonalityTraitDials(warmth: 9))
        #expect(overdriven.feltWarmthEarnedSpan == hot.feltWarmthEarnedSpan)
    }

    /// The two dials the campaign named as "land as config fields consumed later"
    /// must actually land — an unread field that never gets written is a stub.
    @Test func brevityAndHumorDialsReachTheirConfigFields() {
        let terse = PersonalityDynamicsConfiguration.derived(from: PersonalityTraitDials(brevity: 0.9))
        #expect(abs(terse.deliveryBrevityCenter - 0.9) < 0.0001)
        let funny = PersonalityDynamicsConfiguration.derived(from: PersonalityTraitDials(humor: 0.8))
        #expect(abs(funny.playModeWeight - 0.8) < 0.0001)
    }

    // MARK: - 3. the byte-identical capsule

    /// The fixture. Only pre-P1 API is used inside, so this exact function can be
    /// (and was) run against the pre-change tree to source the golden literal.
    private func compileGoldenCapsule(
        dependencies: CognitiveSubstrateDependencies,
        clock: Clock
    ) async -> String {
        let substrate = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: dependencies)
        // A mixed stretch: her own attested turns (so the exemplar shelf and the
        // rut detector both have material) plus warm user turns (so the warmth
        // range constants are actually exercised, not bypassed at rest).
        let script: [(CognitiveEventKind, String, String)] = [
            (.userMessageReceived, "chat_turn", "morning — picking the substrate work back up"),
            (.assistantTurnCompleted, "chat.assistant_turn",
             "Morning. The register fix is in and the whole suite is green."),
            (.userMessageReceived, "chat_turn", "that's great work, exactly what I hoped for"),
            (.assistantTurnCompleted, "chat.assistant_turn",
             "Glad it landed. The pool finally reaches the ranking now."),
            (.userMessageReceived, "chat_turn", "love it — let's keep going on the next one"),
        ]
        for (index, entry) in script.enumerated() {
            clock.advance(120)
            await substrate.ingest(CognitiveEvent(
                id: "golden-\(index)",
                kind: entry.0,
                subject: CognitiveSubjectReference(
                    type: entry.1, id: "golden:\(index)", label: "t"),
                sourceClass: .userStated,
                occurredAt: clock.now(),
                summary: entry.2,
                importance: 0.85,
                metadata: ["sessionId": .string("golden")]))
        }
        clock.advance(60)
        // ORGANISM ON: chemistry supplies all five optional dims, so P2's
        // optionality cannot move this fixture and the pin isolates P1.
        let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "where did we get to?",
            sessionId: "golden",
            mode: .inject,
            organismProjection: OrganismProjection(
                generatedAt: clock.now(),
                chemicalState: ChemicalState.neutral,
                bodySchema: .neutral)))
        return "\(capsule.stableKernel)\n\(capsule.dynamicContext)"
    }

    /// THE PIN. A default-config capsule is byte-identical to the pre-P1 capsule.
    @Test func defaultConfigurationYieldsAByteIdenticalCapsule() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let text = await compileGoldenCapsule(
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() }, makeUUID: { UUID() }),
            clock: clock)
        let expected = Self.goldenCapsule
        let diagnostic: String = "expected " + expected.debugDescription
            + " / actual " + text.debugDescription
            + " — an intentional behavior change does NOT belong under a default"
            + " config; thread it through PersonalityDynamicsConfiguration with"
            + " the default preserving today's literals, exactly as P1 requires."
        #expect(text == expected, Comment(rawValue: diagnostic))
    }

    /// Passing the default explicitly must be indistinguishable from passing
    /// nothing — otherwise the threading has a seam the default does not cover.
    @Test func explicitDefaultDynamicsMatchesTheImplicitOne() async throws {
        let implicitClock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let implicit = await compileGoldenCapsule(
            dependencies: CognitiveSubstrateDependencies(
                now: { implicitClock.now() }, makeUUID: { UUID() }),
            clock: implicitClock)

        let explicitClock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let explicit = await compileGoldenCapsule(
            dependencies: CognitiveSubstrateDependencies(
                now: { explicitClock.now() },
                makeUUID: { UUID() },
                dynamics: { .default }),
            clock: explicitClock)

        #expect(implicit == explicit)
    }

    /// NEGATIVE CONTROL. A test that only ever sees the default cannot tell a
    /// threaded constant from a still-hardcoded one. Changing the config must
    /// MOVE the capsule — if this passes while the pin above also passes, the
    /// wiring is real.
    @Test func aChangedConfigurationActuallyMovesTheCapsule() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        // Warmth rest driven to the floor: the felt word must change.
        let cooled: PersonalityDynamicsConfiguration = {
            var c = PersonalityDynamicsConfiguration.default
            c.feltWarmthRest = 0.05
            c.feltWarmthEarnedSpan = 0.05
            return c
        }()
        let text = await compileGoldenCapsule(
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() }, makeUUID: { UUID() }, dynamics: { cooled }),
            clock: clock)
        #expect(text != Self.goldenCapsule, """
            A cooled warmth configuration must change the felt words. If it does \
            not, the constant is still hardcoded somewhere on the read path and \
            the golden pin above is proving nothing.
            """)
    }

    /// Captured from the fixture above. See the provenance note at the top.
    private static let goldenCapsule = GoldenCapsuleLiteral.value
}

/// Kept in its own type so the literal is trivially diffable in review.
enum GoldenCapsuleLiteral {
    static let value = """
        How you feel:
        warm
        """
}
