import Foundation

// Blueprint: | `PersonalityDynamicsConfiguration.swift` | `PersonalityDynamicsConfiguration`: fixed felt-layer bounds and persona-derived warmth/humor parameters |

/// Fixed felt-layer constants with bounded warmth and humor derived from the persona.
public struct PersonalityDynamicsConfiguration: Sendable, Equatable {

    // MARK: - Felt warmth range (CognitiveSubstrate+Capsule.swift)

    /// Where felt warmth rests with no earned warmth at all. Sits AT the `warm`
    /// word gate and clear of `tender`, so an agent has a reachable neutral.
    public let feltWarmthRest: Double = 0.55
    /// How much of the warmth scale live social warmth can EARN. The 2026-08-02
    /// range fix: the top of the scale is earned, not where she starts.
    public let feltWarmthEarnedSpan: Double
    /// How strongly uncertainty cools felt warmth (a tense working moment reads
    /// cool rather than cold).
    public let feltWarmthUncertaintyCooling: Double = 0.45

    // MARK: - Self-exemplar voice echo

    /// How far back the exemplar shelf reaches.
    public let soundEchoWindow: TimeInterval = 7 * 24 * 60 * 60
    /// AUTHENTICITY FLOOR, not a register filter: its only job is keeping
    /// never-minted stock phrasing out of the candidate pool.
    public let soundEchoWarmthFloor: Double = 0.25
    /// Longest fragment that may be quoted back whole.
    public let soundEchoFragmentMaxCharacters: Int = 90
    /// How many fragments one echo line may carry.
    public let soundEchoCount: Int = 2
    /// Age decay on exemplar ranking — a warm moment echoes for a couple of days,
    /// then yields to newer warmth.
    public let soundEchoRecencyHalfLife: TimeInterval = 2.5 * 24 * 60 * 60
    /// THE TIC FIX: one in N capsules may carry the echo. A signal delivered on
    /// every single turn stops being information and becomes a standing
    /// instruction.
    public let soundEchoDutyCycle: Int = 4
    /// How many recent assistant turns the verbal-rut detector reads.
    public let soundRutRecentTurnLimit: Int = 20
    /// Half-width of the register band: candidates are ranked by how well they
    /// MATCH the room, not by how warm they are in absolute terms.
    public let soundEchoRegisterTolerance: Double = 0.35
    /// How many of the window's fragments a distinctive word must appear in
    /// before it counts as WORN.
    public let wornEchoThreshold: Int = 3
    /// LAW 2 APPLIED TO THE RUT NUDGE (2026-09-01). Measured over 777 live
    /// turns the rut-awareness line rode 82% of capsules: the detector fires
    /// while the worn set is non-empty, and a worn set stays non-empty for
    /// days, so the nudge re-fired every single turn. A nudge on 82% of turns
    /// is a floor, not a signal — and worse, the thing it nags about is
    /// repetition, so the cure became the symptom.
    ///
    /// The line is now CHANGE-DRIVEN: it speaks when the worn SET changes (a
    /// new tic is news), never on consecutive capsules, and otherwise only
    /// after a long window. `soundRutMinimumTurnGap` is the never-consecutive
    /// floor a CHANGE must still clear; `soundRutRepeatTurnGap` /
    /// `soundRutRepeatWindow` are the "still stuck, say it again" escape
    /// hatches so an unchanging rut is not silent forever.
    public let soundRutMinimumTurnGap: Int = 2
    public let soundRutRepeatTurnGap: Int = 20
    public let soundRutRepeatWindow: TimeInterval = 6 * 60 * 60
    /// W7/P10 — λ. Echo ranking is `register-fit × age-decay × (1 + λ·landing)`.
    /// Deliberately small: landing RE-RANKS inside a register band, it never
    /// overrides register fit. At 0.15 the factor spans 0.85…1.15, which cannot
    /// close the fit gap between a matched and a mismatched register.
    public let soundEchoLandingWeight: Double = 0.15

    // MARK: - Felt fingerprint

