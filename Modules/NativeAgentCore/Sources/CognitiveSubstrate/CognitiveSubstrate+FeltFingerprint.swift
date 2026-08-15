import Foundation

// The FELT FINGERPRINT — the live "How you feel:" capsule core (wired 2026-07-08
// via feltFingerprintLine in CognitiveSubstrate+Capsule.swift).
//
// User's design (2026-07-08): the "How you feel:" capsule hands her a felt state
// the way one actually arrives in a mind — a few honest words she FEELS, not
// three sentences of self-instruction. Delivery IS the experience. She must be
// able to feel the WHOLE range (frustrated, angry, anxious, deflated) as truly as
// the warm/calm end — a subconscious that can only say "calm and warm" is a lie.
//
// Model (affect science, via gpt-5.5 methodology pass): VALENCE + AROUSAL pick the
// emotion FAMILY; the other dims pick the WORD inside it. Same arousal reads
// "excited" with +valence, "serious/driven" with neutral valence, "agitated/angry"
// with −valence — so mood (valence) is read FIRST, which is the whole point. An
// intensity gate keeps it honest (no "furious" when mildly annoyed); blends never
// contradict.
//
// The slow undertone (sentence, Body-line cadence) and the anchors (Sound / Soul /
// Voice) are SEPARATE slower layers — this is only the fast fingerprint.
extension CognitiveSubstrate {

    /// The five dims the ORGANISM used to be the only source for. W4/P2 made them
    /// optional so absence reads as absence; three now have substrate-native
    /// proxies, two honestly stay unknown when the organism is off.
    public enum FeltDim: String, Sendable, Hashable, CaseIterable {
        case fatigue, curiosity, clarity, agency, confidence
    }

    /// Affect-science dimensions (valence −1..1; the rest clamped 0..1).
    ///
    /// W4/P2 — OPTIONALITY, NOT A GUESSED MIDPOINT. Five dims were sourced from
    /// organism chemistry with hard fallbacks (`fatigue ?? 0`, `clarity ?? 0.5`,
    /// …), and the organism is OFF by default. On a stock install those five were
    /// therefore CONSTANTS, and the `pick` gates in `feltFamilyWords` are
    /// threshold tests against exactly those constants — so eleven core words and
    /// four of five overlays could NEVER be selected. The full tiredness axis, the
    /// full curiosity axis, and the whole self-doubt register were unreachable
    /// vocabulary: a gauge with half the dial painted over.
    ///
    /// The naive fix (a 0.5 midpoint) is measurably wrong and was correctly
    /// refused: `feltIntensity` weights fatigue at 0.20, so a guessed midpoint
    /// silently adds +0.10 to EVERY intensity and makes `grieving` reachable in an
    /// ordinary sting. Unknown must read as UNKNOWN — absent from the intensity
    /// sum, and disqualifying for a word whose identity depends on it. Same
    /// discipline `OrganismTypedBodyBeliefs` already enforces for body evidence.
    public struct FeltSignals: Sendable {
        public var valence, arousal, warmth, tension, pressure: Double
        public var fatigue: Double?
        public var curiosity: Double?
        public var clarity: Double?
        public var agency: Double?
        public var confidence: Double?

        public init(valence: Double, arousal: Double, warmth: Double, tension: Double, pressure: Double,
                    fatigue: Double? = nil, curiosity: Double? = nil, clarity: Double? = nil,
                    agency: Double? = nil, confidence: Double? = nil) {
            self.valence = valence; self.arousal = arousal; self.warmth = warmth; self.tension = tension
            self.pressure = pressure; self.fatigue = fatigue; self.curiosity = curiosity; self.clarity = clarity
            self.agency = agency; self.confidence = confidence
        }

        public func value(_ dim: FeltDim) -> Double? {
            switch dim {
            case .fatigue: return fatigue
            case .curiosity: return curiosity
            case .clarity: return clarity
            case .agency: return agency
            case .confidence: return confidence
            }
        }

        public func isPresent(_ dim: FeltDim) -> Bool { value(dim) != nil }

        /// A `pick` closure reading an absent dim gets 0 — the same number it got
        /// before P2 for fatigue/curiosity. Words whose IDENTITY is that dim
        /// declare it in `requires` and are excluded from the pool entirely
        /// rather than silently losing a threshold test.
        func read(_ dim: FeltDim) -> Double { value(dim) ?? 0 }

