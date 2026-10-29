import Foundation

// Blueprint: | `PersonalityDynamicsConfiguration.swift` | `PersonalityDynamicsConfiguration`: fixed felt-layer bounds and persona-derived warmth/humor parameters |

/// Fixed felt-layer constants with bounded warmth and humor derived from the persona.
public struct PersonalityDynamicsConfiguration: Sendable, Equatable {

    // MARK: - Felt warmth range (CognitiveSubstrate+Capsule.swift)

    /// Where felt warmth rests with no earned warmth at all. Sits AT the `warm`
    /// word gate and clear of `tender`, so an agent has a reachable neutral.
    public let feltWarmthRest: Double = 0.55
    /// The span of the warmth scale earned through live social warmth.
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
    /// Rut nudges require a worn-set change or the repeat window, always respecting the minimum turn gap.
    public let soundRutMinimumTurnGap: Int = 2
    public let soundRutRepeatTurnGap: Int = 20
    public let soundRutRepeatWindow: TimeInterval = 6 * 60 * 60
    /// Echo ranking is `register-fit × age-decay × (1 + weight·landing)`.
    /// The 0.85…1.15 landing factor cannot override a register mismatch.
    public let soundEchoLandingWeight: Double = 0.15

    // MARK: - Felt fingerprint

    /// Fast-layer recency for the immediate workspace tint.
    public let fingerprintTintHalfLife: TimeInterval = 300
    /// Asymmetric warm-with-the-user baseline lift on fingerprint valence.
    public let personaValenceLift: Double = 0.10
    /// Below this intensity the fingerprint stays silent — feeling-silence stays
    /// silence.
    public let feltIntensityFloor: Double = 0.14

    // MARK: - Felt object and ambivalence

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

    /// Recency weighting half-life for the mood's emotional-tag integral.
    public let moodRecencyHalfLife: TimeInterval = 6 * 60 * 60
    /// Day-scale decay of the settled disposition undertone.
    public let dispositionHalfLife: TimeInterval = 30 * 60 * 60
    /// Per-write scale for reflection, dream and resolution-pattern tones.
    public let dispositionNudgeMagnitude: Double = 0.08
    /// Hard bound on disposition valence; its mood contribution is weighted separately.
    public let dispositionValenceCap: Double = 0.35

    // MARK: - Affect decay (CognitiveSubstrate+Affect.swift)

    public let arousalHalfLife: TimeInterval = 20 * 60
    public let uncertaintyHalfLife: TimeInterval = 45 * 60
    public let taskPressureHalfLife: TimeInterval = 45 * 60
    public let socialWarmthHalfLife: TimeInterval = 90 * 60

    // MARK: - Capsule cadence

    /// Same-family readings allowed by the cadence verdict.
    /// Live delivery also requires its pre-reset run to equal one.
    public let fingerprintFamilyRepeatLimit: Int = 4
    /// Wait before permitting an over-limit same-family cadence verdict.
    /// Expiry alone does not satisfy live assembly's first-run gate.
    public let fingerprintSuppressionWindow: TimeInterval = 20 * 60

    // MARK: - Felt session bridge

    /// Minimum gap across the user's doors; only the first returning turn may carry a bridge cue.
    public let sessionBridgeGapHours: Double = 6

    // MARK: - Trait-derived fields

    /// Weight of `play` mode in exemplar selection, derived from the persona's humor trait.
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
