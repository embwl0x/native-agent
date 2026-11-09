import Foundation

// Blueprint: | `PersonalityDynamicsConfiguration.swift` | `PersonalityDynamicsConfiguration`: bounds and checked persona warmth/humor |

/// Fixed felt-layer constants with bounded warmth and humor derived from the persona.
public struct PersonalityDynamicsConfiguration: Sendable, Equatable {
    private static let baseWarmthEarnedSpan = 0.30

    // MARK: - Felt warmth range (CognitiveSubstrate+Capsule.swift)

    /// Where felt warmth rests with no earned warmth at all. Sits AT the `warm` word gate and clear of `tender`, so an agent has a reachable neutral.
    public let feltWarmthRest: Double = 0.55
    /// Only live social warmth earns this scale span.
    public let feltWarmthEarnedSpan: Double?
    /// Uncertainty cools felt warmth without making a tense working moment cold.
    public let feltWarmthUncertaintyCooling: Double = 0.45

    // MARK: - Self-exemplar voice echo

    /// Bound voice exemplars to recent lived wording.
    public let soundEchoWindow: TimeInterval = 7 * 24 * 60 * 60
    /// AUTHENTICITY FLOOR, not a register filter: its only job is keeping never-minted stock phrasing out of the candidate pool.
    public let soundEchoWarmthFloor: Double = 0.25
    /// Quote fragments whole within this bound.
    public let soundEchoFragmentMaxCharacters: Int = 90
    /// Bound quoted fragments per echo.
    public let soundEchoCount: Int = 2
    /// Age decay on exemplar ranking — a warm moment echoes for a couple of days, then yields to newer warmth.
    public let soundEchoRecencyHalfLife: TimeInterval = 2.5 * 24 * 60 * 60
    /// Use one echo in N capsules; every-turn cues would become standing instructions.
    public let soundEchoDutyCycle: Int = 4
    /// Bound rut detection to recent assistant turns.
    public let soundRutRecentTurnLimit: Int = 20
    /// Half-width of the register band: candidates are ranked by how well they MATCH the room, not by how warm they are in absolute terms.
    public let soundEchoRegisterTolerance: Double = 0.35
    /// Require recurrence across fragments before declaring a word worn.
    public let wornEchoThreshold: Int = 3
    /// Rut nudges require a worn-set change or the repeat window, always respecting the minimum turn gap.
    public let soundRutMinimumTurnGap: Int = 2
    public let soundRutRepeatTurnGap: Int = 20
    public let soundRutRepeatWindow: TimeInterval = 6 * 60 * 60
    /// Echo ranking is `register-fit × age-decay × (1 + weight·landing)`. The 0.85…1.15 landing factor cannot override a register mismatch.
    public let soundEchoLandingWeight: Double = 0.15

    // MARK: - Felt fingerprint

    /// Recent workspace feeling fades faster than the mood integral.
    public let fingerprintTintHalfLife: TimeInterval = 300
    /// Asymmetric warm-with-the-user baseline lift on fingerprint valence.
    public let personaValenceLift: Double = 0.10
    /// Below this intensity no expressive fingerprint word is chosen; the frame still describes the available mood and body.
    public let feltIntensityFloor: Double = 0.14

    // MARK: - Felt object and ambivalence

    /// Refuse subject labels beyond the bound; truncation would invent a named thing.
    public let feltObjectMaximumLabelCharacters: Int = 32
    /// Match the silence floor so ambivalence requires two actual feelings rather than faint noise.
    public let feltAmbivalenceNodeFloor: Double = 0.14

    // MARK: - Mood + disposition (CognitiveSubstrate+Mood.swift)

    /// Recency weighting half-life for the mood's emotional-tag integral.
    public let moodRecencyHalfLife: TimeInterval = 6 * 60 * 60
    /// Day-scale decay of the settled disposition undertone.
    public let dispositionHalfLife: TimeInterval = 30 * 60 * 60
    /// Bound each considered disposition nudge independently of its slower decay.
    public let dispositionNudgeMagnitude: Double = 0.08
    /// Hard bound on disposition valence; its mood contribution is weighted separately.
    public let dispositionValenceCap: Double = 0.35

    // MARK: - Affect decay (CognitiveSubstrate+Affect.swift)

    public let arousalHalfLife: TimeInterval = 20 * 60
    public let uncertaintyHalfLife: TimeInterval = 45 * 60
    public let taskPressureHalfLife: TimeInterval = 45 * 60
    public let socialWarmthHalfLife: TimeInterval = 90 * 60

    // MARK: - Felt session bridge

    /// Minimum gap across the user's doors; only the first returning turn may carry a bridge cue.
    public let sessionBridgeGapHours: Double = 6

    // MARK: - Trait-derived fields

    /// Weight of `play` mode in exemplar selection, derived from the persona's humor trait.
    public let playModeWeight: Double?

    private init(feltWarmthEarnedSpan: Double? = PersonalityDynamicsConfiguration.baseWarmthEarnedSpan, playModeWeight: Double? = 0.5) {
        self.feltWarmthEarnedSpan = feltWarmthEarnedSpan
        self.playModeWeight = playModeWeight
    }

    public static let `default` = PersonalityDynamicsConfiguration()
    /// Fixed rates remain usable; no warmth/humor is invented before a good read.
    public static let unavailable = PersonalityDynamicsConfiguration(feltWarmthEarnedSpan: nil, playModeWeight: nil)

    /// Warmth changes only the earned span, never the resting warmth.
    public static func derived(warmth: Double, humor: Double) -> PersonalityDynamicsConfiguration {
        let centeredWarmth = (warmth.clamped01() - 0.5) * 2
        return PersonalityDynamicsConfiguration(
            feltWarmthEarnedSpan: baseWarmthEarnedSpan * (1 + centeredWarmth * 0.5),
            playModeWeight: humor.clamped01()
        )
    }
}
