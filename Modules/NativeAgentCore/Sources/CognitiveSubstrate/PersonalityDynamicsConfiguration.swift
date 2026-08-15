import Foundation

// PersonalityDynamicsConfiguration — W4/P1 (upgrade campaign Track D, ring 1).
//
// THE STRUCTURAL FACT THIS FIXES (L6 §0): every humanness constant in the
// substrate was a compile-time `static let`, so every install of the app had
// IDENTICAL emotional physics. Two agents with completely different persona
// documents warmed at the same rate, decayed at the same rate, echoed their own
// voice at the same cadence, and reached the same felt words at the same
// thresholds. Character depth that lives only in a prose document is character
// depth the machine cannot enforce, drift-check, or evolve — and it meant every
// tuning fix had to ship as a new hardcoded number, which is how a warmth
// baseline once got parked at the ceiling and told every agent it felt `tender`
// on every turn for weeks.
//
// Meanwhile `CompiledPersonalityTraits` (PersonaEngine) carries eight tuned
// dials per persona — warmth, directness, humor, proactivity, rigor, autonomy,
// creativity, brevity — and NOTHING consumed them. `PersonalityTraitDials` +
// `derived(from:)` below is the first consumer: the persona's NUMBERS start
// driving the persona's PHYSICS.
//
// HARD CONTRACT: `.default` is byte-for-byte today's literals, and neutral
// dials (every trait 0.5) derive exactly `.default`. Pinned by
// PersonalityDynamicsGoldenTests — a default-config capsule must be
// byte-identical to the pre-P1 capsule on a fixture substrate.
//
// NO VOCABULARY LIVES HERE. Every field is a number: a rate, a threshold, a
// cadence, or a cap. Nothing in this type can become a sentence the model reads.

/// The dynamics constants behind the felt layer, as configuration rather than
/// compile-time literals. Threaded through `CognitiveSubstrateDependencies`
/// exactly the way `now()` / `userName()` already are.
public struct PersonalityDynamicsConfiguration: Sendable, Equatable {

    // MARK: - Felt warmth range (CognitiveSubstrate+Capsule.swift)

    /// Where felt warmth rests with no earned warmth at all. Sits AT the `warm`
    /// word gate and clear of `tender`, so an agent has a reachable neutral.
    public var feltWarmthRest: Double
    /// How much of the warmth scale live social warmth can EARN. The 2026-08-02
    /// range fix: the top of the scale is earned, not where she starts.
    public var feltWarmthEarnedSpan: Double
    /// How strongly uncertainty cools felt warmth (a tense working moment reads
    /// cool rather than cold).
    public var feltWarmthUncertaintyCooling: Double

    // MARK: - Self-exemplar voice echo

    /// How far back the exemplar shelf reaches.
    public var soundEchoWindow: TimeInterval
    /// AUTHENTICITY FLOOR, not a register filter: its only job is keeping
    /// never-minted stock phrasing out of the candidate pool.
    public var soundEchoWarmthFloor: Double
    /// Longest fragment that may be quoted back whole.
    public var soundEchoFragmentMaxCharacters: Int
    /// How many fragments one echo line may carry.
    public var soundEchoCount: Int
    /// Age decay on exemplar ranking — a warm moment echoes for a couple of days,
    /// then yields to newer warmth.
    public var soundEchoRecencyHalfLife: TimeInterval
    /// THE TIC FIX: one in N capsules may carry the echo. A signal delivered on
    /// every single turn stops being information and becomes a standing
    /// instruction.
    public var soundEchoDutyCycle: Int
    /// How many recent assistant turns the verbal-rut detector reads.
    public var soundRutRecentTurnLimit: Int
    /// How many closing sentences count as a conversational edge.
    public var soundRutEdgeSentenceCount: Int
    /// Half-width of the register band: candidates are ranked by how well they
    /// MATCH the room, not by how warm they are in absolute terms.
    public var soundEchoRegisterTolerance: Double
    /// How many of the window's fragments a distinctive word must appear in
    /// before it counts as WORN.
    public var wornEchoThreshold: Int
    /// W7/P5 — the negative-register brake. Dropping the valence SIGN gate lets
    /// a stung-but-attested turn mirror a stung moment, which is the whole point;
    /// the hazard is the echo→reply→node loop deepening a bad mood. After this
    /// many consecutive negative-register echoes the next echo is drawn from the
    /// non-negative pool, whatever the register ranking would otherwise prefer.
    /// 0 disables negative echoes entirely; a large value disables the brake.
    public var soundEchoNegativeRunLimit: Int
    /// W7/P10 — λ. Echo ranking is `register-fit × age-decay × (1 + λ·landing)`.
    /// Deliberately small: landing RE-RANKS inside a register band, it never
    /// overrides register fit. At 0.15 the factor spans 0.85…1.15, which cannot
    /// close the fit gap between a matched and a mismatched register.
    public var soundEchoLandingWeight: Double

    // MARK: - Felt fingerprint

