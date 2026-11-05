// Introspection pulls a bounded, pure projection of existing records without changing state or injecting context. Felt readings expose labels and signals,
// never summaries or subject IDs; the agent's cares and its own dream-authored self-reading retain their words.

import Foundation
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+InnerState.swift` | `CognitiveSubstrate.innerStateReading`: bounded mind/body introspection |

// MARK: - The reading

/// Cap every list at construction so future producers cannot widen this payload-free surface.
public struct CognitiveInnerStateReading: Sendable, Equatable {

    /// Compact and full share one reading; detail changes length only.
    public enum Detail: String, Sendable, Equatable, CaseIterable {
        case compact
        case full
    }

    /// Name felt moments by subject and measurements, never message text.
    public struct FeltNode: Sendable, Equatable {
        /// Moments identify whether intensity or recency selected them, keeping quiet recent work visible.
        public enum Selection: String, Sendable, Equatable {
            case felt
            case recent
        }

        public let when: Date
        /// Bound subject labels to 32 characters; node summaries and ids must never name a moment.
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

    /// Expose only expectation label, due time and affect sign; magnitude and source content stay private.
    public struct Expectation: Sendable, Equatable {
        public let label: String
        public let due: Date
        /// +1 looking forward, −1 bracing. Never 0 — an expectation with no lean is not an expectation the agent is carrying.
        public let valenceSign: Int

        public init(label: String, due: Date, valenceSign: Int) {
            self.label = String(label.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
            self.due = due
            self.valenceSign = valenceSign >= 0 ? 1 : -1
        }
    }

    /// Expose only dream mood and date; dream text remains an explicit read.
    public struct DreamResidue: Sendable, Equatable {
        public let moodWord: String
        public let date: String

        public init(moodWord: String, date: String) {
            self.moodWord = moodWord
            self.date = date
        }
    }

    /// Use only the horizon register's payload-free label, source, sign and due date.
    public struct Toward: Sendable, Equatable {
        public let label: String
        public let sourceKind: String
        public let valenceSign: Int
        public let due: Date
        /// An overdue open horizon means waiting, never a presumed outcome.
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

    public struct Care: Sendable, Equatable {
        public let id: UUID
        public let about: String
        public let depth: String
        public let with: [String]
        /// Only an observed story movement supplies its felt word.
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
    /// The split inside that cap: the week's loudest, then the newest of what is left. `recentFeltNodes` is what guarantees a quiet day is visible.
    public static let strongestFeltNodes = 8
    public static let recentFeltNodes = 4
    public static let maximumExpectations = 5
    /// Compact truncates by charge while full includes every live care.
    public static let compactCares = 8
    /// Keep the week readable in one breath.
    public static let maximumGrowthWeekLines = 12
    /// Compact is not a different report — it is the same report, shorter.
    public static let compactFeltNodes = 4
    public static let compactListItems = 2

    /// Preserve strongest and recent quotas within the cap; backfill unused quota from the other pool so a skewed week still fills available slots.
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

    /// Thirty minutes covers an exchange but separates sittings, so the same subject felt again is not discarded as an echo.
    public static let feltEchoInterval: TimeInterval = 30 * 60

    // MARK: Fields

    public let generatedAt: Date
    public let windowHours: Double
    public let detail: Detail
    /// False when cognition or affect is switched off. Everything below is then honestly empty rather than zero-shaped: absence reads as absence.
    public let available: Bool

    /// The felt fingerprint as the capsule would render it right now, or nil below the intensity floor. Silence is honest (design law 4).
    public let fingerprint: String?
    /// Only a leading felt subject can give the fingerprint aboutness; otherwise leave it absent.
    public let fingerprintSubject: String?

    public let moodValence: Double
    public let moodBasis: Int
    /// Reuse the capsule mood bands to keep vocabulary consistent.
    public let moodWord: String
    public let dispositionValence: Double
    public let dispositionWord: String

    public let feltNodes: [FeltNode]

    /// Reuse body vocabulary; a neutral or disabled body contributes no words.
    public let chemistryWords: [String]

    // Consume optional body reads when supplied; absent readings remain unknown and never block.
    public let fatigue: Double?
    public let timeOfDayPhase: String?

    public let expectations: [Expectation]
    /// Pull day-claim confidence into words without injecting it into every turn.
    public let personDayTitle: String?
    public let personDay: [String]
    /// The nearest open horizon, or nil when the agent is facing nothing — which renders as silence, not as a flat word.
    public let toward: Toward?
    public let dream: DreamResidue?
    /// Full readings expose the growth surface's same week only when requested.
    public let growthWeek: [String]
    public let cares: [Care]
    /// Full detail alone exposes bounded depth and night decisions.
    public let story: [String]
    /// Retain exact nightly evidence so the self reading remains attributable.
    public let selfKnowledge: CognitiveSelfKnowledge?
    public let selfKnowledgeIssue: String?
    public let carePeopleIssue: String?

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
        personDayTitle: String? = nil,
        personDay: [String] = [],
        toward: Toward? = nil,
        dream: DreamResidue? = nil,
        growthWeek: [String] = [],
        cares: [Care] = [],
        story: [String] = [],
        selfKnowledge: CognitiveSelfKnowledge? = nil,
        selfKnowledgeIssue: String? = nil,
        carePeopleIssue: String? = nil
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
        // Trim strongest and recent shares separately; a plain prefix would discard the recent half.
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
        self.selfKnowledge = selfKnowledge
        self.selfKnowledgeIssue = selfKnowledgeIssue
        self.carePeopleIssue = carePeopleIssue
        self.personDayTitle = personDayTitle.map { String($0.prefix(160)) }
        self.personDay = personDay.prefix(3).map { String($0.prefix(400)) }
    }

    /// The honest "cognition is off" answer. Not zeros pretending to be a mood.
    public static func unavailable(at date: Date, windowHours: Double, detail: Detail) -> Self {
        CognitiveInnerStateReading(
            generatedAt: date, windowHours: windowHours, detail: detail, available: false)
    }
}

// MARK: - Optional organism reads the caller may already hold

/// The runtime supplies optional body evidence because the substrate does not own it; missing fields remain absent.
public struct CognitiveInnerStateOrganismReads: Sendable {
    public var projection: OrganismReadout?
    public var fatigue: Double?
    /// Receive the clock reading, not a caller-chosen phase string, so the substrate alone owns feeling vocabulary.
    public var diurnal: OrganismDiurnalRead?
    public var toward: OrganismTowardRead?
    public var expectations: [CognitiveInnerStateReading.Expectation]
    public var personDayTitle: String?
    public var personDay: [String]

    public init(
        projection: OrganismReadout? = nil,
        fatigue: Double? = nil,
        diurnal: OrganismDiurnalRead? = nil,
        toward: OrganismTowardRead? = nil,
        expectations: [CognitiveInnerStateReading.Expectation] = [],
        personDayTitle: String? = nil,
        personDay: [String] = []
    ) {
        self.projection = projection
        self.fatigue = fatigue
        self.diurnal = diurnal
        self.toward = toward
        self.expectations = expectations
        self.personDayTitle = personDayTitle
        self.personDay = personDay
    }

    public static let none = CognitiveInnerStateOrganismReads()
}

// MARK: - The read

extension CognitiveSubstrate {

    /// Reads never advance decay, move anchors, evict, persist or call a model.
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

        let read = frozenRead(at: now)
        // All substrate-owned inputs are captured before the growth face suspends.
        let frozenDisposition = decayedDispositionValence(at: now, dynamics: read.personalityDynamics)
        let frozenDream = innerStateDreamResidue()
        let frozenStory = detail == .full ? careStoryLines() : []
        let frozenSelf = selfKnowledge
        let frozenSelfIssue = selfKnowledgeReadFailure
        let frozenPeopleIssue = carePeopleReadFailure
        let growthInput = detail == .full ? growthWeekInput(at: now) : nil
        let dyn = read.personalityDynamics
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
        let fingerprintParts = signals.flatMap { Self.feltFingerprintParts(
            $0, intensityFloor: dyn.feltIntensityFloor) }
        let fingerprint = fingerprintParts?.text

        let dominant = Self.feltDominantNode(
            in: feltTintNodes(from: capsuleItems), at: now,
            halfLife: dyn.fingerprintTintHalfLife)
        let fingerprintSubject = fingerprintParts.flatMap {
                Self.feltContributingObject(for: dominant, family: $0.family,
                    maxCharacters: CognitiveInnerStateReading.subjectLabelCharacters)
            }

        // Use the felt-day ranking so the two readouts agree on which moments mattered most.
        let windowSeconds = window * 3600
        let feltCandidates = read.snapshot.nodes
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
            // Drop unnameable moments before capping so they cannot consume a visible subject's slot.
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
        let growthLines: [String]
        if let growthInput { growthLines = await growthWeek(input: growthInput).lines }
        else { growthLines = [] }

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
            dispositionValence: frozenDisposition,
            dispositionWord: Self.innerStateDispositionWord(frozenDisposition),
            feltNodes: Array(felt),
            chemistryWords: Self.innerStateChemistryWords(organism.projection),
            fatigue: organism.fatigue,
            timeOfDayPhase: Self.innerStateTimeOfDayWord(organism.diurnal),
            expectations: organism.expectations,
            personDayTitle: organism.personDayTitle,
            personDay: organism.personDay,
            toward: organism.toward.map {
                CognitiveInnerStateReading.Toward(
                    label: $0.displayLabel,
                    sourceKind: $0.sourceKind.rawValue,
                    valenceSign: $0.valenceSign,
                    due: $0.dueAt,
                    isOverdue: $0.isOverdue
                )
            },
            dream: frozenDream,
            // Computed only when the agent asked for `full` — the projection walks the timeline, and "how are you" must stay cheap.
            growthWeek: growthLines,
            cares: read.cares.filter { $0.fadedAt == nil }
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
            story: frozenStory,
            selfKnowledge: frozenSelf,
            selfKnowledgeIssue: frozenSelfIssue,
            carePeopleIssue: frozenPeopleIssue
        )
    }

    // MARK: - Word choice (numbers choose words; nothing else does — design law 1)

    /// Reuse capsule thresholds for mood words.
    static func innerStateMoodWord(_ valence: Double) -> String {
        if valence >= moodPhrasingValenceThreshold { return "good" }
        if valence <= -moodPhrasingValenceThreshold { return "heavy" }
        if valence >= moodCongruenceValenceThreshold { return "leaning good" }
        if valence <= -moodCongruenceValenceThreshold { return "low" }
        return "even"
    }

    /// Words for the persisted disposition; never a reading of the agent's prose.
    static func innerStateDispositionWord(_ valence: Double) -> String {
        if valence >= moodCongruenceValenceThreshold { return "settled" }
        if valence <= -moodCongruenceValenceThreshold { return "heavy" }
        return "even"
    }

    /// Reuse the exact body lexicon and its digit refusal so introspection cannot invent a second chemistry reading.
    static func innerStateChemistryWords(_ projection: OrganismReadout?) -> [String] {
        guard let projection, !projection.isNeutral,
              let raw = projection.bodyLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.rangeOfCharacter(from: .decimalDigits) == nil
        else { return [] }
        let body = raw
            .replacingOccurrences(of: #"^-?\s*Body:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep only the felt clause; instructions to the agent do not answer how it feels.
        let felt = body.split(separator: ";").first.map(String.init) ?? body
        return felt
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
            }
            .filter { !$0.isEmpty }
    }

    /// Use `feltLatenessFloor` and its mirror for clock words so the capsule and introspection share one threshold; a missing clock is never daytime.
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