    /// Fast-layer recency for the immediate workspace tint.
    public let fingerprintTintHalfLife: TimeInterval = 300
    /// Asymmetric warm-with-the-user baseline lift on fingerprint valence.
    public let personaValenceLift: Double = 0.10
    /// Below this intensity the fingerprint stays silent — feeling-silence stays
    /// silence.
    public let feltIntensityFloor: Double = 0.14

    // MARK: - Felt OBJECT + AMBIVALENCE (2026-09-02, Agent complaints #1 and #2)

    /// Longest subject label the felt line may name as its OBJECT. A label
    /// longer than this is REFUSED, never trimmed: truncating a title mid-word
    /// invents a phrase she would then read as the name of a thing.
    public let feltObjectMaximumLabelCharacters: Int = 32
    /// How strong a felt node's valence must be before it may be one half of an
    /// ambivalence pair. Same magnitude as the fingerprint's own silence floor:
    /// a contradiction is only honest between two feelings that are actually
    /// there, and the failure this gates against is manufacturing conflict out
    /// of two faint stirrings.
    public let feltAmbivalenceNodeFloor: Double = 0.14

    // MARK: - Mood + disposition (CognitiveSubstrate+Mood.swift)

    public let moodRecencyHalfLife: TimeInterval = 6 * 60 * 60
    public let dispositionHalfLife: TimeInterval = 30 * 60 * 60
    public let dispositionNudgeMagnitude: Double = 0.08
    public let dispositionValenceCap: Double = 0.35

    // MARK: - Affect decay (CognitiveSubstrate+Affect.swift)

    public let arousalHalfLife: TimeInterval = 20 * 60
    public let uncertaintyHalfLife: TimeInterval = 45 * 60
    public let taskPressureHalfLife: TimeInterval = 45 * 60
    public let socialWarmthHalfLife: TimeInterval = 90 * 60

    // MARK: - Capsule cadence (W4/P4)

    /// SUPPRESS-WHEN-UNCHANGED: after this many consecutive capsules reporting
    /// the SAME felt family, the fingerprint line goes quiet. An identical
    /// "How you feel: warm" for forty consecutive turns is a stuck gauge, and the
    /// model will express it.
    public let fingerprintFamilyRepeatLimit: Int = 4
    /// A suppressed fingerprint re-surfaces on the next family change OR when
    /// this window expires, whichever comes first — so a genuinely persistent
    /// state is never muted forever.
    public let fingerprintSuppressionWindow: TimeInterval = 20 * 60

    // MARK: - Felt session bridge (W4/P7)

    /// A gap in USER's turns (any door) of at least this long makes his next
    /// turn the first one back, the only turn the bridge line may speak on.
    /// Six hours (Phase 5 B2, replayed on 09-26…10-03): a night or a workday
    /// away, about one a day (8 gaps in the week, 7 with something in them);
    /// four hours would also recap afternoon breaks (13 a week), and not every
    /// return earns a recap.
    public let sessionBridgeGapHours: Double = 6

    // MARK: - Trait-derived fields

    /// How strongly a `play` felt mode is weighted in mode-driven selection
    /// (P11 echo targeting today, the delivery envelope later). Derived from the
    /// `humor` trait.
    public let playModeWeight: Double

    private init(feltWarmthEarnedSpan: Double = 0.30, playModeWeight: Double = 0.5) {
        self.feltWarmthEarnedSpan = feltWarmthEarnedSpan
        self.playModeWeight = playModeWeight
    }

    public static let `default` = PersonalityDynamicsConfiguration()

    /// Warmth changes only the earned span, never the resting warmth.
    public static func derived(warmth: Double, humor: Double) -> PersonalityDynamicsConfiguration {
        let centeredWarmth = (warmth.clamped01() - 0.5) * 2
        return PersonalityDynamicsConfiguration(
            feltWarmthEarnedSpan: Self.default.feltWarmthEarnedSpan * (1 + centeredWarmth * 0.5),
            playModeWeight: humor.clamped01()
        )
    }
}
