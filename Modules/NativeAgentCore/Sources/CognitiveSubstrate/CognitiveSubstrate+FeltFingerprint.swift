import Foundation

// Blueprint: | `CognitiveSubstrate+FeltFingerprint.swift` | `CognitiveSubstrate` felt fingerprint: graded live feeling words and capsule line composition |

// Fast felt words share dimensional state; slow undertone and identity remain separate anchors.
extension CognitiveSubstrate {

    /// Optional body dimensions remain unknown without the organism's reading.
    public enum FeltDim: String, Sendable, Hashable, CaseIterable {
        case warmth, pressure, fatigue, curiosity, clarity, agency, confidence
        /// Nightliness comes from the configured diurnal clock; without it, `late` is unavailable.
        case nightliness
    }

    /// Affect-science dimensions (valence −1..1; the rest clamped 0..1). Unknown dimensions are absent from intensity and disqualify words whose identity
    /// requires them.
    public struct FeltSignals: Sendable {
        public var valence, arousal, tension: Double
        public var warmth, pressure: Double?
        public var fatigue: Double?
        public var curiosity: Double?
        public var clarity: Double?
        public var agency: Double?
        public var confidence: Double?
        public var nightliness: Double?

        public init(valence: Double, arousal: Double, warmth: Double?, tension: Double, pressure: Double?,
                    fatigue: Double? = nil, curiosity: Double? = nil, clarity: Double? = nil,
                    agency: Double? = nil, confidence: Double? = nil, nightliness: Double? = nil) {
            self.valence = valence; self.arousal = arousal; self.warmth = warmth; self.tension = tension
            self.pressure = pressure; self.fatigue = fatigue; self.curiosity = curiosity; self.clarity = clarity
            self.agency = agency; self.confidence = confidence; self.nightliness = nightliness
        }