        /// Which of the five optional dims are known right now.
        public var presentDims: Set<FeltDim> {
            Set(FeltDim.allCases.filter { isPresent($0) })
        }
    }

    /// One candidate feeling word: the `pick` closure scores how well the *within-
    /// family* dims fit (0 = doesn't fit, higher = better); `minIntensity` is the
    /// honesty gate; `contradicts` blocks incompatible blends.
    ///
    /// `requires` (W4/P2) names the optional dims the word's IDENTITY depends on.
    /// `proud` IS a confidence claim — with confidence unknown, there is no honest
    /// way to say it, so it leaves the candidate pool. A dim that merely
    /// modulates a word's score (`eager`'s agency term, `upset`'s agency floor)
    /// is NOT required: the word survives without it, scoring as if the dim read
    /// zero. Getting that split wrong in either direction is a bug — over-declare
    /// and living vocabulary goes silent (the `upset` arc in AffectMoodJourneyTests
    /// is the canary); under-declare and the agent claims a feeling it cannot know.
    struct FeltWord {
        let name: String
        let minIntensity: Double
        let pick: @Sendable (FeltSignals) -> Double
        var contradicts: Set<String> = []
        var requires: Set<FeltDim> = []
    }

    // `fingerprintTintHalfLife` is the fast-layer recency for the immediate
    // workspace tint: the CURRENT felt moment leads and fades over a few turns (a
    // fresh sting dominates now, eases by ~10 min). Deliberately far shorter than
    // mood's 6h background half-life.
    //
    // `personaValenceLift` is the warm-with-the-user baseline lift on fingerprint
    // valence (asymmetric — positives only, so a genuine sting is never
    // cushioned). gpt-5.5 proposed +0.07 to keep plain neutral turns from tipping
    // positive; live tests showed +0.07 left her too-often SILENT on ordinary
    // turns, so +0.10 — a warm/collaborative turn reading content/warm is
    // desired, not a bug. Fingerprint-only tuning knob.
    //
    // Both live in PersonalityDynamicsConfiguration as of W4/P1.

