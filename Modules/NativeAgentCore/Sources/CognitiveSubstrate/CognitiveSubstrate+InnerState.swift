// CognitiveSubstrate+InnerState.swift
// Introspection pulls a bounded, pure projection of existing records without changing state or injecting context.
// Felt readings expose labels and signals, never summaries or subject IDs; free text is limited to her care and stance.

import Foundation
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+InnerState.swift` | `CognitiveSubstrate.innerStateReading`: record-backed mind/body introspection, selection reasons and felt/care/toward projections |

// MARK: - The reading

/// One bounded, payload-free projection of what her organs are currently
/// holding. Every list is capped at CONSTRUCTION, so no producer can flood a
/// reader and no future source can quietly widen the surface.
public struct CognitiveInnerStateReading: Sendable, Equatable {

    /// How much to say. `compact` is the answer to "how are you"; `full` is the
    /// answer to "no — honestly, what's actually going on in there".
    public enum Detail: String, Sendable, Equatable, CaseIterable {
        case compact
        case full
    }

    /// A felt moment, named by its SUBJECT and its numbers. Never by what was
    /// said in it.
    public struct FeltNode: Sendable, Equatable {
        /// Moments identify whether intensity or recency selected them, keeping quiet recent work visible.
        public enum Selection: String, Sendable, Equatable {
            case felt
            case recent
        }

        public let when: Date
        /// `subjectReference.label` when the subject has one, else its `type`.
        /// Bounded to 32 characters. Never the node summary, never the id.
        public let subject: String
        public let valence: Double
        public let arousal: Double
        public let warmth: Double
        public let selection: Selection

        public init(when: Date, subject: String, valence: Double, arousal: Double,
                    warmth: Double, selection: Selection = .felt) {
            self.selection = selection
            self.when = when
            self.subject = String(subject.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
            self.valence = valence.clampedSigned()
            self.arousal = arousal.clamped01()
            self.warmth = warmth.clamped01()
        }
    }

    /// Something she is still waiting to find out. Label, when it comes due, and
    /// the SIGN of the affect attached — not the affect's magnitude and not what
    /// the expectation was about.
    public struct Expectation: Sendable, Equatable {
        public let label: String
        public let due: Date
        /// +1 looking forward, −1 bracing. Never 0 — an expectation with no lean
        /// is not an expectation she is carrying.
        public let valenceSign: Int

        public init(label: String, due: Date, valenceSign: Int) {
            self.label = String(label.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
            self.due = due
            self.valenceSign = valenceSign >= 0 ? 1 : -1
        }
    }

    /// What the night left. A mood word and a date. The dream's text is not here
    /// and must never be — she reads her dreams by choosing to, not by asking
    /// how she feels.
    public struct DreamResidue: Sendable, Equatable {
        public let moodWord: String
        public let date: String

        public init(moodWord: String, date: String) {
            self.moodWord = moodWord
            self.date = date
        }
    }

    /// The nearest thing she is facing. Payload-free by construction — the
    /// horizon register already publishes only a label, a source kind, a
    /// valence SIGN and a due date, because the capsule picks the word and
    /// never renders a number.
    public struct Toward: Sendable, Equatable {
        public let label: String
        public let sourceKind: String
        /// −1 dreading · +1 looking forward.
        public let valenceSign: Int
        public let due: Date
        /// The horizon passed and nothing answered it — `waiting`.
        public let isOverdue: Bool

        public init(
            label: String, sourceKind: String, valenceSign: Int, due: Date, isOverdue: Bool
        ) {
            self.label = String(label.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
            self.sourceKind = sourceKind
            self.valenceSign = valenceSign >= 0 ? 1 : -1
            self.due = due
            self.isOverdue = isOverdue
        }
    }

    /// What she cares about, as her own words and its charge right now.
    public struct Care: Sendable, Equatable {
        public let id: UUID
        public let about: String
        public let depth: String
        public let with: [String]
        /// The newest felt word in its story.
        public let felt: String?
        public let charge: Double
        public let open: String?
        public let stance: String?
        public let because: String?
        public let wouldChangeMind: String?

        public init(id: UUID, about: String, depth: String, with: [String], felt: String?,
                    charge: Double, open: String?, stance: String?, because: String? = nil,
                    wouldChangeMind: String? = nil) {
            self.id = id
            self.about = about
            self.depth = depth
            self.with = with
            self.felt = felt
            self.charge = charge.isFinite ? charge : 0
            self.open = open
            self.stance = stance
            self.because = because
            self.wouldChangeMind = wouldChangeMind
        }
    }

    // MARK: Bounds (design law 6 — everything is bounded)

    public static let subjectLabelCharacters = 32
    public static let maximumFeltNodes = 12
    /// The split inside that cap: the week's loudest, then the newest of what
    /// is left. `recentFeltNodes` is what guarantees a quiet day is visible.
    public static let strongestFeltNodes = 8
    public static let recentFeltNodes = 4
    public static let maximumExpectations = 5
    /// Compact shows the most charged few; full shows every live care.
    public static let compactCares = 8
    /// Bounded like everything else. A week she can read in one breath.
    public static let maximumGrowthWeekLines = 12
    /// Compact is not a different report — it is the same report, shorter.
    public static let compactFeltNodes = 4
    public static let compactListItems = 2

    /// Trim to `cap` while keeping both halves represented, in the builder's
    /// order (strongest, then newest). The recent share scales with the cap, so
    /// compact is the same report shorter rather than a different one.
    ///
    /// The share is a QUOTA, not a ceiling: capacity a skewed pool cannot fill
    /// is handed back to the other pool, so the cap is reached whenever the two
    /// pools together hold enough. Taking the quotas literally underfilled a
    /// skewed week — one felt node beside twelve recent ones returned five of
    /// twelve, and the quiet days it was meant to protect went missing.
    static func trimmedFelt(_ nodes: [FeltNode], cap: Int) -> [FeltNode] {
        guard cap > 0 else { return [] }
        guard nodes.count > cap else { return nodes }
        let strongPool = nodes.filter { $0.selection == .felt }
        let recentPool = nodes.filter { $0.selection == .recent }
        let recentShare = max(1, cap * recentFeltNodes / maximumFeltNodes)
        var recentTake = min(recentPool.count, recentShare)
        // Backfill the unused remainder: strongest first, then newest.
        let strongTake = min(strongPool.count, cap - recentTake)
        recentTake = min(recentPool.count, cap - strongTake)
        return Array(strongPool.prefix(strongTake)) + Array(recentPool.prefix(recentTake))
    }

    public static let minimumWindowHours: Double = 1
    /// A week widens the felt-node scan; `maximumFeltNodes` still bounds the answer.
    public static let maximumWindowHours: Double = 168
    public static let defaultWindowHours: Double = 6

    /// HOW CLOSE AN ECHO HAS TO BE TO BE AN ECHO. Half an hour: long enough to
    /// cover a message and the reply to it (the nine-second "stall" pair), and
    /// far short of the gap between two separate sittings. Beyond it, the same
    /// subject is the same subject felt AGAIN, which is a second moment and not
    /// a duplicate row.
    public static let feltEchoInterval: TimeInterval = 30 * 60

    // MARK: Fields

    public let generatedAt: Date
    /// The window actually used, after clamping to 1…48.
    public let windowHours: Double
    public let detail: Detail
    /// False when cognition or affect is switched off. Everything below is then
    /// honestly empty rather than zero-shaped: absence reads as absence.
    public let available: Bool

    /// The felt fingerprint as the capsule would render it right now, or nil
    /// below the intensity floor. Silence is honest (design law 4).
    public let fingerprint: String?
    /// What the fingerprint is ABOUT — the subject label of the felt node
    /// currently leading the workspace. nil when nothing in particular leads it.
    public let fingerprintSubject: String?

    public let moodValence: Double
    public let moodBasis: Int
    /// The capsule's own mood-band vocabulary, as one word.
    public let moodWord: String
    public let dispositionValence: Double
    public let dispositionWord: String

    public let feltNodes: [FeltNode]

    /// Organism chemistry in the EXISTING `- Body:` vocabulary, split into its
    /// phrases. Empty when the body is neutral or off — no invented words.
    public let chemistryWords: [String]

    // Optional organism reads. Other lanes in this wave (fatigue and the
    // diurnal clock and `toward`) land separately; this reading
    // CONSUMES them when the caller has them and reports their absence
    // honestly when it does not. It never blocks on them.
    public let fatigue: Double?
    public let timeOfDayPhase: String?

    public let expectations: [Expectation]
    /// The nearest open horizon, or nil when she is facing nothing — which
    /// renders as silence, not as a flat word.
    public let toward: Toward?
    public let dream: DreamResidue?
    /// Full readings expose the growth surface's same week only when requested.
    public let growthWeek: [String]
    /// Live cares, most charged first.
    public let cares: [Care]
    /// `full` only: her depth changes and what her nights settled or let go,
    /// newest first, one plain line each.
    public let story: [String]

    public init(
        generatedAt: Date,
        windowHours: Double,
        detail: Detail,
        available: Bool,
        fingerprint: String? = nil,
        fingerprintSubject: String? = nil,
        moodValence: Double = 0,
        moodBasis: Int = 0,
        moodWord: String = "even",
        dispositionValence: Double = 0,
        dispositionWord: String = "even",
        feltNodes: [FeltNode] = [],
        chemistryWords: [String] = [],
        fatigue: Double? = nil,
        timeOfDayPhase: String? = nil,
        expectations: [Expectation] = [],
        toward: Toward? = nil,
        dream: DreamResidue? = nil,
        growthWeek: [String] = [],
        cares: [Care] = [],
        story: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.windowHours = min(
            Self.maximumWindowHours, max(Self.minimumWindowHours, windowHours))
        self.detail = detail
        self.available = available
        self.fingerprint = fingerprint
        self.fingerprintSubject = fingerprintSubject.map {
            String($0.prefix(Self.subjectLabelCharacters))
        }
        self.moodValence = moodValence.clampedSigned()
        self.moodBasis = max(0, moodBasis)
        self.moodWord = moodWord
        self.dispositionValence = dispositionValence.clampedSigned()
        self.dispositionWord = dispositionWord
        let feltCap = detail == .full ? Self.maximumFeltNodes : Self.compactFeltNodes
        // A PLAIN PREFIX WOULD UNDO THE SPLIT. The builder puts the strongest
        // first and the newest after them, so `prefix` in compact detail would
        // cut off exactly the recent half this exists to guarantee. Trim each
        // half in proportion instead.
        self.feltNodes = Self.trimmedFelt(feltNodes, cap: feltCap)
        self.chemistryWords = Array(chemistryWords.prefix(4))
        self.fatigue = fatigue.map { $0.clamped01() }
        self.timeOfDayPhase = timeOfDayPhase.map { String($0.prefix(Self.subjectLabelCharacters)) }
        self.expectations = Array(
            expectations.prefix(detail == .full ? Self.maximumExpectations : Self.compactListItems))
        self.toward = toward
        self.dream = dream
        self.growthWeek = detail == .full ? Array(growthWeek.prefix(Self.maximumGrowthWeekLines)) : []
        self.cares = detail == .full ? cares : Array(cares.prefix(Self.compactCares))
        self.story = detail == .full ? story : []
    }

    /// The honest "cognition is off" answer. Not zeros pretending to be a mood.
    public static func unavailable(at date: Date, windowHours: Double, detail: Detail) -> Self {
        CognitiveInnerStateReading(
            generatedAt: date, windowHours: windowHours, detail: detail, available: false)
    }
}

// MARK: - Optional organism reads the caller may already hold

/// What the reading cannot see for itself. The substrate does not own organism
/// state, so the caller (the cognition runtime, which owns both) hands over the
/// body's side of the answer. Every field is optional and defaults to absent:
/// a caller that has none of it still gets a truthful reading of the mind.
public struct CognitiveInnerStateOrganismReads: Sendable {
    public var projection: OrganismReadout?
    public var fatigue: Double?
    /// The body's clock read. The substrate turns it into a WORD — numbers
    /// choose words, and nothing outside the substrate chooses the word
    /// (design law 1), so callers hand over the read, never a phase string.
    public var diurnal: OrganismDiurnalRead?
    /// The nearest open horizon, from the organism's horizon register.
    public var toward: OrganismTowardRead?
    public var expectations: [CognitiveInnerStateReading.Expectation]

    public init(
        projection: OrganismReadout? = nil,
        fatigue: Double? = nil,
        diurnal: OrganismDiurnalRead? = nil,
        toward: OrganismTowardRead? = nil,
        expectations: [CognitiveInnerStateReading.Expectation] = []
    ) {
        self.projection = projection
        self.fatigue = fatigue
        self.diurnal = diurnal
        self.toward = toward
        self.expectations = expectations
    }

    public static let none = CognitiveInnerStateOrganismReads()
}

// MARK: - The read

extension CognitiveSubstrate {

    /// PURE. Reads never mutate (design law 5): no decay is advanced, no anchor
    /// moves, no node is evicted, nothing is persisted, no LLM is called.
    public func innerStateReading(
        windowHours: Double = CognitiveInnerStateReading.defaultWindowHours,
        detail: CognitiveInnerStateReading.Detail = .compact,
        organism: CognitiveInnerStateOrganismReads = .none,
        surface: String? = nil,
        at explicitNow: Date? = nil
    ) async -> CognitiveInnerStateReading {
        let now = explicitNow ?? dependencies.now()
        let window = min(
            CognitiveInnerStateReading.maximumWindowHours,
            max(CognitiveInnerStateReading.minimumWindowHours, windowHours))
        guard configuration.enabled else {
            return .unavailable(at: now, windowHours: window, detail: detail)
        }

        let read = await frozenRead(at: now)
        let dyn = read.personalityDynamics
        let currentAffect = read.affect
        let mood = read.mood
        // The canonical bounded workspace is selected on a copied field.
        let capsuleItems = read.workspace.items
            .filter { capsuleEligibleWorkspaceNode($0.node) }

        let request = CognitiveCapsuleRequest(
            surface: "inner_state",
            userMessage: "",
            mode: .inspectOnly,
            organismProjection: organism.projection,
            allowNonLiveProjection: true,
            turnKind: .live
        )
        let signals = feltSignalsForCapsule(
            from: capsuleItems, request: request, frozenRead: read)
        let fingerprintParts = Self.feltFingerprintParts(
            signals, intensityFloor: dyn.feltIntensityFloor)
        let fingerprint = fingerprintParts?.text

        let dominant = Self.feltDominantNode(
            in: feltTintNodes(from: capsuleItems), at: now,
            halfLife: dyn.fingerprintTintHalfLife)
        let fingerprintSubject = fingerprintParts.flatMap {
                Self.feltContributingObject(for: dominant, family: $0.family,
                    maxCharacters: CognitiveInnerStateReading.subjectLabelCharacters)
            }

        // The window's felt nodes: |valence| first, then recency. Same ranking
        // the felt-day summary uses, so the two surfaces never disagree about
        // which moment mattered most.
        let windowSeconds = window * 3600
        let feltCandidates = field.peekNodes()
            .filter { node in
                // Diagnostic traffic cannot contribute a lived feeling.
                guard node.turnKind.contributesToLivedState else { return false }
                // Tool observations affect the body but do not count as lived moments in this readout.
                guard node.kind != .toolObservation else { return false }
                // Mechanical rows are excluded from lived moments without changing their stored affect.
                guard !CognitiveMechanicalRowKind.marksMechanicalRow(node.metadata) else {
                    return false
                }
                guard node.feltDirection != nil else { return false }
                let age = now.timeIntervalSince(node.lastActivatedAt)
                return age >= 0 && age <= windowSeconds
            }
            .sorted { lhs, rhs in
                let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
                if lv != rv { return lv > rv }
                if lhs.lastActivatedAt != rhs.lastActivatedAt {
                    return lhs.lastActivatedAt > rhs.lastActivatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            // A MOMENT THAT CANNOT NAME ITS SUBJECT IS NOT SHOWN. Dropping
            // happens BEFORE the cap so an unnameable node costs the reading a
            // slot it could have given to a nameable one.
            .compactMap { node -> CognitiveInnerStateReading.FeltNode? in
                guard let subject = Self.innerStateSubjectLabel(node) else { return nil }
                return CognitiveInnerStateReading.FeltNode(
                    when: node.lastActivatedAt,
                    subject: subject,
                    valence: node.emotionalValence,
                    arousal: node.emotionalArousal,
                    warmth: node.emotionalWarmth,
                    selection: .felt
                )
            }
        // Collapse subject echoes only within `feltEchoInterval`, after strength sorting and before the cap.
        var keptAt: [String: [Date]] = [:]
        let deduped = feltCandidates
            .filter { candidate in
                let key = candidate.subject.lowercased()
                let echoes = keptAt[key] ?? []
                let interval = CognitiveInnerStateReading.feltEchoInterval
                guard !echoes.contains(where: {
                    abs($0.timeIntervalSince(candidate.when)) <= interval
                }) else { return false }
                keptAt[key, default: []].append(candidate.when)
                return true
            }


        // Strongest moments lead; newest remaining moments fill the cap with selection provenance.
        let ranked = Array(deduped)
        let strongest = ranked.prefix(CognitiveInnerStateReading.strongestFeltNodes)
        let recent = ranked
            .dropFirst(strongest.count)
            .sorted { lhs, rhs in
                if lhs.when != rhs.when { return lhs.when > rhs.when }
                return abs(lhs.valence) > abs(rhs.valence)
            }
            .prefix(CognitiveInnerStateReading.recentFeltNodes)
            .map { node in
                CognitiveInnerStateReading.FeltNode(
                    when: node.when, subject: node.subject, valence: node.valence,
                    arousal: node.arousal, warmth: node.warmth, selection: .recent)
            }
        let felt = Array(strongest) + recent

        return CognitiveInnerStateReading(
            generatedAt: now,
            windowHours: window,
            detail: detail,
            available: true,
            fingerprint: fingerprint,
            fingerprintSubject: fingerprintSubject,
            moodValence: mood.valence,
            moodBasis: mood.basis,
            moodWord: Self.innerStateMoodWord(mood.valence),
            dispositionValence: decayedDispositionValence(at: now, dynamics: dyn),
            dispositionWord: Self.innerStateDispositionWord(decayedDispositionValence(at: now, dynamics: dyn)),
            feltNodes: Array(felt),
            chemistryWords: Self.innerStateChemistryWords(organism.projection),
            fatigue: organism.fatigue,
            timeOfDayPhase: Self.innerStateTimeOfDayWord(organism.diurnal),
            expectations: organism.expectations,
            toward: organism.toward.map {
                CognitiveInnerStateReading.Toward(
                    label: $0.displayLabel,
                    sourceKind: $0.sourceKind.rawValue,
                    valenceSign: $0.valenceSign,
                    due: $0.dueAt,
                    isOverdue: $0.isOverdue
                )
            },
            dream: innerStateDreamResidue(),
            // Computed only when she asked for `full` — the projection walks
            // the timeline, and "how are you" must stay cheap.
            growthWeek: detail == .full ? await growthWeekLines(at: now) : [],
            cares: cares.values.filter { $0.fadedAt == nil }
                .map { (care: $0, charge: $0.charge(at: now)) }
                .sorted { abs($0.charge) != abs($1.charge) ? abs($0.charge) > abs($1.charge)
                    : $0.care.updatedAt > $1.care.updatedAt }
                .map {
                    CognitiveInnerStateReading.Care(
                        id: $0.care.id, about: $0.care.about, depth: $0.care.depth.rawValue, with: $0.care.with,
                        felt: $0.care.story.last(where: { $0.depthChange == nil })?.felt, charge: $0.charge,
                        open: $0.care.open, stance: $0.care.stance?.text,
                        because: $0.care.stance?.because, wouldChangeMind: $0.care.stance?.wouldChangeMind)
                },
            story: detail == .full ? careStoryLines() : []
        )
    }

    // MARK: - Word choice (numbers choose words; nothing else does — design law 1)

    /// The capsule's own mood-band thresholds, as single words.
    static func innerStateMoodWord(_ valence: Double) -> String {
        if valence >= moodPhrasingValenceThreshold { return "good" }
        if valence <= -moodPhrasingValenceThreshold { return "heavy" }
        if valence >= moodCongruenceValenceThreshold { return "leaning good" }
        if valence <= -moodCongruenceValenceThreshold { return "low" }
        return "even"
    }

    /// Words for the persisted disposition; never a reading of her prose.
    static func innerStateDispositionWord(_ valence: Double) -> String {
        if valence >= moodCongruenceValenceThreshold { return "settled" }
        if valence <= -moodCongruenceValenceThreshold { return "heavy" }
        return "even"
    }

    /// Chemistry AS WORDS — the exact `- Body:` vocabulary the capsule already
    /// speaks, split into its phrases. Not a second lexicon and not numbers with
    /// adjectives glued on: if the body line refuses to say something, so does
    /// this. Digits disqualify the whole line, the same rule
    /// `organismBodyLine` enforces.
    static func innerStateChemistryWords(_ projection: OrganismReadout?) -> [String] {
        guard let projection, !projection.isNeutral,
              let raw = projection.bodyLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.rangeOfCharacter(from: .decimalDigits) == nil
        else { return [] }
        let body = raw
            .replacingOccurrences(of: #"^-?\s*Body:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The positive line is a comma-joined blend of one or two graded
        // phrases; the stress lines are one sentence whose FIRST clause is the
        // felt part and whose second is the instruction to herself. Keep the
        // felt half only — she is being asked how she is, not what to do.
        let felt = body.split(separator: ";").first.map(String.init) ?? body
        return felt
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
            }
            .filter { !$0.isEmpty }
    }

    /// The body's clock, as a WORD.
    ///
    /// `OrganismDiurnalRead.nightliness` is 1 at the body's trough and 0 at its
    /// peak. The word comes off `feltLatenessFloor` — the SAME constant the felt
    /// word `late` gates on — and its mirror image, so both edges derive from
    /// one shared threshold and no second idea of what "late" means enters the
    /// system. Two organs disagreeing about the hour is exactly the shape that
    /// makes an agent contradict itself.
    ///
    /// Nil clock ⇒ nil word. Absence reads as absence, never as "daytime".
    static func innerStateTimeOfDayWord(_ diurnal: OrganismDiurnalRead?) -> String? {
        guard let diurnal else { return nil }
        if diurnal.nightliness >= feltLatenessFloor { return "late" }
        if diurnal.nightliness <= 1 - feltLatenessFloor { return "daytime" }
        return "ordinary hours"
    }

    /// Project the existing dream contribution, never classify an episode's prose.
    func innerStateDreamResidue() -> CognitiveInnerStateReading.DreamResidue? {
        guard let transition = dispositionTransitions.last(where: { $0.source.hasPrefix("dream ") }) else { return nil }
        let tone = transition.afterContribution - transition.afterDecay
        let word = tone > 0 ? "settled" : tone < 0 ? "heavy" : "even"
        return CognitiveInnerStateReading.DreamResidue(
            moodWord: word, date: String(transition.source.dropFirst("dream ".count)))
    }
}