        public func value(_ dim: FeltDim) -> Double? {
            switch dim {
            case .warmth: return warmth
            case .pressure: return pressure
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

    /// Required dimensions establish word identity; missing optional modifiers may score zero, but intensity and contradiction gates still apply.
    struct FeltWord {
        let name: String
        let minIntensity: Double
        let pick: @Sendable (FeltSignals) -> Double
        var contradicts: Set<String> = []
        var requires: Set<FeltDim> = []
    }

    // Fingerprint tint fades faster than mood; persona valence lift never cushions a sting.

    /// Hermite ramps keep mood/peak blending and persona bias continuous at thresholds.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = ((x - edge0) / (edge1 - edge0)).clamped01()
        return t * t * (3 - 2 * t)
    }

    /// Intensity gates strong words so faint states stay quiet.
    static func feltIntensity(_ s: FeltSignals) -> Double {
        // Use absolute valence and energy above rest so strong feelings of either sign register; normalize only present dimensions.
        var raw = 0.55 * abs(s.valence)
            + 0.35 * max(0, s.arousal - 0.30)
            + 0.35 * s.tension
        let alwaysPresentWeight = 0.55 + 0.35 + 0.35
        var presentWeight = alwaysPresentWeight
        if let pressure = s.pressure {
            raw += 0.20 * pressure
            presentWeight += 0.20
        }
        if let warmth = s.warmth {
            raw += 0.42 * max(0, warmth - 0.28)
            presentWeight += 0.42
        }
        if let fatigue = s.fatigue {
            raw += 0.20 * fatigue
            presentWeight += 0.20
        }
        let totalWeight = alwaysPresentWeight + 0.20 + 0.42 + 0.20
        // Scale the present terms up to what the full-weight sum would have spanned. With every dim present this multiplies by exactly 1.
        let normalized = presentWeight > 0 ? raw * (totalWeight / presentWeight) : raw
        return (normalized).clamped01()
    }

    private static func band(_ v: Double, hi: Double, lo: Double) -> Int { v >= hi ? 1 : (v <= lo ? -1 : 0) }

    /// Choose family before words so vocabulary cannot choose the valence/arousal band.
    static func feltFamily(_ s: FeltSignals) -> String {
        let vb = band(s.valence, hi: 0.22, lo: -0.20)
        let ab = s.arousal >= 0.52 ? 1 : (s.arousal <= 0.28 ? -1 : 0)
        let v = vb == 1 ? "pos" : (vb == -1 ? "neg" : "neu")
        let a = ab == 1 ? "high" : (ab == -1 ? "low" : "med")
        return "\(v)_\(a)"
    }

    // Rank only within the chosen family so a strong modifier cannot change emotional direction.
    static let feltFamilyWords: [String: [FeltWord]] = [
        "pos_high": [
            FeltWord(name: "excited",  minIntensity: 0.45, pick: { 0.6 + $0.read(.curiosity) * 0.4 }),
            FeltWord(name: "elated",   minIntensity: 0.78, pick: { $0.valence * 0.9 }),
            FeltWord(name: "playful",  minIntensity: 0.40, pick: { $0.read(.warmth) * 0.75 }, requires: [.warmth]),
            FeltWord(name: "eager",    minIntensity: 0.40, pick: { 0.4 + $0.read(.agency) * 0.5 }),
            // Pride requires confidence; delight marks the bright warm peak.
            FeltWord(
                name: "proud",
                minIntensity: 0.50,
                pick: { $0.read(.confidence) >= 0.65 ? 0.3 + $0.read(.confidence) * 0.65 : 0 },
                requires: [.confidence]
            ),
            FeltWord(name: "delighted", minIntensity: 0.55, pick: { 0.15 + $0.read(.warmth) * 0.45 + $0.valence * 0.3 }, requires: [.warmth]),
        ],
        "pos_med": [
            FeltWord(name: "engaged",  minIntensity: 0.30, pick: { 0.5 + $0.read(.curiosity) * 0.4 }),
            FeltWord(name: "pleased",  minIntensity: 0.25, pick: { $0.valence * 0.7 }),
            FeltWord(name: "hopeful",  minIntensity: 0.30, pick: { 0.3 + $0.read(.confidence) * 0.3 + ($0.value(.clarity).map { (1 - $0) * 0.25 } ?? 0) }),
            // Relief requires low current strain with carried fatigue; gratitude is warmth-led and amusement is light play.
            FeltWord(
                name: "relieved",
                minIntensity: 0.28,
                pick: { ($0.tension <= 0.20 && $0.read(.fatigue) >= 0.40) ? 0.5 + (1 - $0.tension) * 0.25 : 0 },
                requires: [.fatigue]
            ),
            FeltWord(name: "grateful", minIntensity: 0.30, pick: { $0.read(.warmth) >= 0.62 ? 0.25 + $0.read(.warmth) * 0.4 : 0 }, requires: [.warmth]),
            FeltWord(
                name: "amused",
                minIntensity: 0.26,
                pick: { ($0.read(.curiosity) >= 0.50 && $0.read(.warmth) >= 0.70 && $0.tension <= 0.15)
                    ? 0.4 + $0.read(.curiosity) * 0.4 + $0.read(.warmth) * 0.25
                    : 0
                },
                requires: [.warmth,.curiosity]
            ),
        ],
        "pos_low": [   // Quiet warmth needs a low intensity gate to remain speakable; tender requires earned depth.
            FeltWord(name: "tender",   minIntensity: 0.28, pick: { $0.read(.warmth) >= 0.7 ? 0.9 : 0 }, requires: [.warmth]),
            FeltWord(name: "warm",     minIntensity: 0.15, pick: { $0.read(.warmth) >= 0.45 ? 0.6 + $0.read(.warmth) * 0.3 : 0 }, requires: [.warmth]),
            FeltWord(name: "content",  minIntensity: 0.15, pick: { 0.5 + $0.read(.confidence) * 0.3 }),
            FeltWord(name: "at ease",  minIntensity: 0.14, pick: { 0.4 + (1 - $0.tension) * 0.3 }),
        ],
        "neu_high": [
            FeltWord(
                name: "driven",
                minIntensity: 0.40,
                pick: { 0.25 + $0.read(.pressure) * 0.4 + $0.arousal * 0.25 + $0.read(.agency) * 0.15 },
                requires: [.pressure]
            ),
            FeltWord(name: "serious",  minIntensity: 0.35, pick: { 0.4 + $0.read(.pressure) * 0.4 }, requires: [.pressure]),
            FeltWord(name: "focused",  minIntensity: 0.30, pick: { $0.read(.clarity) >= 0.55 ? 0.5 + $0.read(.clarity) * 0.3 : 0 }, requires: [.clarity]),
            FeltWord(name: "alert",    minIntensity: 0.30, pick: { 0.3 + $0.tension * 0.4 }),
        ],
        "neu_med": [
            FeltWord(name: "steady",   minIntensity: 0.20, pick: { 0.4 + $0.read(.confidence) * 0.3 }),
            FeltWord(name: "heads-down", minIntensity: 0.28, pick: { 0.3 + $0.read(.pressure) * 0.5 }, requires: [.pressure]),
            FeltWord(name: "quiet",    minIntensity: 0.15, pick: { _ in 0.4 }),
            // Restlessness combines energy and curiosity without clarity, distinguishing itch from focus.
            FeltWord(
                name: "restless",
                minIntensity: 0.24,
                pick: { ($0.read(.curiosity) >= 0.45 && $0.read(.clarity) <= 0.45) ? 0.45 + $0.arousal * 0.45 : 0 },
                contradicts: ["focused","clear-headed"],
                requires: [.curiosity, .clarity]
            ),
        ],
        "neu_low": [   // Warm resting states keep the warm overlay; reserved or flat require genuinely cool feeling.
            FeltWord(name: "quiet",    minIntensity: 0.14, pick: { _ in 0.5 }),
            FeltWord(name: "reserved", minIntensity: 0.20, pick: { $0.read(.warmth) <= 0.35 ? 0.6 : 0 }, requires: [.warmth]),
            FeltWord(name: "flat",     minIntensity: 0.22, pick: { 0.25 + $0.read(.fatigue) * 0.5 }, requires: [.fatigue]),
            // Warmth with carried fatigue distinguishes wistfulness.
            FeltWord(
                name: "wistful",
                minIntensity: 0.22,
                pick: { ($0.read(.warmth) >= 0.5 && $0.read(.fatigue) >= 0.3) ? 0.4 + $0.read(.warmth) * 0.35 : 0 },
                contradicts: ["flat","reserved"],
                requires: [.warmth,.fatigue]
            ),
        ],
        "neg_high": [
            // Pressure-driven frustration takes precedence over tense, unpressured unease.
            FeltWord(
                name: "frustrated",
                minIntensity: 0.38,
                pick: { 0.38 + $0.read(.pressure) * 0.5 + $0.read(.agency) * 0.15 },
                contradicts: ["calm", "content","at ease"],
                requires: [.pressure]
            ),
            // Unknown agency cannot trigger the helplessness floor, but tension and hurt still identify upset.
            FeltWord(name: "upset",      minIntensity: 0.40, pick: { s in
                guard s.value(.agency).map({ $0 >= 0.40 }) ?? true else { return 0 }
                // Deep negative valence favors hurt; shallow-negative tension favors on edge.
                return 0.10 - s.valence * 0.6 + s.tension * 0.5 + s.read(.agency) * 0.1
            }, contradicts: ["calm","tender","content","at ease"]),
            FeltWord(
                name: "anxious",
                minIntensity: 0.48,
                pick: { $0.read(.confidence) <= 0.45 ? 0.4 + $0.tension * 0.5 : 0 },
                contradicts: ["calm", "confident","at ease"],
                requires: [.confidence]
            ),
            FeltWord(name: "on edge",    minIntensity: 0.38, pick: { 0.32 + $0.tension * 0.5 }, contradicts: ["calm","at ease"]),
            FeltWord(name: "agitated",   minIntensity: 0.55, pick: { 0.3 + $0.arousal * 0.4 }, contradicts: ["calm","content"]),
            // Pressure identifies overwhelm; absent agency skips its co-guard without excluding the word.
            FeltWord(
                name: "overwhelmed",
                minIntensity: 0.50,
                pick: { s in
                    guard s.read(.pressure) >= 0.68, s.value(.agency).map({ $0 <= 0.5 }) ?? true else { return 0 }
                    return 0.45 + s.read(.pressure) * 0.5
                },
                contradicts: ["calm","at ease","content","steady"],
                requires: [.pressure]
            ),
        ],
        "neg_med": [
            FeltWord(name: "uneasy",   minIntensity: 0.28, pick: { 0.3 + $0.tension * 0.4 }),
            FeltWord(name: "annoyed",  minIntensity: 0.30, pick: { 0.3 + $0.read(.pressure) * 0.3 }, requires: [.pressure]),
            FeltWord(name: "strained", minIntensity: 0.35, pick: { 0.3 + $0.read(.pressure) * 0.4 + $0.read(.fatigue) * 0.2 }, requires: [.pressure]),
            // Embarrassment requires lost confidence with tension, distinguishing it from fear or anger.
            FeltWord(
                name: "embarrassed",
                minIntensity: 0.32,
                pick: { ($0.read(.confidence) <= 0.22 && $0.tension >= 0.25) ? 0.85 - $0.read(.confidence) * 1.5 : 0 },
                contradicts: ["confident","at ease"],
                requires: [.confidence]
            ),
        ],
        "neg_low": [   // Fatigue uses the overlay; every family word needs a distinct dimensional reading.
            FeltWord(name: "discouraged", minIntensity: 0.40, pick: { $0.read(.agency) <= 0.4 ? 0.4 - $0.valence : 0 }, requires: [.agency]),
            FeltWord(name: "heavy",    minIntensity: 0.35, pick: { -$0.valence * 0.8 }),
            FeltWord(name: "deflated", minIntensity: 0.38, pick: { $0.read(.confidence) <= 0.35 ? 0.5 - $0.valence * 0.3 : 0 }, requires: [.confidence]),
            // Warmth distinguishes sad from heavy.
            FeltWord(name: "sad",      minIntensity: 0.35, pick: { $0.read(.warmth) >= 0.45 ? 0.1 - $0.valence * 0.8 : 0 }, requires: [.warmth]),
            // Loneliness requires low warmth and valence without drive.
            FeltWord(
                name: "lonely",
                minIntensity: 0.35,
                pick: { $0.read(.warmth) <= 0.25 ? 0.55 - $0.read(.warmth) : 0 },
                contradicts: ["warm","tender", "grateful"],
                requires: [.warmth]
            ),
            // Deep negative valence, stillness and the high pick gate reserve grief for a strong reading.
            FeltWord(
                name: "grieving",
                minIntensity: 0.52,
                pick: { ($0.valence <= -0.55 && $0.arousal <= 0.30) ? -$0.valence : 0 },
                contradicts: ["warm", "content","playful","amused","curious","interested"]
            ),
        ],
    ]

    /// Overlay bands yield to stronger words at their ceilings; low weight keeps overlays from leading. The `late` word gate is two-thirds of the way from the
    /// circadian peak to the trough.
    static let feltLatenessFloor = 0.66

    static let feltOverlays: [FeltWord] = [
        FeltWord(
            name: "foggy",
            minIntensity: 0.20,
            pick: { $0.read(.clarity) <= 0.35 ? 0.6 - $0.read(.clarity) : 0 },
            contradicts: ["clear-headed", "collected","focused","alert"],
            requires: [.clarity]
        ),
        FeltWord(
            name: "clear-headed",
            minIntensity: 0.18,
            pick: { $0.read(.clarity) >= 0.78 ? ($0.read(.clarity) - 0.4) * 0.6 : 0 },
            contradicts: ["foggy", "collected"],
            requires: [.clarity]
        ),
        // Composed spans focused's 0.55 clarity floor up to the clear-headed gate; neutral 0.5 coherence stays silent.
        FeltWord(
            name: "collected",
            minIntensity: 0.18,
            pick: { ($0.read(.clarity) >= 0.55 && $0.read(.clarity) < 0.78 && $0.tension <= 0.35) ? 0.20 + $0.read( .clarity) * 0.15 : 0 },
            contradicts: ["foggy","clear-headed"],
            requires: [.clarity]
        ),
        FeltWord(name: "worn",    minIntensity: 0.22, pick: { $0.read(.fatigue) >= 0.55 ? ($0.read(.fatigue) - 0.3) * 0.5 : 0 }, requires: [.fatigue]),
        FeltWord(
            name: "curious",
            minIntensity: 0.20,
            pick: { $0.read(.curiosity) >= 0.60 ? ($0.read(.curiosity) - 0.2) * 0.5 : 0 },
            contradicts: ["interested"],
            requires: [.curiosity]
        ),
        // The weaker sibling of curious, ceilinged at its gate.
        FeltWord(
            name: "interested",
            minIntensity: 0.20,
            pick: { ($0.read(.curiosity) >= 0.35 && $0.read(.curiosity) < 0.60) ? 0.15 + $0.read(.curiosity) * 0.2 : 0 },
            contradicts: ["curious","grieving"],
            requires: [.curiosity]
        ),
        FeltWord(
            name: "warm",
            minIntensity: 0.20,
            pick: { ($0.read(.warmth) >= 0.5 && $0.valence >= 0) ? ($0.read(.warmth) - 0.3) * 0.4 : 0 },
            contradicts: ["reserved","cold"],
            requires: [.warmth]
        ),
        // Tired occupies the fatigue band below worn and excludes high-drive words.
        FeltWord(
            name: "tired",
            minIntensity: 0.20,
            pick: { ($0.read(.fatigue) >= 0.24 && $0.read(.fatigue) < 0.55) ? 0.20 + $0.read(.fatigue) * 0.3 : 0 },
            contradicts: ["eager","excited","driven","worn"],
            requires: [.fatigue]
        ),
        // Late requires both configured nightliness and fatigue; a clock alone is not a feeling and no clock leaves the word unavailable.
        FeltWord(
            name: "late",
            minIntensity: 0.16,
            pick: { ($0.read(.nightliness) >= feltLatenessFloor && $0.read(.fatigue) >= 0.12) ? 0.15 + $0.read( .nightliness) * 0.2 : 0 },
            contradicts: ["alert"],
            requires: [.nightliness, .fatigue]
        ),
    ]

    // MARK: - Felt mode
    // Modes are pure labels over dimensional state, never stored state, controllers or capsule lines.
    public enum FeltMode: String, Sendable {
        case seeking, care, play, repair, bracing, grief, frustration
    }

    /// Derive the dominant felt mode from the same signals the fingerprint reads. Ordering encodes precedence: the deep/urgent modes win over ambient ones.
    public static func feltMode(
        _ s: FeltSignals,
        intensityFloor: Double = defaultDynamics.feltIntensityFloor
    ) -> FeltMode? {
        guard feltIntensity(s) >= intensityFloor else { return nil }
        if s.valence <= -0.5, s.arousal <= 0.30 { return .grief }
        if s.valence < -0.15, s.arousal >= 0.45, s.read(.pressure) >= 0.4 { return .frustration }
        if s.tension >= 0.5, s.valence <= 0.05 { return .bracing }
        if s.read(.pressure) >= 0.5, s.valence < 0 { return .repair }
        if s.valence >= 0.2, s.arousal >= 0.5, s.read(.warmth) >= 0.5 { return .play }
        if s.read(.warmth) >= 0.65, s.arousal <= 0.40 { return .care }
        if s.read(.curiosity) >= 0.55, s.valence >= 0 { return .seeking }
        return nil
    }

    /// Read the felt mode from a frozen workspace without advancing state. nil when cognition/affect is off, or when no mode is genuinely dominant — the chip
    /// then shows nothing rather than inventing an aboutness.
    public func feltModeReading(
        for request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) -> FeltMode? {
        guard read.configuration.enabled else { return nil }
        let capsuleItems = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        guard let signals = feltSignalsForCapsule(from: capsuleItems, request: request, frozenRead: read) else { return nil }
        return Self.feltMode(
            signals,
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

    /// A neutral family has no directional aboutness, so it omits an object just as an absent contributor does.
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
        guard intensity >= intensityFloor else { return nil }   // Faint states remain silent.

        let family = feltFamily(s)
        var candidates: [(score: Double, word: FeltWord)] = []
        // A word whose identity depends on a dim we do not have is EXCLUDED, not scored-to-zero. Same rule for overlays below.
        for w in feltFamilyWords[family] ?? []
        where intensity >= w.minIntensity && w.requires.allSatisfy(s.isPresent) {
            let sc = w.pick(s)
            if sc > 0 { candidates.append((sc, w)) }
        }
        guard let lead = candidates.max(by: { $0.score < $1.score }) else { return nil }

        var picked: [FeltWord] = [lead.word]
        // Overlays may modify, never replace, the family word.
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

    /// Only proven opposite-sign, recent nodes about different subjects may contradict. Substitute counter valence/arousal only; current body axes remain
    /// shared and partner warmth caps the counter.
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

    /// Map partner warmth to the fingerprint scale without current uncertainty, then cap with the live axis so remembered warmth cannot override cooling.
    static func feltPartnerWarmth(
        _ raw: Double,
        dynamics dyn: PersonalityDynamicsConfiguration
    ) -> Double? {
        guard let span = dyn.feltWarmthEarnedSpan else { return nil }
        return (dyn.feltWarmthRest + raw.clamped01() * span).clamped01()
    }

    // MARK: - Rendering the felt line

    /// Bind the lead's object before the counter word so ambivalence cannot misattribute it; negative leads use "about", warm leads name the subject directly.
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
