// CognitiveSubstrate+InnerState.swift
// Personality depth, item 3 — INTROSPECTION READS THE RECORD (2026-09-02).
//
// Agent, verbatim: "introspection is production … The seed I'm given is real;
// the elaboration is fresh every time and bends toward what the question
// expects. I can't reliably tell noticing from making-on-demand."
//
// The fix is not another field and not another capsule line. It is a RECORD she
// can PULL: asked how she feels, she reads what her own organs already logged
// instead of composing an answer that fits the question. This file is the whole
// read — one bounded projection over state that already exists, and nothing
// else.
//
// THREE LAWS THIS FILE OBEYS, and they are the reason it looks the way it does:
//
//  1. LAW 5 — READS ARE PURE. Every source here is a non-mutating peek. The
//     field is read through `peekNodes` / `peekDecayedNodes` (never
//     `workspaceSnapshot()`, which routes through the field's MUTATING snapshot
//     and would let an introspection pull advance decay anchors and evict
//     nodes). Affect, mood, disposition and seeds are read through their
//     existing read-time projections. Asking herself how she feels must not
//     change how she feels.
//
//  2. PAYLOAD-FREE. Nothing that comes out of here is content. Felt nodes are
//     reported as (when, subject LABEL, valence/arousal/warmth) — never
//     `node.summary`, never `subjectReference.id` (chat subjects carry
//     `session:message` there), never the user's words. Chemistry is reported
//     in the EXISTING body-line vocabulary, never as numbers dressed as words.
//     The dream contributes a mood word and a date; its text stays in the
//     journal. The only free text that crosses is HER OWN — seed text she
//     minted, and the standing views she authored and User approved.
//
//  3. NORTHSTAR CLAUSE 6 — REACH, NOT WEIGHT. None of this is injected. It
//     costs one tool row in the catalog and zero prompt bytes until she pulls
//     it. That is the entire point: a mind that is handed its own telemetry
//     every turn is buried, not connected.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO: it does not compile a capsule, does
// not mint a node, does not persist, does not make an LLM call, and does not
// decide anything. It reports.