    /// Fast-layer recency for the immediate workspace tint.
    public var fingerprintTintHalfLife: TimeInterval
    /// Asymmetric warm-with-the-user baseline lift on fingerprint valence.
    public var personaValenceLift: Double
    /// Below this intensity the fingerprint stays silent — feeling-silence stays
    /// silence.
    public var feltIntensityFloor: Double

    // MARK: - Mood + disposition (CognitiveSubstrate+Mood.swift)

    public var moodRecencyHalfLife: TimeInterval
    public var dispositionHalfLife: TimeInterval
    public var dispositionNudgeMagnitude: Double
    public var dispositionValenceCap: Double

    // MARK: - Affect decay (CognitiveSubstrate+Affect.swift)

    public var arousalHalfLife: TimeInterval
    public var uncertaintyHalfLife: TimeInterval
    public var taskPressureHalfLife: TimeInterval
    public var socialWarmthHalfLife: TimeInterval

    // MARK: - Capsule cadence (W4/P4)

    /// One in N capsules may carry the felt-fingerprint line. 1 = every capsule
    /// (today's behavior); the suppress-when-unchanged rule below is the organ
    /// that actually damps a stuck gauge.
    public var fingerprintDutyCycle: Int
    /// SUPPRESS-WHEN-UNCHANGED: after this many consecutive capsules reporting
    /// the SAME felt family, the fingerprint line goes quiet. An identical
    /// "How you feel: warm" for forty consecutive turns is a stuck gauge, and the
    /// model will express it.
    public var fingerprintFamilyRepeatLimit: Int
    /// A suppressed fingerprint re-surfaces on the next family change OR when
    /// this window expires, whichever comes first — so a genuinely persistent
    /// state is never muted forever.
    public var fingerprintSuppressionWindow: TimeInterval

    // MARK: - Felt session bridge (W4/P7)

    /// A conversational gap of at least this long makes the NEXT turn the first
    /// turn after a gap, which is the only turn the bridge line may speak on.
    public var sessionBridgeGapHours: Double

    // MARK: - Trait-derived fields consumed by later waves

    /// Center of the reply-length band the delivery envelope will target (P6).
    /// Carried here so the `brevity` trait has a home the moment the envelope
    /// lands; nothing reads it yet.
    public var deliveryBrevityCenter: Double
    /// How strongly a `play` felt mode is weighted in mode-driven selection
    /// (P11 echo targeting today, the delivery envelope later). Derived from the
    /// `humor` trait.
    public var playModeWeight: Double

    public init(
        feltWarmthRest: Double = 0.55,
        feltWarmthEarnedSpan: Double = 0.30,
        feltWarmthUncertaintyCooling: Double = 0.45,
        soundEchoWindow: TimeInterval = 7 * 24 * 60 * 60,
        soundEchoWarmthFloor: Double = 0.25,
        soundEchoFragmentMaxCharacters: Int = 90,
        soundEchoCount: Int = 2,
        soundEchoRecencyHalfLife: TimeInterval = 2.5 * 24 * 60 * 60,
        soundEchoDutyCycle: Int = 4,
        soundRutRecentTurnLimit: Int = 12,
        soundRutEdgeSentenceCount: Int = 2,
        soundEchoRegisterTolerance: Double = 0.35,
        wornEchoThreshold: Int = 3,
        fingerprintTintHalfLife: TimeInterval = 300,
        personaValenceLift: Double = 0.10,
        feltIntensityFloor: Double = 0.14,
        moodRecencyHalfLife: TimeInterval = 6 * 60 * 60,
        dispositionHalfLife: TimeInterval = 30 * 60 * 60,
        dispositionNudgeMagnitude: Double = 0.08,
        dispositionValenceCap: Double = 0.35,
        arousalHalfLife: TimeInterval = 20 * 60,
        uncertaintyHalfLife: TimeInterval = 45 * 60,
        taskPressureHalfLife: TimeInterval = 45 * 60,
        socialWarmthHalfLife: TimeInterval = 90 * 60,
        fingerprintDutyCycle: Int = 1,
        fingerprintFamilyRepeatLimit: Int = 4,
        fingerprintSuppressionWindow: TimeInterval = 20 * 60,
        sessionBridgeGapHours: Double = 6,
        deliveryBrevityCenter: Double = 0.5,
        playModeWeight: Double = 0.5,
        soundEchoNegativeRunLimit: Int = 2,
        soundEchoLandingWeight: Double = 0.15
    ) {
        self.feltWarmthRest = feltWarmthRest
        self.feltWarmthEarnedSpan = feltWarmthEarnedSpan
        self.feltWarmthUncertaintyCooling = feltWarmthUncertaintyCooling
        self.soundEchoWindow = soundEchoWindow
        self.soundEchoWarmthFloor = soundEchoWarmthFloor
        self.soundEchoFragmentMaxCharacters = soundEchoFragmentMaxCharacters
        self.soundEchoCount = soundEchoCount
        self.soundEchoRecencyHalfLife = soundEchoRecencyHalfLife
        self.soundEchoDutyCycle = soundEchoDutyCycle
        self.soundRutRecentTurnLimit = soundRutRecentTurnLimit
        self.soundRutEdgeSentenceCount = soundRutEdgeSentenceCount
        self.soundEchoRegisterTolerance = soundEchoRegisterTolerance
        self.wornEchoThreshold = wornEchoThreshold
        self.fingerprintTintHalfLife = fingerprintTintHalfLife
        self.personaValenceLift = personaValenceLift
        self.feltIntensityFloor = feltIntensityFloor
        self.moodRecencyHalfLife = moodRecencyHalfLife
        self.dispositionHalfLife = dispositionHalfLife
        self.dispositionNudgeMagnitude = dispositionNudgeMagnitude
        self.dispositionValenceCap = dispositionValenceCap
        self.arousalHalfLife = arousalHalfLife
        self.uncertaintyHalfLife = uncertaintyHalfLife
        self.taskPressureHalfLife = taskPressureHalfLife
        self.socialWarmthHalfLife = socialWarmthHalfLife
        self.fingerprintDutyCycle = fingerprintDutyCycle
        self.fingerprintFamilyRepeatLimit = fingerprintFamilyRepeatLimit
        self.fingerprintSuppressionWindow = fingerprintSuppressionWindow
        self.sessionBridgeGapHours = sessionBridgeGapHours
        self.deliveryBrevityCenter = deliveryBrevityCenter
        self.playModeWeight = playModeWeight
        self.soundEchoNegativeRunLimit = max(0, soundEchoNegativeRunLimit)
        self.soundEchoLandingWeight = max(0, min(0.5, soundEchoLandingWeight))
    }