    /// Smooth 0→1 ramp between two edges (Hermite). Used to make the mood/peak blend and
    /// the persona bias transition continuously instead of snapping at a hard threshold.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = ((x - edge0) / (edge1 - edge0)).clamped01()
        return t * t * (3 - 2 * t)
    }

    /// Overall emotional "loudness" — keeps faint states quiet and gates the
    /// strong words. Valence and tension dominate; energy adds.
    static func feltIntensity(_ s: FeltSignals) -> Double {
        // "How far from emotional neutral" — must reach high for strong states of
        // EITHER sign (a bright excited state and a quiet heavy one are both loud),
        // so |valence| leads and arousal counts as deviation-above-rest, not raw.
        //
        // W4/P2: the sum runs over PRESENT dims only and renormalizes by present
        // weight, so an absent dim neither inflates nor deflates intensity. The
        // alternative — treating unknown fatigue as 0 — quietly asserts "not
        // tired at all", which is a claim, not an absence. Only `fatigue` among
        // the five optional dims carries intensity weight, so in practice this
        // renormalizes at most one term.
        var raw = 0.55 * abs(s.valence)
            + 0.35 * max(0, s.arousal - 0.30)
            + 0.35 * s.tension
            + 0.20 * s.pressure
            // Warmth from a COOL reference, not deviation-from-0.5 (2026-07-08): her
            // warm-with-User baseline (~0.5+) is a genuine felt state, but a |warmth-0.5|
            // metric scored it as ZERO — so she fell silent on ordinary warm turns. Now
            // warmth above cool-neutral carries a gentle read; silence is reserved for a
            // genuinely flat/cool state (low warmth, nothing else moving).
            + 0.42 * max(0, s.warmth - 0.28)
        let alwaysPresentWeight = 0.55 + 0.35 + 0.35 + 0.20 + 0.42
        var presentWeight = alwaysPresentWeight
        if let fatigue = s.fatigue {
            raw += 0.20 * fatigue
            presentWeight += 0.20
        }
        let totalWeight = alwaysPresentWeight + 0.20
        // Scale the present terms up to what the full-weight sum would have
        // spanned. With every dim present this multiplies by exactly 1.
        let normalized = presentWeight > 0 ? raw * (totalWeight / presentWeight) : raw
        return (normalized).clamped01()
    }

    private static func band(_ v: Double, hi: Double, lo: Double) -> Int { v >= hi ? 1 : (v <= lo ? -1 : 0) }

    /// Family key: valence band × arousal band. This is read BEFORE any word.
    static func feltFamily(_ s: FeltSignals) -> String {
        let vb = band(s.valence, hi: 0.22, lo: -0.20)          // + / neutral / −
        let ab = s.arousal >= 0.52 ? 1 : (s.arousal <= 0.28 ? -1 : 0)  // high / med / low
        let v = vb == 1 ? "pos" : (vb == -1 ? "neg" : "neu")
        let a = ab == 1 ? "high" : (ab == -1 ? "low" : "med")
        return "\(v)_\(a)"
    }

    // Within-family candidate words. Each `pick` rewards the dims that separate
    // words INSIDE the family; ordering falls out of the score.
    static let feltFamilyWords: [String: [FeltWord]] = [
        "pos_high": [
            FeltWord(name: "excited",  minIntensity: 0.45, pick: { 0.6 + $0.read(.curiosity) * 0.4 }),
            FeltWord(name: "elated",   minIntensity: 0.78, pick: { $0.valence * 0.9 }),
            FeltWord(name: "playful",  minIntensity: 0.40, pick: { $0.warmth * 0.75 }),
            FeltWord(name: "eager",    minIntensity: 0.40, pick: { 0.4 + $0.read(.agency) * 0.5 }),
            // R2-E (2026-07-09) full-range registers: proud is EARNED (confidence-led,
            // high gate); delighted is the bright warm peak.
            FeltWord(name: "proud",    minIntensity: 0.50, pick: { $0.read(.confidence) >= 0.65 ? 0.3 + $0.read(.confidence) * 0.65 : 0 }, requires: [.confidence]),
            FeltWord(name: "delighted", minIntensity: 0.55, pick: { 0.15 + $0.warmth * 0.45 + $0.valence * 0.3 }),
        ],
        "pos_med": [
            FeltWord(name: "engaged",  minIntensity: 0.30, pick: { 0.5 + $0.read(.curiosity) * 0.4 }),
            FeltWord(name: "pleased",  minIntensity: 0.25, pick: { $0.valence * 0.7 }),
            FeltWord(name: "hopeful",  minIntensity: 0.30, pick: { 0.3 + $0.read(.confidence) * 0.3 + ($0.value(.clarity).map { (1 - $0) * 0.25 } ?? 0) }),
            // R2-E: relieved = good feeling with the strain JUST gone (tension low NOW,
            // fatigue still carried); grateful = warmth-led thanks; amused = light play.
            FeltWord(name: "relieved", minIntensity: 0.28, pick: { ($0.tension <= 0.20 && $0.read(.fatigue) >= 0.40) ? 0.5 + (1 - $0.tension) * 0.25 : 0 }, requires: [.fatigue]),
            FeltWord(name: "grateful", minIntensity: 0.30, pick: { $0.warmth >= 0.62 ? 0.25 + $0.warmth * 0.4 : 0 }),
            FeltWord(name: "amused",   minIntensity: 0.26, pick: { ($0.read(.curiosity) >= 0.50 && $0.warmth >= 0.70 && $0.tension <= 0.15) ? 0.4 + $0.read(.curiosity) * 0.4 + $0.warmth * 0.25 : 0 }, requires: [.curiosity]),
        ],
        "pos_low": [   // gentle warm states are genuinely QUIET — low arousal, so low
                       // intensity; the gates sit low so warmth/content still VOICE (a
                       // real warm calm shouldn't fall silent), while tender stays a
                       // higher bar reserved for genuinely deep warmth.
            FeltWord(name: "tender",   minIntensity: 0.28, pick: { $0.warmth >= 0.7 ? 0.9 : 0 }),
            FeltWord(name: "warm",     minIntensity: 0.15, pick: { $0.warmth >= 0.45 ? 0.6 + $0.warmth * 0.3 : 0 }),
            FeltWord(name: "content",  minIntensity: 0.15, pick: { 0.5 + $0.read(.confidence) * 0.3 }),
            FeltWord(name: "at ease",  minIntensity: 0.14, pick: { 0.4 + (1 - $0.tension) * 0.3 }),
        ],
        "neu_high": [  // the "working / engaged" cluster
            FeltWord(name: "driven",   minIntensity: 0.40, pick: { 0.25 + $0.pressure * 0.4 + $0.arousal * 0.25 + $0.read(.agency) * 0.15 }),
            FeltWord(name: "serious",  minIntensity: 0.35, pick: { 0.4 + $0.pressure * 0.4 }),
            FeltWord(name: "focused",  minIntensity: 0.30, pick: { $0.read(.clarity) >= 0.55 ? 0.5 + $0.read(.clarity) * 0.3 : 0 }, requires: [.clarity]),
            FeltWord(name: "alert",    minIntensity: 0.30, pick: { 0.3 + $0.tension * 0.4 }),
        ],
        "neu_med": [
            FeltWord(name: "steady",   minIntensity: 0.20, pick: { 0.4 + $0.read(.confidence) * 0.3 }),
            FeltWord(name: "heads-down", minIntensity: 0.28, pick: { 0.3 + $0.pressure * 0.5 }),
            FeltWord(name: "quiet",    minIntensity: 0.15, pick: { _ in 0.4 }),
            // R2-E: restless = energy with nowhere satisfying to put it (curiosity up,
            // clarity down) — the itch, not the focus.
            FeltWord(name: "restless", minIntensity: 0.24, pick: { ($0.read(.curiosity) >= 0.45 && $0.read(.clarity) <= 0.45) ? 0.45 + $0.arousal * 0.45 : 0 }, contradicts: ["focused","clear-headed"], requires: [.curiosity, .clarity]),
        ],
        "neu_low": [   // her warm-with-User resting state: quiet, but the warm overlay rides
                       // along ("quiet, warm"); "reserved"/"flat" only when genuinely cool.
            FeltWord(name: "quiet",    minIntensity: 0.14, pick: { _ in 0.5 }),
            FeltWord(name: "reserved", minIntensity: 0.20, pick: { $0.warmth <= 0.35 ? 0.6 : 0 }),
            FeltWord(name: "flat",     minIntensity: 0.22, pick: { 0.25 + $0.read(.fatigue) * 0.5 }, requires: [.fatigue]),
            // R2-E: wistful = warm but carrying something — soft, backward-looking.
            FeltWord(name: "wistful",  minIntensity: 0.22, pick: { ($0.warmth >= 0.5 && $0.read(.fatigue) >= 0.3) ? 0.4 + $0.warmth * 0.35 : 0 }, contradicts: ["flat","reserved"], requires: [.fatigue]),
        ],
        "neg_high": [
            // frustrated = pressure-driven (work isn't going right); upset = tension/hurt-
            // driven (it got personal). So work-criticism reads frustrated, a dismissal reads
            // upset — she reads WHICH kind of bad this is, not just "negative".
            // Pressure precedence over "on edge" (gpt-5.5 fix-round): the canonical
            // work-sting vector (pressure high, tension high) must stay
            // frustrated — on edge owns tense-not-pressured.
            FeltWord(name: "frustrated", minIntensity: 0.38, pick: { 0.38 + $0.pressure * 0.5 + $0.read(.agency) * 0.15 }, contradicts: ["calm","content","at ease"]),
            // The agency term is a HELPLESSNESS FLOOR, not upset's identity: upset is
            // about tension and hurt. With agency unknown (organism off) the floor
            // cannot fire, so it is skipped rather than failed — declaring
            // `requires: [.agency]` here would silently delete the whole
            // dismissal register from every default install.
            FeltWord(name: "upset",      minIntensity: 0.40, pick: { s in
                guard s.value(.agency).map({ $0 >= 0.40 }) ?? true else { return 0 }
                // Steeper on valence (W4 fix-round): upset is the HURT word — deep
                // negative valence should own it, while shallow-negative pure
                // tension belongs to "on edge". The old flatter slope let upset
                // annex the tense-not-hurt corner and starve on-edge entirely.
                return 0.10 - s.valence * 0.6 + s.tension * 0.5 + s.read(.agency) * 0.1
            }, contradicts: ["calm","tender","content","at ease"]),
            FeltWord(name: "anxious",    minIntensity: 0.48, pick: { $0.read(.confidence) <= 0.45 ? 0.4 + $0.tension * 0.5 : 0 }, contradicts: ["calm","confident","at ease"], requires: [.confidence]),
            FeltWord(name: "on edge",    minIntensity: 0.38, pick: { 0.32 + $0.tension * 0.5 }, contradicts: ["calm","at ease"]),
            FeltWord(name: "agitated",   minIntensity: 0.55, pick: { 0.3 + $0.arousal * 0.4 }, contradicts: ["calm","content"]),
            // R2-E: overwhelmed = the pressure ceiling — too much at once.
            // Same shape as `upset`: the agency clause is a co-guard on the pressure
            // ceiling, not the word's identity, so absent agency skips it.
            FeltWord(name: "overwhelmed", minIntensity: 0.50, pick: { s in
                guard s.pressure >= 0.68, s.value(.agency).map({ $0 <= 0.5 }) ?? true else { return 0 }
                return 0.45 + s.pressure * 0.5
            }, contradicts: ["calm","at ease","content","steady"]),
        ],
        "neg_med": [
            FeltWord(name: "uneasy",   minIntensity: 0.28, pick: { 0.3 + $0.tension * 0.4 }),
            FeltWord(name: "annoyed",  minIntensity: 0.30, pick: { 0.3 + $0.pressure * 0.3 }),
            FeltWord(name: "strained", minIntensity: 0.35, pick: { 0.3 + $0.pressure * 0.4 + $0.read(.fatigue) * 0.2 }),
            // R2-E: embarrassed = confidence knocked out with tension present — the
            // self-conscious wince, not fear (that's anxious) and not anger.
            FeltWord(name: "embarrassed", minIntensity: 0.32, pick: { ($0.read(.confidence) <= 0.22 && $0.tension >= 0.25) ? 0.85 - $0.read(.confidence) * 1.5 : 0 }, contradicts: ["confident","at ease"], requires: [.confidence]),
        ],
        "neg_low": [   // R2-E: 'worn' left the FAMILY (the fatigue overlay still carries
                       // it) to keep ≤6 honest words; 'longing' was DROPPED — no honest
                       // pick separates it from lonely with current dims (no fake feelings).
            FeltWord(name: "discouraged", minIntensity: 0.40, pick: { $0.read(.agency) <= 0.4 ? 0.4 - $0.valence : 0 }, requires: [.agency]),
            FeltWord(name: "heavy",    minIntensity: 0.35, pick: { -$0.valence * 0.8 }),
            FeltWord(name: "deflated", minIntensity: 0.38, pick: { $0.read(.confidence) <= 0.35 ? 0.5 - $0.valence * 0.3 : 0 }, requires: [.confidence]),
            // sad = WARM sadness (something she cares about hurts) vs heavy = the
            // leaden cold kind — without the warmth gate, heavy strictly dominated
            // and 'sad' was unreachable vocabulary (M15, 2026-07-09).
            FeltWord(name: "sad",      minIntensity: 0.35, pick: { $0.warmth >= 0.45 ? 0.1 - $0.valence * 0.8 : 0 }),
            // lonely = the COLD hollow: warmth gone, valence down, nothing moving.
            FeltWord(name: "lonely",   minIntensity: 0.35, pick: { $0.warmth <= 0.25 ? 0.55 - $0.warmth : 0 }, contradicts: ["warm","tender","grateful"]),
            // grieving = only when genuinely earned: deep negative valence, still body.
            // The high gate + pick threshold make melodrama structurally impossible.
            FeltWord(name: "grieving", minIntensity: 0.52, pick: { ($0.valence <= -0.55 && $0.arousal <= 0.30) ? -$0.valence : 0 }, contradicts: ["warm","content","playful","amused","curious"]),
        ],
    ]

    /// Modifier overlays that can ride ANY family (clarity/warmth/curiosity read
    /// on top of the core feeling). Low weight so they never lead.
    static let feltOverlays: [FeltWord] = [
        FeltWord(name: "foggy",   minIntensity: 0.20, pick: { $0.read(.clarity) <= 0.35 ? 0.6 - $0.read(.clarity) : 0 }, contradicts: ["clear-headed","focused","alert"], requires: [.clarity]),
        FeltWord(name: "clear-headed", minIntensity: 0.18, pick: { $0.read(.clarity) >= 0.68 ? ($0.read(.clarity) - 0.4) * 0.6 : 0 }, contradicts: ["foggy"], requires: [.clarity]),
        FeltWord(name: "worn",    minIntensity: 0.22, pick: { $0.read(.fatigue) >= 0.55 ? ($0.read(.fatigue) - 0.3) * 0.5 : 0 }, requires: [.fatigue]),
        FeltWord(name: "curious", minIntensity: 0.20, pick: { $0.read(.curiosity) >= 0.45 ? ($0.read(.curiosity) - 0.2) * 0.5 : 0 }, requires: [.curiosity]),
        FeltWord(name: "warm",    minIntensity: 0.20, pick: { ($0.warmth >= 0.5 && $0.valence >= 0) ? ($0.warmth - 0.3) * 0.4 : 0 }, contradicts: ["reserved","cold"]),
    ]

    // MARK: - Felt MODE (R2-E, 2026-07-09) — the aboutness under the words.
    // Panksepp-inspired categorical read (with Barrett's constructed-emotion caveat:
    // these are derived LABELS over dimensional state, not separate circuits). A pure
    // read for future waves + the Observatory — NOT a controller, NOT stored state,
    // and it never adds a capsule line. Nil when no mode is genuinely dominant.
    public enum FeltMode: String, Sendable {
        case seeking, care, play, repair, bracing, grief, frustration
    }

    /// Derive the dominant felt mode from the same signals the fingerprint reads.
    /// Ordering encodes precedence: the deep/urgent modes win over ambient ones.
    public static func feltMode(
        _ s: FeltSignals,
        intensityFloor: Double = defaultDynamics.feltIntensityFloor
    ) -> FeltMode? {
        guard feltIntensity(s) >= intensityFloor else { return nil }
        if s.valence <= -0.5, s.arousal <= 0.30 { return .grief }
        if s.valence < -0.15, s.arousal >= 0.45, s.pressure >= 0.4 { return .frustration }
        if s.tension >= 0.5, s.valence <= 0.05 { return .bracing }
        if s.pressure >= 0.5, s.valence < 0 { return .repair }
        if s.valence >= 0.2, s.arousal >= 0.5, s.warmth >= 0.5 { return .play }
        if s.warmth >= 0.65, s.arousal <= 0.40 { return .care }
        if s.read(.curiosity) >= 0.55, s.valence >= 0 { return .seeking }
        return nil
    }

    /// The live felt mode against a workspace the CALLER already snapshotted (U3,
    /// 2026-07-09 — the Observatory's mode chip). Read-only: no persistence, no
    /// mutation, no capsule text. Takes the workspace rather than re-snapshotting
    /// because `workspaceSnapshot()` advances field decay — an Observatory panel
    /// refreshing every 5s must never be the thing that ages her memory.
    ///
    /// nil when cognition/affect is off, or when no mode is genuinely dominant —
    /// the chip then shows nothing rather than inventing an aboutness.
    public func feltModeReading(
        for request: CognitiveCapsuleRequest,
        workspace: CognitiveWorkspaceSnapshot
    ) -> FeltMode? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        let capsuleItems = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        return Self.feltMode(
            feltSignalsForCapsule(from: capsuleItems, request: request),
            intensityFloor: dynamics.feltIntensityFloor)
    }

    /// Build the fingerprint: family from valence×arousal, best word inside it,
    /// plus up-to-two compatible overlays, honesty-gated by intensity.
    public static func feltFingerprint(
        _ s: FeltSignals,
        intensityFloor: Double = defaultDynamics.feltIntensityFloor
    ) -> String? {
        let intensity = feltIntensity(s)
        guard intensity >= intensityFloor else { return nil }   // faint → silent, like the body line

        var candidates: [(score: Double, word: FeltWord)] = []
        // W4/P2: a word whose identity depends on a dim we do not have is
        // EXCLUDED, not scored-to-zero. Same rule for overlays below.
        for w in feltFamilyWords[feltFamily(s)] ?? []
        where intensity >= w.minIntensity && w.requires.allSatisfy(s.isPresent) {
            let sc = w.pick(s)
            if sc > 0 { candidates.append((sc, w)) }
        }
        guard let lead = candidates.max(by: { $0.score < $1.score }) else { return nil }

        var picked: [FeltWord] = [lead.word]
        // overlays (foggy / clear-headed / worn / curious / warm) as modifiers
        let overlays = feltOverlays
            .filter { intensity >= $0.minIntensity && $0.requires.allSatisfy(s.isPresent) && $0.pick(s) > 0 }
            .sorted { $0.pick(s) > $1.pick(s) }
        for o in overlays where !picked.contains(where: { $0.name == o.name }) {
            if picked.count >= 3 { break }
            if picked.allSatisfy({ !$0.contradicts.contains(o.name) && !o.contradicts.contains($0.name) }) {
                picked.append(o)
            }
        }
        return picked.map(\.name).joined(separator: ", ")
    }
}
