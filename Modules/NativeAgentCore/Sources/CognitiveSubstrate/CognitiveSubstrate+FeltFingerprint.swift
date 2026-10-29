import Foundation

// Blueprint: | `CognitiveSubstrate+FeltFingerprint.swift` | `CognitiveSubstrate` felt fingerprint: graded live feeling words and capsule line composition |

// The felt fingerprint expresses the full live emotional range through a few felt words.
// Valence and arousal choose the family; other dimensions choose intensity-gated, noncontradictory words.
// Slow undertone and identity anchors remain separate from this fast reading.
extension CognitiveSubstrate {

    /// Optional dimensions remain unknown when neither the organism nor a substrate proxy supplies them.
    public enum FeltDim: String, Sendable, Hashable, CaseIterable {
        case fatigue, curiosity, clarity, agency, confidence
        /// Nightliness comes from the configured diurnal clock; without it, `late` is unavailable.
        case nightliness
    }

    /// Affect-science dimensions (valence −1..1; the rest clamped 0..1).
    /// Unknown dimensions are absent from intensity and disqualify words whose identity requires them.
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

        /// Scoring reads absent dimensions as zero; identity-dependent words require their presence.
        func read(_ dim: FeltDim) -> Double { value(dim) ?? 0 }

    }

    /// A candidate's score chooses within its family; intensity and contradiction gates keep blends honest.
    /// Required dimensions define the word's identity; optional modifiers may score as zero when absent.
    struct FeltWord {
        let name: String
        let minIntensity: Double
        let pick: @Sendable (FeltSignals) -> Double
        var contradicts: Set<String> = []
        var requires: Set<FeltDim> = []
    }

    // Fingerprint tint fades faster than mood; persona valence lift never cushions a sting.

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
        // Normalize over present dimensions only so unknown fatigue asserts neither tiredness nor its absence.
        var raw = 0.55 * abs(s.valence)
            + 0.35 * max(0, s.arousal - 0.30)
            + 0.35 * s.tension
            + 0.20 * s.pressure
            // Warmth above cool-neutral carries a gentle reading; a flat, cool state stays silent.
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
            // Pride requires confidence; delight marks the bright warm peak.
            FeltWord(name: "proud",    minIntensity: 0.50, pick: { $0.read(.confidence) >= 0.65 ? 0.3 + $0.read(.confidence) * 0.65 : 0 }, requires: [.confidence]),
            FeltWord(name: "delighted", minIntensity: 0.55, pick: { 0.15 + $0.warmth * 0.45 + $0.valence * 0.3 }),
        ],
        "pos_med": [
            FeltWord(name: "engaged",  minIntensity: 0.30, pick: { 0.5 + $0.read(.curiosity) * 0.4 }),
            FeltWord(name: "pleased",  minIntensity: 0.25, pick: { $0.valence * 0.7 }),
            FeltWord(name: "hopeful",  minIntensity: 0.30, pick: { 0.3 + $0.read(.confidence) * 0.3 + ($0.value(.clarity).map { (1 - $0) * 0.25 } ?? 0) }),
            // relieved = good feeling with the strain JUST gone (tension low NOW,
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
            // restless = energy with nowhere satisfying to put it (curiosity up,
            // clarity down) — the itch, not the focus.
            FeltWord(name: "restless", minIntensity: 0.24, pick: { ($0.read(.curiosity) >= 0.45 && $0.read(.clarity) <= 0.45) ? 0.45 + $0.arousal * 0.45 : 0 }, contradicts: ["focused","clear-headed"], requires: [.curiosity, .clarity]),
        ],
        "neu_low": [   // her warm-with-User resting state: quiet, but the warm overlay rides
                       // along ("quiet, warm"); "reserved"/"flat" only when genuinely cool.
            FeltWord(name: "quiet",    minIntensity: 0.14, pick: { _ in 0.5 }),
            FeltWord(name: "reserved", minIntensity: 0.20, pick: { $0.warmth <= 0.35 ? 0.6 : 0 }),
            FeltWord(name: "flat",     minIntensity: 0.22, pick: { 0.25 + $0.read(.fatigue) * 0.5 }, requires: [.fatigue]),
            // wistful = warm but carrying something — soft, backward-looking.
            FeltWord(name: "wistful",  minIntensity: 0.22, pick: { ($0.warmth >= 0.5 && $0.read(.fatigue) >= 0.3) ? 0.4 + $0.warmth * 0.35 : 0 }, contradicts: ["flat","reserved"], requires: [.fatigue]),
        ],
        "neg_high": [
            // Pressure-driven frustration takes precedence over tense, unpressured unease.
            FeltWord(name: "frustrated", minIntensity: 0.38, pick: { 0.38 + $0.pressure * 0.5 + $0.read(.agency) * 0.15 }, contradicts: ["calm","content","at ease"]),
            // The agency term is a HELPLESSNESS FLOOR, not upset's identity: upset is
            // about tension and hurt. With agency unknown (organism off) the floor
            // cannot fire, so it is skipped rather than failed — declaring
            // `requires: [.agency]` here would silently delete the whole
            // dismissal register from every default install.
            FeltWord(name: "upset",      minIntensity: 0.40, pick: { s in
                guard s.value(.agency).map({ $0 >= 0.40 }) ?? true else { return 0 }
                // Deep negative valence favors hurt; shallow-negative tension favors on edge.
                return 0.10 - s.valence * 0.6 + s.tension * 0.5 + s.read(.agency) * 0.1
            }, contradicts: ["calm","tender","content","at ease"]),
            FeltWord(name: "anxious",    minIntensity: 0.48, pick: { $0.read(.confidence) <= 0.45 ? 0.4 + $0.tension * 0.5 : 0 }, contradicts: ["calm","confident","at ease"], requires: [.confidence]),
            FeltWord(name: "on edge",    minIntensity: 0.38, pick: { 0.32 + $0.tension * 0.5 }, contradicts: ["calm","at ease"]),
            FeltWord(name: "agitated",   minIntensity: 0.55, pick: { 0.3 + $0.arousal * 0.4 }, contradicts: ["calm","content"]),
            // overwhelmed = the pressure ceiling — too much at once.
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
            // embarrassed = confidence knocked out with tension present — the
            // self-conscious wince, not fear (that's anxious) and not anger.
            FeltWord(name: "embarrassed", minIntensity: 0.32, pick: { ($0.read(.confidence) <= 0.22 && $0.tension >= 0.25) ? 0.85 - $0.read(.confidence) * 1.5 : 0 }, contradicts: ["confident","at ease"], requires: [.confidence]),
        ],
        "neg_low": [   // Fatigue uses the overlay; every family word needs a distinct dimensional reading.
            FeltWord(name: "discouraged", minIntensity: 0.40, pick: { $0.read(.agency) <= 0.4 ? 0.4 - $0.valence : 0 }, requires: [.agency]),
            FeltWord(name: "heavy",    minIntensity: 0.35, pick: { -$0.valence * 0.8 }),
            FeltWord(name: "deflated", minIntensity: 0.38, pick: { $0.read(.confidence) <= 0.35 ? 0.5 - $0.valence * 0.3 : 0 }, requires: [.confidence]),
            // Warmth distinguishes sad from heavy.
            FeltWord(name: "sad",      minIntensity: 0.35, pick: { $0.warmth >= 0.45 ? 0.1 - $0.valence * 0.8 : 0 }),
            // lonely = the COLD hollow: warmth gone, valence down, nothing moving.
            FeltWord(name: "lonely",   minIntensity: 0.35, pick: { $0.warmth <= 0.25 ? 0.55 - $0.warmth : 0 }, contradicts: ["warm","tender","grateful"]),
            // grieving = only when genuinely earned: deep negative valence, still body.
            // The high gate + pick threshold make melodrama structurally impossible.
            FeltWord(name: "grieving", minIntensity: 0.52, pick: { ($0.valence <= -0.55 && $0.arousal <= 0.30) ? -$0.valence : 0 }, contradicts: ["warm","content","playful","amused","curious","interested"]),
        ],
    ]

    /// Overlay bands yield to stronger words at their ceilings; low weight keeps overlays from leading.
    /// The `late` word gate is two-thirds of the way from the circadian peak to the trough.
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
        // Tired occupies the fatigue band below worn and excludes high-drive words.
        FeltWord(name: "tired",   minIntensity: 0.20, pick: { ($0.read(.fatigue) >= 0.24 && $0.read(.fatigue) < 0.55) ? 0.20 + $0.read(.fatigue) * 0.3 : 0 }, contradicts: ["eager","excited","driven","worn"], requires: [.fatigue]),
        // `late` is the ONE word that reads the clock, and it still refuses to
        // read it alone: deep night with no tiredness behind it is a timestamp,
        // not a feeling, so a real fatigue floor rides with the nightliness
        // gate. Absent the diurnal clock the word leaves the pool entirely
        // (`requires`), rather than being guessed from the wall time — the same
        // refusal `proud` and `anxious` make on an organism-less install.
        FeltWord(name: "late",    minIntensity: 0.16, pick: { ($0.read(.nightliness) >= feltLatenessFloor && $0.read(.fatigue) >= 0.12) ? 0.15 + $0.read(.nightliness) * 0.2 : 0 }, contradicts: ["alert"], requires: [.nightliness, .fatigue]),
    ]

    // MARK: - Felt mode
    // Modes are pure labels over dimensional state, never stored state, controllers or capsule lines.
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

    /// Read the felt mode from a frozen workspace without advancing state.
    /// nil when cognition/affect is off, or when no mode is genuinely dominant —
    /// the chip then shows nothing rather than inventing an aboutness.
    public func feltModeReading(
        for request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) -> FeltMode? {
        guard read.configuration.enabled else { return nil }
        let capsuleItems = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        return Self.feltMode(
            feltSignalsForCapsule(
                from: capsuleItems, request: request, frozenRead: read),
            intensityFloor: read.personalityDynamics.feltIntensityFloor)
    }

    /// The lead is always a family word; dimension overlays cannot displace it or own its object.
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
        // A word whose identity depends on a dim we do not have is
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

    // MARK: - Ambivalence

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
    /// Counter warmth is capped by the partner's mapped warmth so the word reflects what that subject earned.
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
            if best.map({ score > $0.score }) ?? true { best = (score, w.name) }
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