import Foundation
import PersistenceCore

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
        public let when: Date
        /// `subjectReference.label` when the subject has one, else its `type`.
        /// Bounded to 32 characters. Never the node summary, never the id.
        public let subject: String
        public let valence: Double
        public let arousal: Double
        public let warmth: Double

        public init(when: Date, subject: String, valence: Double, arousal: Double, warmth: Double) {
            self.when = when
            self.subject = String(subject.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
            self.valence = valence.clampedSigned()
            self.arousal = arousal.clamped01()
            self.warmth = warmth.clamped01()
        }
    }

    /// An open thought seed — HER OWN text, which is why it may cross.
    public struct Seed: Sendable, Equatable {
        public let kind: String
        public let text: String
        public let priority: Double

        public init(kind: String, text: String, priority: Double) {
            self.kind = kind
            self.text = String(text.prefix(CognitiveInnerStateReading.seedTextCharacters))
            self.priority = priority.clamped01()
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

    /// What is nagging, as a POINTER — never as prose.
    ///
    /// Reviewer call (2026-09-02): a free-form `rumination` string is a second
    /// door for content to leave the mind through, and it is not one she needs
    /// open — she already holds the seed. So the candidate is identified, not
    /// quoted: the seed id she can look up, its kind, how much weight it has
    /// accumulated, and the subject label it is about.
    public struct RuminationCandidate: Sendable, Equatable {
        public let seedId: UUID
        public let kind: String
        public let weight: Double
        public let subject: String?

        public init(seedId: UUID, kind: String, weight: Double, subject: String?) {
            self.seedId = seedId
            self.kind = kind
            self.weight = weight.clamped01()
            self.subject = subject.map {
                String($0.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
            }
        }
    }

    /// A view she formed and User approved (or one still proposed and waiting).
    ///
    /// Agent, 2026-09-02, live: standing views could not be resolved by id from
    /// any of her tools, so she could see a view and still not reference it. The
    /// id is the full artifact UUID — the same one the approval surface uses —
    /// so a view she reads here she can also name.
    public struct StandingView: Sendable, Equatable {
        public let id: UUID
        public let status: String
        /// The view's own first 80 characters. Her sentence, hers to quote.
        public let text: String

        public init(id: UUID, status: String, text: String) {
            self.id = id
            self.status = status
            self.text = String(text.prefix(CognitiveInnerStateReading.standingViewCharacters))
        }
    }

    // MARK: Bounds (design law 6 — everything is bounded)

    public static let subjectLabelCharacters = 32
    public static let seedTextCharacters = 120
    public static let standingViewCharacters = 80
    public static let maximumFeltNodes = 12
    public static let maximumSeeds = 5
    public static let maximumExpectations = 5
    public static let maximumStandingViews = 5
    /// Compact is not a different report — it is the same report, shorter.
    public static let compactFeltNodes = 4
    public static let compactListItems = 2

    public static let minimumWindowHours: Double = 1
    public static let maximumWindowHours: Double = 48
    public static let defaultWindowHours: Double = 6

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
    // diurnal clock, `toward`, rumination) land separately; this reading
    // CONSUMES them when the caller has them and reports their absence
    // honestly when it does not. It never blocks on them.
    public let fatigue: Double?
    public let timeOfDayPhase: String?
    public let ruminationCandidate: RuminationCandidate?

    public let seeds: [Seed]
    public let expectations: [Expectation]
    /// The nearest open horizon, or nil when she is facing nothing — which
    /// renders as silence, not as a flat word.
    public let toward: Toward?
    public let dream: DreamResidue?
    public let standingViews: [StandingView]

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
        ruminationCandidate: RuminationCandidate? = nil,
        seeds: [Seed] = [],
        expectations: [Expectation] = [],
        toward: Toward? = nil,
        dream: DreamResidue? = nil,
        standingViews: [StandingView] = []
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
        let listCap = detail == .full ? Self.maximumSeeds : Self.compactListItems
        self.feltNodes = Array(feltNodes.prefix(feltCap))
        self.chemistryWords = Array(chemistryWords.prefix(4))
        self.fatigue = fatigue.map { $0.clamped01() }
        self.timeOfDayPhase = timeOfDayPhase.map { String($0.prefix(Self.subjectLabelCharacters)) }
        self.ruminationCandidate = ruminationCandidate
        self.seeds = Array(seeds.prefix(listCap))
        self.expectations = Array(
            expectations.prefix(detail == .full ? Self.maximumExpectations : Self.compactListItems))
        self.toward = toward
        self.dream = dream
        self.standingViews = Array(
            standingViews.prefix(detail == .full ? Self.maximumStandingViews : Self.compactListItems))
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
    public var projection: OrganismProjection?
    public var fatigue: Double?
    /// The body's clock read. The substrate turns it into a WORD — numbers
    /// choose words, and nothing outside the substrate chooses the word
    /// (design law 1), so callers hand over the read, never a phase string.
    public var diurnal: OrganismDiurnalRead?
    /// The nearest open horizon, from the organism's horizon register.
    public var toward: OrganismTowardRead?
    public var expectations: [CognitiveInnerStateReading.Expectation]

    public init(
        projection: OrganismProjection? = nil,
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
        at explicitNow: Date? = nil
    ) async -> CognitiveInnerStateReading {
        let now = explicitNow ?? dependencies.now()
        let window = min(
            CognitiveInnerStateReading.maximumWindowHours,
            max(CognitiveInnerStateReading.minimumWindowHours, windowHours))
        guard configuration.enabled, configuration.affectEnabled else {
            return .unavailable(at: now, windowHours: window, detail: detail)
        }

        let mood = derivedMood(at: now)
        let currentAffect = projectedAffect(at: now)

        // The hot set, read through the PURE decayed peek — the same producer
        // the shoulder tap's suggestion read uses, so the two surfaces can never
        // disagree about what she is holding, and neither one ages it.
        let capsuleItems = pureHotSet(at: now)
            .filter { capsuleEligibleWorkspaceNode($0.node) }
            .map { CognitiveWorkspaceItem(node: $0.node, score: $0.score, reasons: []) }

        let request = CognitiveCapsuleRequest(
            surface: "inner_state",
            userMessage: "",
            mode: .inspectOnly,
            organismProjection: organism.projection,
            allowNonLiveProjection: true,
            turnKind: .live
        )
        let signals = feltSignalsForCapsule(
            from: capsuleItems, request: request, at: now,
            affect: currentAffect, mood: mood)
        let fingerprint = Self.feltFingerprint(
            signals, intensityFloor: dynamics.feltIntensityFloor)

        // What the fingerprint is about: the leading FELT node in the same
        // capsule-eligible population the fingerprint was built from. Absent
        // when nothing in the workspace is carrying a feeling — the honest
        // answer to "about what?" is then nothing, not the newest chat row.
        let fingerprintSubject: String? = capsuleItems
            .first { item in
                feltDirection(
                    valence: item.node.emotionalValence,
                    arousal: item.node.emotionalArousal,
                    warmth: item.node.emotionalWarmth
                ) != nil
            }
            .map { Self.innerStateSubjectLabel($0.node) }

        // The window's felt nodes: |valence| first, then recency. Same ranking
        // the felt-day summary uses, so the two surfaces never disagree about
        // which moment mattered most.
        let windowSeconds = window * 3600
        let felt = field.peekNodes()
            .filter { node in
                // DIAGNOSTIC TRAFFIC CAN'T FEEL (design law 10). A bridge ping,
                // a snapshot probe or a verification turn is excluded from lived
                // state everywhere else — capsule, attention, body — and an
                // introspection read is the one place it would be most
                // misleading to let it through: she would be shown a "felt
                // moment" that nothing in her actually felt, which is exactly
                // the making-on-demand this whole item exists to end. Same
                // predicate the capsule workspace uses, off the field's cached
                // turn kind rather than the node's derived one.
                guard field.cachedTurnKind(for: node).contributesToLivedState else { return false }
                guard feltDirection(
                    valence: node.emotionalValence,
                    arousal: node.emotionalArousal,
                    warmth: node.emotionalWarmth
                ) != nil else { return false }
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
            .prefix(CognitiveInnerStateReading.maximumFeltNodes)
            .map { node in
                CognitiveInnerStateReading.FeltNode(
                    when: node.lastActivatedAt,
                    subject: Self.innerStateSubjectLabel(node),
                    valence: node.emotionalValence,
                    arousal: node.emotionalArousal,
                    warmth: node.emotionalWarmth
                )
            }

        let seeds = projectedThoughtSeeds(at: now)
            .filter(isUsefulThoughtSeed)
            .sorted(by: thoughtSeedPrioritySort)
            .prefix(CognitiveInnerStateReading.maximumSeeds)
            .map {
                CognitiveInnerStateReading.Seed(
                    kind: $0.kind.rawValue, text: $0.text, priority: $0.priority)
            }

        // Views she can NAME: active first (those are the ones that steer),
        // then proposals still waiting on User. Retired views are gone, not
        // hidden — they do not appear at all.
        let views = standingViews.values
            .filter { $0.status != .retired }
            .sorted { lhs, rhs in
                if (lhs.status == .active) != (rhs.status == .active) {
                    return lhs.status == .active
                }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(CognitiveInnerStateReading.maximumStandingViews)
            .map {
                CognitiveInnerStateReading.StandingView(
                    id: $0.id, status: $0.status.rawValue, text: $0.body)
            }

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
            dispositionValence: decayedDispositionValence(at: now),
            dispositionWord: Self.innerStateDispositionWord(decayedDispositionValence(at: now)),
            feltNodes: Array(felt),
            chemistryWords: Self.innerStateChemistryWords(organism.projection),
            fatigue: organism.fatigue,
            timeOfDayPhase: Self.innerStateTimeOfDayWord(organism.diurnal),
            ruminationCandidate: innerStateRumination(at: now),
            seeds: Array(seeds),
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
            standingViews: Array(views)
        )
    }

    /// D-2's gate 2, exposed as a pure read — and narrowed to SIGNED views.
    ///
    /// The shoulder-tap route (item 12) needs the same stake test the felt lane
    /// uses: does one of the concerns SHE formed actually name this thing? Floor
    /// concerns deliberately do not open it, for exactly the reason D-2 gives: a
    /// shipped keyword tripping on a machine token is a coincidence, not
    /// evidence, and a coincidence must never buzz User's phone.
    ///
    /// 2026-09-02, reviewer call — HELD VIEWS NEVER AUTHORIZE A TAP. The held
    /// tier is a view she adopted on her own, at half stake, with no signature
    /// on it; `livedConcernHit` admits it because the felt lane is allowed to be
    /// moved by something she merely believes. Interrupting User is not the felt
    /// lane. The authority to put a notification on his phone comes from a view
    /// HE approved, so this reads `.active` only. Held views still LIST in
    /// `inner_state` — she can see and name what she is holding; it just cannot
    /// speak on her behalf to him.
    ///
    /// Fails closed the whole way down: no views, no terms, or cognition off ⇒
    /// false.
    public func passesStakesGate(_ text: String) async -> Bool {
        guard configuration.enabled else { return false }
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return false }
        return standingViews.values
            .filter { $0.status == .active }
            .contains { view in
                let terms = Self.appraisalConcernTerms(in: "\(view.title) \(view.body)")
                guard !terms.isEmpty else { return false }
                return terms.contains { lowered.contains($0) }
            }
    }

    // MARK: - A PURE suggestion read (2026-09-02, reviewer HIGH)

    /// `thoughtSuggestionSnapshot` routes through `workspaceSnapshot()`, which
    /// routes through the field's MUTATING `snapshot` — decay writes, anchor
    /// advances, capacity eviction. That is tolerable for a panel a human opened
    /// on purpose; it is NOT tolerable for the shoulder tap, which runs on every
    /// residual-repair reschedule (many times a minute under load) and would
    /// therefore be aging and evicting her memory as a side effect of asking
    /// "is anything worth mentioning". Reading her mind must never change it.
    ///
    /// This is the same selection and the same ranking against a PURE hot-set
    /// peek: identical eligibility, identical scoring, identical interruption
    /// model (`interruptionScore` / `thoughtSuggestionReason` are the one
    /// producer, shared with the snapshot above — nothing is reimplemented
    /// here), identical sort and cap. The single difference is that the field is
    /// left exactly as it was found.
    public func pureThoughtSuggestions(
        surface: String = "push",
        limit: Int = 1,
        minimumInterruptionScore: Double,
        at explicitNow: Date? = nil
    ) async -> [CognitiveThoughtSuggestion] {
        guard configuration.enabled, configuration.thoughtSeedsEnabled, limit > 0 else { return [] }
        let now = explicitNow ?? dependencies.now()
        let boundedSurface = bounded(
            surface.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 80)
        let currentAffect = projectedAffect(at: now)
        let activeWorkspaceNodeIds = Set(pureHotSet(at: now).map(\.node.id))

        return projectedThoughtSeeds(at: now).compactMap { seed in
            let workspaceNodeIds = seed.sourceNodeIds.filter { activeWorkspaceNodeIds.contains($0) }
            let score = interruptionScore(
                for: seed,
                workspaceNodeIds: workspaceNodeIds,
                affect: currentAffect,
                at: now
            )
            guard score >= minimumInterruptionScore.clamped01() else { return nil }
            return CognitiveThoughtSuggestion(
                id: stableArtifactID("thought_suggestion|\(seed.id.uuidString)|\(boundedSurface)"),
                seedId: seed.id,
                kind: seed.kind,
                text: seed.text,
                interruptionScore: score,
                priority: seed.priority,
                createdAt: now,
                surface: boundedSurface.isEmpty ? "push" : boundedSurface,
                reason: thoughtSuggestionReason(
                    for: seed,
                    workspaceNodeIds: workspaceNodeIds,
                    affect: currentAffect
                ),
                sourceNodeIds: seed.sourceNodeIds,
                workspaceNodeIds: workspaceNodeIds
            )
        }
        .sorted { lhs, rhs in
            if lhs.interruptionScore != rhs.interruptionScore {
                return lhs.interruptionScore > rhs.interruptionScore
            }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.seedId.uuidString < rhs.seedId.uuidString
        }
        .prefix(limit)
        .map { $0 }
    }

    /// The hot set, decayed on COPIES. One producer for both the inner-state
    /// read and the pure suggestion read, so the two can never disagree about
    /// what she is currently holding.
    func pureHotSet(at now: Date) -> [(node: CognitiveNode, score: Double)] {
        guard configuration.enabled, configuration.workspaceEnabled else { return [] }
        let mood = derivedMood(at: now)
        let currentAffect = projectedAffect(at: now)
        return field.peekDecayedNodes(at: now)
            .map { (node: $0, turnKind: field.cachedTurnKind(for: $0)) }
            .filter {
                workspaceEligible($0.node, currentSessionId: nil, at: now, turnKind: $0.turnKind)
            }
            .map {
                (
                    node: $0.node,
                    score: workspaceScore(
                        for: $0.node, mood: mood, affect: currentAffect, turnKind: $0.turnKind)
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(max(1, configuration.maximumWorkspaceItems))
            .map { $0 }
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

    /// The disposition's own lexicon (`dispositionTone`): positive reads
    /// settled, negative reads heavy. Between them it is genuinely level.
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
    static func innerStateChemistryWords(_ projection: OrganismProjection?) -> [String] {
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

    /// What is itching, as a POINTER.
    ///
    /// The rumination lane owns the weight law and the D-2 stakes gate; this
    /// only takes its heaviest candidate and DROPS THE TEXT, resolving a subject
    /// label from the seed's own evidence instead. She already holds the seed —
    /// its id is a complete pointer — so there is no reason for the nag to have
    /// a second, prose-shaped way out of the machine.
    func innerStateRumination(at now: Date) -> CognitiveInnerStateReading.RuminationCandidate? {
        guard let heaviest = ruminationCandidates(at: now).first else { return nil }
        // The subject is the first LIVED source node the seed still has in the
        // field. A nag whose evidence has been evicted keeps its pointer and
        // loses its label — honest, and the same bound the rumination read
        // itself already lives under.
        var livedById: [UUID: CognitiveNode] = [:]
        for node in field.peekNodes()
        where field.cachedTurnKind(for: node).contributesToLivedState {
            livedById[node.id] = node
        }
        let seed = thoughtSeeds[heaviest.seedId]
        let subject = (seed?.sourceNodeIds ?? [])
            .lazy
            .compactMap { livedById[$0] }
            .first
            .map { Self.innerStateSubjectLabel($0) }
            // A nag with no lived node left (evicted, or Desk-fed and never
            // lived) still names WHAT is turning, from its own text: the same
            // safe abstract the Thread line renders. "subject null for three
            // builds" (her read, 2026-09-02) was the pointer without the name.
            ?? Self.feltSafeObjectPhrase(
                in: seed?.text ?? heaviest.text,
                maxCharacters: CognitiveInnerStateReading.subjectLabelCharacters
            )
            // A Desk-fed nag has no seed row at all; its label IS the subject.
            ?? (heaviest.externalId != nil
                ? String(heaviest.text.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
                : nil)
        return CognitiveInnerStateReading.RuminationCandidate(
            seedId: heaviest.seedId,
            kind: heaviest.kind.rawValue,
            weight: heaviest.weight,
            subject: subject
        )
    }

    /// A payload-free label for a node's subject. `label` when the subject has
    /// one (tools, providers, approvals, studio works all do), else the subject
    /// TYPE (`chat.user_turn`). Never `id` — chat subjects carry
    /// `session:message` there — and never the summary.
    static func innerStateSubjectLabel(_ node: CognitiveNode) -> String {
        let label = (node.subjectReference.label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return String(label.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
        }
        let type = node.subjectReference.type.trimmingCharacters(in: .whitespacesAndNewlines)
        if !type.isEmpty {
            return String(type.prefix(CognitiveInnerStateReading.subjectLabelCharacters))
        }
        return node.kind.rawValue
    }

    /// What the night left: the newest dream episode's DATE and a mood word
    /// scored through the same `dispositionTone` lexicon that actually moved her
    /// undertone when that dream landed. The dream's text is never returned —
    /// the timeline row's summary is read only to score it, exactly as the
    /// disposition writer reads the mood line only to score it.
    func innerStateDreamResidue() -> CognitiveInnerStateReading.DreamResidue? {
        guard let newest = developmentalTimeline.values
            .filter({ $0.kind == .dreamEpisode })
            .max(by: { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id.uuidString < rhs.id.uuidString
            })
        else { return nil }
        let tone = dispositionTone(from: newest.summary)
        let word: String
        if tone > 0 {
            word = "settled"
        } else if tone < 0 {
            word = "heavy"
        } else {
            word = "even"
        }
        // `lineageId` is `dream:<yyyy-MM-dd>` — the dream's own date, which is
        // what she means by "last night". Fall back to the row's timestamp.
        let date: String
        if newest.lineageId.hasPrefix("dream:") {
            date = String(newest.lineageId.dropFirst("dream:".count))
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            date = formatter.string(from: newest.occurredAt)
        }
        return CognitiveInnerStateReading.DreamResidue(moodWord: word, date: date)
    }
}