    /// Today's exact literals. The byte-identical baseline every other config is
    /// a bounded departure from.
    public static let `default` = PersonalityDynamicsConfiguration()
}

/// The eight persona dials, shape-for-shape `PersonaEngine.CompiledPersonalityTraits`
/// (warmth / directness / humor / proactivity / rigor / autonomy / creativity /
/// brevity, each clamped 0…1 by the compiler). Declared HERE rather than imported
/// so CognitiveSubstrate keeps its single dependency on PersistenceCore — the
/// assembly seam that already sees both modules does the field-for-field copy.
///
/// 0.5 on every dial is NEUTRAL and derives `.default` exactly.
public struct PersonalityTraitDials: Sendable, Equatable {
    public var warmth: Double
    public var directness: Double
    public var humor: Double
    public var proactivity: Double
    public var rigor: Double
    public var autonomy: Double
    public var creativity: Double
    public var brevity: Double

    public init(
        warmth: Double = 0.5,
        directness: Double = 0.5,
        humor: Double = 0.5,
        proactivity: Double = 0.5,
        rigor: Double = 0.5,
        autonomy: Double = 0.5,
        creativity: Double = 0.5,
        brevity: Double = 0.5
    ) {
        self.warmth = warmth.clamped01()
        self.directness = directness.clamped01()
        self.humor = humor.clamped01()
        self.proactivity = proactivity.clamped01()
        self.rigor = rigor.clamped01()
        self.autonomy = autonomy.clamped01()
        self.creativity = creativity.clamped01()
        self.brevity = brevity.clamped01()
    }

    public static let neutral = PersonalityTraitDials()
}

extension PersonalityDynamicsConfiguration {

    /// Derive dynamics from the persona's own dials, BOUNDED so a trait at either
    /// extreme still lands inside the honest ranges the current constants define.
    ///
    /// Bounding is the whole safety argument. A persona doc cannot push warmth to
    /// a place where `tender` becomes the resting state again (the exact defect
    /// the 2026-08-02 range fix cured), because the earned span is confined to a
    /// band around today's literal rather than scaled freely.
    ///
    /// - `warmth`   → `feltWarmthEarnedSpan` (how much warmth a persona can EARN,
    ///                never where it rests — rest stays the calibrated literal).
    /// - `brevity`  → `deliveryBrevityCenter` (consumed by P6's delivery envelope).
    /// - `humor`    → `playModeWeight` (consumed by P11's mode-driven selection).
    ///
    /// Every other field stays at its default: this wave deliberately derives only
    /// the three the campaign named. Adding a dial→constant edge is a decision per
    /// edge, not a bulk mapping.
    public static func derived(
        from dials: PersonalityTraitDials,
        base: PersonalityDynamicsConfiguration = .default
    ) -> PersonalityDynamicsConfiguration {
        var out = base
        out.feltWarmthEarnedSpan = boundedAroundDefault(
            base.feltWarmthEarnedSpan, dial: dials.warmth, relativeSpan: 0.5)
        out.deliveryBrevityCenter = dials.brevity
        out.playModeWeight = dials.humor
        return out
    }

    /// Map a 0…1 dial onto ±`relativeSpan` (fractional) around a default, with 0.5
    /// landing EXACTLY on the default. `relativeSpan: 0.5` means a maxed dial can
    /// move the constant by at most half its own magnitude in either direction.
    static func boundedAroundDefault(
        _ defaultValue: Double,
        dial: Double,
        relativeSpan: Double
    ) -> Double {
        let centered = (dial.clamped01() - 0.5) * 2      // −1 … +1, exactly 0 at 0.5
        return defaultValue * (1 + centered * relativeSpan)
    }
}
