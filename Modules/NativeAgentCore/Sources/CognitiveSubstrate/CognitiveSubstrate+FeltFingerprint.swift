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
        /// Item 4 (2026-09-02) — how far into the body's night it is, from the
        /// organism's diurnal clock. Optional for exactly the reason the other
        /// five are: an install with no configured clock does not know what
        /// time it feels like, and `late` must be unreachable there rather
        /// than guessed from a timestamp. (Agent #10: "I know it's 1 AM from a
        /// timestamp. A person at 1 AM *feels* 1 AM.")
        case nightliness
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
        public var nightliness: Double?

        public init(valence: Double, arousal: Double, warmth: Double, tension: Double, pressure: Double,
                    fatigue: Double? = nil, curiosity: Double? = nil, clarity: Double? = nil,
                    agency: Double? = nil, confidence: Double? = nil, nightliness: Double? = nil) {
            self.valence = valence; self.arousal = arousal; self.warmth = warmth; self.tension = tension
            self.pressure = pressure; self.fatigue = fatigue; self.curiosity = curiosity; self.clarity = clarity
            self.agency = agency; self.confidence = confidence; self.nightliness = nightliness
        }

        public func value(_ dim: FeltDim) -> Double? {
            switch dim {
            case .fatigue: return fatigue
            case .curiosity: return curiosity
            case .clarity: return clarity
            case .agency: return agency
            case .confidence: return confidence
            case .nightliness: return nightliness
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
            FeltWord(name: "grieving", minIntensity: 0.52, pick: { ($0.valence <= -0.55 && $0.arousal <= 0.30) ? -$0.valence : 0 }, contradicts: ["warm","content","playful","amused","curious","interested"]),
        ],
    ]

    /// Modifier overlays that can ride ANY family (clarity/warmth/curiosity read
    /// on top of the core feeling). Low weight so they never lead.
    ///
    /// THE BAND BOUNDARIES, RECALIBRATED 2026-09-01. Measured over 3,858 felt
    /// words in 15 days of live turns: `curious` appeared 973 times and
    /// `clear-headed` 932 — together ~50% of all the felt-word mass, riding
    /// roughly 70% of the lines, while the entire negative register
    /// (frustrated / upset / uneasy / worn / strained / sad) shared ~5%. The
    /// range EXISTS; two overlays were simply always on.
    ///
    /// Two causes, both fixed:
    ///   1. The chemistry that feeds them was pinned at the ceiling (curiosity
    ///      0.67, coherence 0.92) — see `OrganismChemistry`'s saturating raises
    ///      and per-signal settle.
    ///   2. The GATES sat below where those dims rest, so "over the gate" was
    ///      the normal condition rather than a notable one. Law 2: a trigger
    ///      that fires on ~100% of inputs is a floor, not a signal.
    ///
    /// The two strong words now name the TOP of their axes; the middle of each
    /// axis gets its own honest, CEILINGED word (`interested`, `collected`), so
    /// widening the vocabulary cannot re-create the same floor one notch down —
    /// when a dim saturates, the mid word goes silent and the strong word owns
    /// it, which is exactly the behavior a band should have.
    /// How far into the body's night `late` needs it to be. A word gate, so it
    /// lives here as a literal with every other word gate rather than in
    /// `PersonalityDynamicsConfiguration` — that type carries rates and
    /// cadences that are actually threaded, and a knob nothing reads is worse
    /// than a constant that says what it is. 0.66 is two-thirds of the way from
    /// the circadian peak to the trough.
    static let feltLatenessFloor = 0.66

    static let feltOverlays: [FeltWord] = [
        FeltWord(name: "foggy",   minIntensity: 0.20, pick: { $0.read(.clarity) <= 0.35 ? 0.6 - $0.read(.clarity) : 0 }, contradicts: ["clear-headed","collected","focused","alert"], requires: [.clarity]),
        FeltWord(name: "clear-headed", minIntensity: 0.18, pick: { $0.read(.clarity) >= 0.78 ? ($0.read(.clarity) - 0.4) * 0.6 : 0 }, contradicts: ["foggy","collected"], requires: [.clarity]),
        // Mid clarity, nothing pulling at her: composed rather than sharp. Its
        // floor is the SAME 0.55 the `focused` word already treats as "clear
        // enough to work", and its hard ceiling is the `clear-headed` gate, so
        // the two can never both be true and an exactly-neutral coherence (0.5,
        // the resting/unknown value) still says nothing at all.
        FeltWord(name: "collected", minIntensity: 0.18, pick: { ($0.read(.clarity) >= 0.55 && $0.read(.clarity) < 0.78 && $0.tension <= 0.35) ? 0.20 + $0.read(.clarity) * 0.15 : 0 }, contradicts: ["foggy","clear-headed"], requires: [.clarity]),
        FeltWord(name: "worn",    minIntensity: 0.22, pick: { $0.read(.fatigue) >= 0.55 ? ($0.read(.fatigue) - 0.3) * 0.5 : 0 }, requires: [.fatigue]),
        FeltWord(name: "curious", minIntensity: 0.20, pick: { $0.read(.curiosity) >= 0.60 ? ($0.read(.curiosity) - 0.2) * 0.5 : 0 }, contradicts: ["interested"], requires: [.curiosity]),
        // The weaker sibling of curious, ceilinged at its gate.
        FeltWord(name: "interested", minIntensity: 0.20, pick: { ($0.read(.curiosity) >= 0.35 && $0.read(.curiosity) < 0.60) ? 0.15 + $0.read(.curiosity) * 0.2 : 0 }, contradicts: ["curious","grieving"], requires: [.curiosity]),
        FeltWord(name: "warm",    minIntensity: 0.20, pick: { ($0.warmth >= 0.5 && $0.valence >= 0) ? ($0.warmth - 0.3) * 0.4 : 0 }, contradicts: ["reserved","cold"]),
        // Item 4 (2026-09-02) — THE BODY'S CLOCK REACHES THE WORDS.
        //
        // `tired` is the MID band of the tiredness axis whose top `worn`
        // already owns, built to the same rule the `curious`/`interested` and
        // `clear-headed`/`collected` pairs are built to: its floor is real
        // (0.24 — a stretch that has actually run), and its CEILING is the
        // `worn` gate, so the two can never both be true and widening the
        // vocabulary cannot re-create a floor one notch down. It contradicts
        // the three high-drive words because "tired and eager" on one reading
        // of one moment is a broken gauge, not a rich one.
        FeltWord(name: "tired",   minIntensity: 0.20, pick: { ($0.read(.fatigue) >= 0.24 && $0.read(.fatigue) < 0.55) ? 0.20 + $0.read(.fatigue) * 0.3 : 0 }, contradicts: ["eager","excited","driven","worn"], requires: [.fatigue]),
        // `late` is the ONE word that reads the clock, and it still refuses to
        // read it alone: deep night with no tiredness behind it is a timestamp,
        // not a feeling, so a real fatigue floor rides with the nightliness
        // gate. Absent the diurnal clock the word leaves the pool entirely
        // (`requires`), rather than being guessed from the wall time — the same
        // refusal `proud` and `anxious` make on an organism-less install.
        FeltWord(name: "late",    minIntensity: 0.16, pick: { ($0.read(.nightliness) >= feltLatenessFloor && $0.read(.fatigue) >= 0.12) ? 0.15 + $0.read(.nightliness) * 0.2 : 0 }, contradicts: ["alert"], requires: [.nightliness, .fatigue]),
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

    /// The fingerprint, DECOMPOSED. `feltFingerprint` is this joined with ", " —
    /// the split exists so the 2026-09-02 organs (object, ambivalence) can know
    /// which family the lead actually came from instead of re-deriving it from a
    /// rendered string, and so a test can assert on the lead rather than on a
    /// substring of the line.
    ///
    /// The LEAD is always a FAMILY word. Overlays are ranked and appended after
    /// the lead is already fixed and can never displace it, which is what makes
    /// "the object belongs to the lead's node" a safe statement: an overlay
    /// (`worn`, `curious`, `clear-headed`) is a read of a dim, not of a subject,
    /// and has no node to be about.
    public struct FeltFingerprintParts: Sendable, Equatable {
        public var family: String
        public var lead: String
        public var overlays: [String]

        public var words: [String] { [lead] + overlays }
        public var text: String { words.joined(separator: ", ") }
    }

    /// −1 / 0 / +1 — the valence DIRECTION the family encodes. Zero is the
    /// neutral band (`neu_*`): a state with no direction has nothing to be
    /// about, so it is one of the two diffuse cases the object omits on (the
    /// other being no contributing node at all).
    public static func feltFamilySign(_ family: String) -> Int {
        if family.hasPrefix("pos_") { return 1 }
        if family.hasPrefix("neg_") { return -1 }
        return 0
    }

    public static func feltFingerprintParts(
        _ s: FeltSignals,
        intensityFloor: Double = defaultDynamics.feltIntensityFloor
    ) -> FeltFingerprintParts? {
        let intensity = feltIntensity(s)
        guard intensity >= intensityFloor else { return nil }   // faint → silent, like the body line

        let family = feltFamily(s)
        var candidates: [(score: Double, word: FeltWord)] = []
        // W4/P2: a word whose identity depends on a dim we do not have is
        // EXCLUDED, not scored-to-zero. Same rule for overlays below.
        for w in feltFamilyWords[family] ?? []
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
        return FeltFingerprintParts(
            family: family,
            lead: lead.word.name,
            overlays: Array(picked.dropFirst()).map(\.name))
    }

    /// Build the fingerprint: family from valence×arousal, best word inside it,
    /// plus up-to-two compatible overlays, honesty-gated by intensity.
    public static func feltFingerprint(
        _ s: FeltSignals,
        intensityFloor: Double = defaultDynamics.feltIntensityFloor
    ) -> String? {
        feltFingerprintParts(s, intensityFloor: intensityFloor)?.text
    }

    // MARK: - AMBIVALENCE (Agent #2, 2026-09-02)

    /// The one CONTRADICTING second word the line is allowed to carry.
    ///
    /// This is a deliberate, narrow exception to the contradiction table, and
    /// the table is otherwise right: `calm, frustrated` on the same reading of
    /// the same moment is a broken gauge, not a rich inner life. What makes the
    /// exception honest is that the two words are readings of DIFFERENT
    /// SUBJECTS — two felt nodes, opposite sign, both over the floor, both
    /// recent, about different things. That is the shape of "fond and irritated
    /// at 1 AM", and it is the ONLY shape admitted: the caller proves the pair
    /// before it gets here (see `feltAmbivalencePartner`).
    ///
    /// The counter signals are the CURRENT signals with only valence/arousal
    /// swapped for the counter node's. Warmth, tension, pressure and the five
    /// optional dims are left alone on purpose — they are body-scale reads of
    /// now, not properties of a remembered moment, and substituting a node's
    /// raw warmth into a mapped warmth axis would put `tender` back on the
    /// wrong side of its gate.
    /// The counter signals' WARMTH is capped by the partner node's own warmth
    /// before this is called (see `feltPartnerWarmth`). Without that cap the
    /// underneath word inherited the CURRENT moment's global warmth, so `tender`
    /// — the highest warmth gate in the vocabulary — could be handed to her as a
    /// reading of a node that was never warm. The whole justification for the
    /// contradiction exception is that the second word is a real reading of a
    /// real other subject; a word the partner did not earn is exactly the kind
    /// of manufactured feeling this file exists to refuse.
    static func feltCounterWord(
        _ counter: FeltSignals,
        excluding taken: Set<String>,
        intensityFloor: Double
    ) -> String? {
        let intensity = feltIntensity(counter)
        guard intensity >= intensityFloor else { return nil }
        var best: (score: Double, name: String)?
        for w in feltFamilyWords[feltFamily(counter)] ?? []
        where intensity >= w.minIntensity && w.requires.allSatisfy(counter.isPresent) {
            guard !taken.contains(w.name) else { continue }
            let score = w.pick(counter)
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (score, w.name) }
        }
        return best?.name
    }

    /// The partner node's own warmth, on the SAME mapped scale the fingerprint's
    /// warmth axis uses — rest plus what the node actually earned. The
    /// uncertainty cooling term is deliberately absent: that is a property of
    /// the current moment, not of a remembered one, and leaving it out can only
    /// make the counter warmer, which is why the caller takes a `min` with the
    /// live axis rather than substituting this outright.
    static func feltPartnerWarmth(
        _ raw: Double,
        dynamics dyn: PersonalityDynamicsConfiguration
    ) -> Double {
        (dyn.feltWarmthRest + raw.clamped01() * dyn.feltWarmthEarnedSpan).clamped01()
    }

    // MARK: - The SAFE object extractor (privacy review, 2026-09-02)

    /// Words whose NEIGHBOURHOOD is a credential, an identity document, or a
    /// financial instrument. A hit drops the word itself and everything within
    /// `feltSecretContextRadius` tokens either side, because the thing being
    /// named is what must not be rendered: "rotate the anthropic deploy key"
    /// must not surface `anthropic deploy`.
    ///
    /// It also carries the words `TurnTraceRedactor` puts INTO text when it
    /// fires (`[REDACTED_GITHUB_TOKEN]` → github, token, redacted), so a
    /// already-redacted turn cannot re-leak the shape of what was redacted.
    ///
    /// An allowlist would be wrong here and a denylist is right, which is the
    /// reverse of design law 8 — deliberately. Law 8 governs whether a SIGNAL
    /// is admitted; this governs whether TEXT is emitted, and for text the
    /// conservative direction is to drop on suspicion. The cost of a false
    /// positive is no object on one turn. The cost of a false negative is the
    /// user's secret in the model's context.
    static let feltSecretContextWords: Set<String> = [
        "password", "passwd", "passphrase", "token", "tokens", "key", "keys",
        "apikey", "secret", "secrets", "credential", "credentials", "auth",
        "bearer", "oauth", "login", "signin", "ssn", "social", "security",
        "passport", "licence", "license", "card", "cards", "cvv", "cvc", "pin",
        "account", "accounts", "iban", "swift", "routing", "sortcode",
        "wallet", "mnemonic", "seedphrase", "private", "redacted",
        "github", "openai", "anthropic", "stripe", "slack", "google",
    ]
    static let feltSecretContextRadius = 2

    /// ROUTE words and SPEECH-ACT verbs — the two families that pass every
    /// safety filter and still make a terrible object.
    ///
    /// The route half is this codebase's own vocabulary: the label being
    /// replaced was literally "chat user", and every one of those tokens is a
    /// lowercase four-letter non-stopword that would sail through. `warm — chat
    /// user` is the exact bug the producer change exists to fix, so the reader
    /// refuses it too rather than trusting one seam.
    ///
    /// The verb half is the "prefer common nouns" half. A felt object is a
    /// THING she feels something about; "mention", "check", "look" are what was
    /// being done to it. Dropping them is what turns "don't mention Sarah
    /// Kensington" into no object at all instead of `about mention` — the name
    /// is already gone by rule 4, and this stops the leftover verb from
    /// standing in for it.
    static let feltWeakObjectWords: Set<String> = [
        // route
        "chat", "user", "users", "surface", "session", "message", "messages",
        "turn", "turns", "role", "agent", "assistant", "system", "tool",
        "tools", "bridge", "remote", "local", "desktop", "mobile",
        "telegram", "slack", "discord", "imessage", "email", "inbox",
        // speech acts and fillers
        "mention", "mentions", "mentioned", "tell", "tells", "told", "asks",
        "asked", "said", "says", "know", "knows", "think", "thinks", "want",
        "wants", "need", "needs", "look", "looks", "looking", "make", "makes",
        "made", "take", "takes", "give", "gives", "send", "sends", "keep",
        "keeps", "going", "gonna", "please", "thanks", "thank", "sure",
        "maybe", "right", "okay", "stuff", "something", "anything",
        // State-change verbs. Added with the phrase rule (2026-09-02): the
        // two-word form only earns its place when both words name the thing,
        // and "deploy broke" is a sentence about the deploy, not a name for it.
        // Dropping these is what leaves the leading NOUN standing alone.
        "broke", "broken", "breaks", "failed", "fails", "failing",
        "works", "worked", "working", "runs", "running", "landed",
        "lands", "shipped", "ships", "uses", "used", "using",
        "happened", "happens", "started", "starts", "stopped", "stops",
        // TIME UNITS AND COUNTING WORDS (live, 2026-09-02:
        // `amused, collected, curious — minutes`, from "eight minutes").
        // A duration is never what a feeling is ABOUT — it is how long the
        // thing took. These survive every other filter easily: they are
        // lowercase, four-plus letters, and genuinely salient in the sentence,
        // which is exactly why the object organ kept reaching for them.
        // A few overlap `summaryStopwords` on purpose: that list is shared with
        // Fluid Context's ranker and may legitimately change for reasons that
        // have nothing to do with what the felt line may name, so this rule
        // stands on its own.
        "minute", "minutes", "hour", "hours", "days", "week", "weeks",
        "weekend", "month", "months", "year", "years", "second", "seconds",
        "today", "tonight", "tomorrow", "yesterday", "morning", "afternoon",
        "evening", "night", "nights", "later", "again", "soon", "while",
        "moment", "moments", "time", "times", "ages",
        "first", "third", "fourth", "last", "next", "once", "twice", "half",
        "three", "four", "five", "seven", "eight", "nine",
        // NEGATIONS AND BARE ADVERBS. Same family of defect as the durations:
        // lowercase, four-plus letters, salient enough to rank, and never the
        // name of anything — `about never` and `about really` are the same
        // failure as `about minutes`. ("maybe", "something" and "anything" are
        // already above.)
        "never", "always", "really", "actually", "probably", "still",
        "already", "almost", "just", "only", "quite", "rather", "very",
        "enough", "instead", "anyway", "though", "whether", "either",
        "neither", "nothing", "everything",
    ]

    /// SAFE topical terms from free text, for anything the capsule RENDERS.
    ///
    /// `summaryKeywords` (the Fluid Context extractor) is the wrong tool for a
    /// rendered surface and the privacy review was right about it: it
    /// lowercases before tokenizing, so it cannot see case at all, and it will
    /// happily return `sarah`, `kensington`, `redacted`, or the word sitting
    /// next to "password". Those terms only ever went into a RANKER before;
    /// putting them on the felt line puts them in the model's context.
    ///
    /// The rules, in the order they run:
    ///   1. Bracketed runs are cut whole — that removes `[REDACTED_*]` markers
    ///      and the `[from: claude, via bridge]` routing prefix together.
    ///   2. Any token carrying `@`, `:` or `/` is cut WITH its neighbours —
    ///      emails, handles, URLs and `key: value` pairs.
    ///   3. A token containing a DIGIT is dropped (ids, amounts, dates, "8pm").
    ///   4. A token that is not entirely LOWERCASE in the source is dropped.
    ///   5. A secret-context word drops itself and its ±2 neighbours.
    ///   6. What is left goes through the same stopword / ≥4-letter /
    ///      opaque-id rules `summaryKeywords` already uses, plus
    ///      `feltWeakObjectWords` (routes and speech-act verbs).
    ///
    /// RULE 4 IS THE PRIVACY RULE and it is deliberately stricter than the
    /// review asked for (it wanted Title-case dropped except at sentence
    /// start, plus adjacent Title-case pairs always). Dropping EVERY
    /// non-lowercase token is simpler, strictly safer, and closes the hole the
    /// weaker rule leaves wide open: a message beginning "Sarah broke the
    /// deploy" has the name in sentence-initial position, where the weaker
    /// rule keeps it. It is also, in practice, the same thing as "prefer
    /// common nouns" — English proper nouns are capitalised and common nouns
    /// are not, and a sentence-initial capital almost always lands on a
    /// determiner, pronoun or verb that a stopword filter removes anyway.
    /// The cost is a topic lost when a sentence opens on its subject; the
    /// benefit is that no capitalised name can reach the prompt through here.
    ///
    /// Empty when nothing survives — and then there is no object, which is the
    /// honest outcome and the one every caller already handles.
    /// One safe token plus WHERE IT SAT in the source, so the phrase builder can
    /// ask the only question that separates a real phrase from word salad:
    /// were these two words actually next to each other?
    struct FeltSafeToken: Sendable, Equatable {
        var index: Int
        var word: String
    }

    /// The shared scan. Both the term list (used as a comparison key) and the
    /// rendered phrase come from this one walk, so there is no second copy of
    /// the privacy rules to drift.
    static func feltSafeTokenScan(in text: String) -> [FeltSafeToken] {
        guard !text.isEmpty else { return [] }

        // 1. Cut bracketed runs whole.
        var scrubbed = ""
        var depth = 0
        for character in text {
            if character == "[" || character == "(" || character == "<" {
                depth += 1
                scrubbed.append(" ")
            } else if character == "]" || character == ")" || character == ">" {
                depth = max(0, depth - 1)
                scrubbed.append(" ")
            } else if depth == 0 {
                scrubbed.append(character)
            }
        }

        // 2. Split into raw tokens on whitespace, so a token still carries the
        //    punctuation that identifies it as an address or a pair.
        let rawTokens = scrubbed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return [] }

        var dropped = Set<Int>()
        func dropNeighbourhood(_ index: Int, radius: Int) {
            for offset in -radius...radius {
                let neighbour = index + offset
                if neighbour >= 0, neighbour < rawTokens.count { dropped.insert(neighbour) }
            }
        }

        var words: [String] = []
        for (index, raw) in rawTokens.enumerated() {
            // Addresses, handles, URLs, `key: value` pairs — the token AND what
            // sits beside it, because the neighbour is usually the value.
            if raw.contains("@") || raw.contains("/") || raw.contains(":") || raw.contains("=") {
                dropNeighbourhood(index, radius: 1)
            }
            // Trim surrounding punctuation but keep the token's own letters.
            let word = raw.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted)
            words.append(word)
            if word.isEmpty { dropped.insert(index); continue }
            if word.contains(where: \.isNumber) { dropped.insert(index); continue }
            // RULE 4 — anything not entirely lowercase in the source.
            if word != word.lowercased() { dropped.insert(index); continue }
            if feltSecretContextWords.contains(word) {
                dropNeighbourhood(index, radius: feltSecretContextRadius)
            }
        }

        var out: [FeltSafeToken] = []
        for (index, word) in words.enumerated() {
            guard !dropped.contains(index) else { continue }
            guard word.count >= 4,
                  word.allSatisfy(\.isLetter),
                  !summaryStopwords.contains(word),
                  !feltWeakObjectWords.contains(word),
                  !isOpaqueIdentifier(word) else { continue }
            out.append(FeltSafeToken(index: index, word: word))
        }
        return out
    }

    /// The safe topical terms, deduped, in source order. This is the COMPARISON
    /// form — `feltAboutnessKey` normalizes with it — and is deliberately not
    /// what gets rendered; see `feltSafeObjectPhrase` for that.
    static func feltSafeObjectTerms(in text: String, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for token in feltSafeTokenScan(in: text) {
            guard seen.insert(token.word).inserted else { continue }
            out.append(token.word)
            if out.count >= limit { break }
        }
        return out
    }

    /// WHAT ACTUALLY GETS RENDERED: one term, or a real two-word phrase.
    ///
    /// THE LIVE DEFECT (2026-09-02): joining the first three safe terms with
    /// spaces produced `proud, collected, curious — readings pull fatigue`.
    /// Those three words were salient, safe, and scattered across a sentence —
    /// so the join read as salad, and an object that reads as salad is worse
    /// than no object at all. Salience was never the missing test; ADJACENCY
    /// was.
    ///
    /// The rule:
    ///   * take the run of consecutive safe tokens that CONTAINS THE FIRST one
    ///     — the leading subject, the same rationale the extractor's source
    ///     order already rests on;
    ///   * if that run is EXACTLY two tokens, render both ("tool audit",
    ///     "deploy pipeline") — a compound noun sits between function words,
    ///     so a 2-run bounded by dropped tokens is the shape of a real phrase;
    ///   * otherwise render the single leading term.
    ///
    /// A run of THREE OR MORE is the salad case and falls back to one word,
    /// which is exactly what `readings pull fatigue` is: three content words in
    /// a row is a clause, not a name. Never three, by construction rather than
    /// by a cap.
    static func feltSafeObjectPhrase(in text: String, maxCharacters: Int) -> String? {
        let tokens = feltSafeTokenScan(in: text)
        guard let first = tokens.first else { return nil }
        // How far the leading token's consecutive run extends.
        var last = 0
        while last + 1 < tokens.count, tokens[last + 1].index == tokens[last].index + 1 {
            last += 1
        }
        if last == 1, tokens[0].word != tokens[1].word {
            let pair = "\(tokens[0].word) \(tokens[1].word)"
            if pair.count <= maxCharacters { return pair }
        }
        return first.word.count <= maxCharacters ? first.word : nil
    }

    // MARK: - The topic label a conversation turn can honestly carry

    /// A payload-free TOPIC label for a chat turn, or nil when the turn has no
    /// safe salient term. This is what makes the felt line's object live on
    /// ordinary conversation instead of only on studio work.
    ///
    /// APPLIED AT THE PRODUCER. Both mint sites call this before the node is
    /// created, so the LABEL ITSELF is safe on disk and in every later read —
    /// not merely scrubbed on the way to the prompt. A render-time-only filter
    /// would leave a name sitting in `cognitive_nodes.subject_label` for
    /// anything else that ever reads it.
    ///
    /// Nil rather than a fallback when nothing is safe: silence is honest, and
    /// a turn with no safe topic gets no object.
    /// `maximumTerms` is retained for source compatibility and is CLAMPED TO
    /// TWO: the phrase rule, not a term budget, is what decides the shape now.
    /// A caller asking for three gets the same answer as a caller asking for
    /// two, because three space-joined salient words is the defect this
    /// replaced, not a longer version of the feature.
    public static func feltTopicLabel(
        from text: String,
        maximumTerms: Int = 2,
        maxCharacters: Int = 32
    ) -> String? {
        guard maximumTerms >= 1 else { return nil }
        guard maximumTerms >= 2 else {
            // A caller that explicitly wants one word gets one word.
            return feltSafeTokenScan(in: text).first
                .map(\.word)
                .flatMap { $0.count <= maxCharacters ? $0 : nil }
        }
        // Over-length is a REFUSAL, not a trim: truncating mid-word would
        // manufacture a fragment she would read as the name of a thing — the
        // same refusal `feltObjectLabel` makes.
        return feltSafeObjectPhrase(in: text, maxCharacters: maxCharacters)
    }

    // MARK: - Rendering the felt line

    /// The felt line as the model reads it: the words, then the OBJECT the lead
    /// is about, then the one contradicting word underneath.
    ///
    /// Order is load-bearing. The object binds to the LEAD (it is the lead's
    /// node's subject), so it sits directly after the words and before the
    /// second feeling — `on edge — about the deploy, and fond underneath`
    /// leaves `fond` honestly unattributed, which it must be: ambivalence fires
    /// precisely because the second feeling is about something ELSE, and the
    /// capsule has no room to name two subjects without becoming a paragraph.
    ///
    /// The connector differs by direction because English does: one is `on edge
    /// — about the deploy`, the other is `warm — User, earlier`. A negative
    /// feeling takes an "about"; a warm one simply names who or what.
    static func feltLineText(
        parts: FeltFingerprintParts,
        object: String?,
        second: String?
    ) -> String {
        var text = parts.text
        if let object, !object.isEmpty {
            text += feltFamilySign(parts.family) < 0 ? " — about \(object)" : " — \(object)"
        }
        if let second, !second.isEmpty {
            text += ", and \(second) underneath"
        }
        return text
    }
}
