import Foundation
import Experiences
import PersistenceCore

// Blueprint: | `CognitivePhaseModels.swift` | Cognition phase contracts: prepared turn projections, presentation commits, attention, workspace, capsule and care values |

public protocol CognitiveEventObserving: Sendable {
    func observe(_ event: CognitiveEvent) async
}

public protocol CognitiveContextProviding: Sendable {
    /// One fixed-time value for the ordinary turn's cognition/organism seam.
    /// The value is advisory and owns no authority.
    func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitiveTurnProjection
    /// Commits presentation-only bookkeeping after the caller actually adds
    /// the projection to the provider context. Preparation itself must not
    /// consume a surfaced-body/capsule window.
    func commitTurnProjection(
        _ projection: CognitiveTurnProjection,
        request: CognitiveCapsuleRequest
    ) async
    /// Mind-into-circulation (2026-07-10): a bounded, PURE read of what she is
    /// currently holding — hot workspace subjects, the open question, felt
    /// activation on remembered material, and what the organism is bracing
    /// for. Consumed by the turn engine to populate Fluid Context's dormant
    /// NeedSignal inputs so context selection follows her mind, not just the
    /// message. nil (the default) means "nothing to add" and MUST leave turn
    /// preparation byte-identical to the unwired behavior.
    func attentionSignals(at date: Date) async -> CognitiveAttentionSignals?
}

extension CognitiveContextProviding {
    /// Default keeps every existing conformer source-compatible and inert.
    public func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? { nil }


}

/// What her mind is holding right now, shaped for the context selector.
/// All fields are bounded at CONSTRUCTION so no producer can flood the
/// selector: terms ≤ 16 (64 chars each), tool groups ≤ 8, memory ids ≤ 32,
/// working ids ≤ 16, free-text intents ≤ 200 chars. Weights clamp to 0…1.
/// Memory entries carry MEMORY RECORD ids — never context atom ids; the
/// app layer owns the projection's stable-ID derivation.
public struct CognitiveAttentionSignals: Sendable, Equatable {
    // `let`, not `var` (gpt-5.5 review, 2026-07-10): the initializer IS the
    // bounding contract — mutable fields would let any conformer assign
    // unbounded values after construction and bypass every cap the turn
    // engine relies on.
    public let terms: [String: Double]
    public let unresolvedQuestion: String?
    public let activeTask: String?
    public let goal: String?
    /// Provenance bit for an activeTask/goal supplied by the resident Desk
    /// pursuit overlay. The turn engine keeps this intent out of ordinary
    /// conversation relevance; the Desk context projection remains available
    /// for explicit, query-selected work recall.
    public let residentWorkIntent: Bool
    public let predictedToolGroups: Set<String>
    public let memoryActivation: [String: Double]
    public let workingMemoryRecordIDs: Set<String>
    /// Phase 5 B0: memory record id → the signatures she rejected it for
    /// (empty signature: never). ≤ 48 rows, already capped by the owner.
    public let suppressedMemory: [String: [[String]]]

    public var isEmpty: Bool {
        terms.isEmpty && unresolvedQuestion == nil && activeTask == nil
            && goal == nil && predictedToolGroups.isEmpty
            && memoryActivation.isEmpty && workingMemoryRecordIDs.isEmpty
            && suppressedMemory.isEmpty
    }

    /// The record ids she rejected for this kind of message.
    public func suppressedMemoryRecordIDs(for message: String) -> Set<String> {
        guard !suppressedMemory.isEmpty else { return [] }
        let terms = CognitiveSubstrate.associationTerms(in: message)
        return Set(suppressedMemory.compactMap { id, signatures in
            signatures.contains { CognitiveSubstrate.suppressionCovers($0, messageTerms: terms) } ? id : nil
        })
    }

    public init(
        terms: [String: Double] = [:],
        unresolvedQuestion: String? = nil,
        activeTask: String? = nil,
        goal: String? = nil,
        residentWorkIntent: Bool = false,
        predictedToolGroups: Set<String> = [],
        memoryActivation: [String: Double] = [:],
        workingMemoryRecordIDs: Set<String> = [],
        suppressedMemory: [String: [[String]]] = [:]
    ) {
        func bounded(_ text: String, to limit: Int) -> String {
            text.count <= limit ? text : String(text.prefix(limit))
        }
        // Deterministic keep-order under the caps: strongest first, then
        // lexicographic so equal weights can't reshuffle across calls (the
        // packet fingerprint folds these in — nondeterminism would thrash
        // the selection cache).
        func cappedByWeight(_ dict: [String: Double], cap: Int, keyLimit: Int) -> [String: Double] {
            var entries: [(key: String, value: Double)] = dict.map { entry in
                (key: bounded(entry.key, to: keyLimit), value: (entry.value).clamped01())
            }
            entries.sort { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            var result: [String: Double] = [:]
            for entry in entries.prefix(cap) {
                result[entry.key] = max(result[entry.key] ?? 0, entry.value)
            }
            return result
        }
        self.terms = cappedByWeight(terms, cap: 16, keyLimit: 64)
        self.unresolvedQuestion = unresolvedQuestion.map { bounded($0, to: 200) }
        self.activeTask = activeTask.map { bounded($0, to: 200) }
        self.goal = goal.map { bounded($0, to: 200) }
        self.residentWorkIntent = residentWorkIntent
        self.predictedToolGroups = Set(predictedToolGroups.sorted().prefix(8).map { bounded($0, to: 64) })
        self.memoryActivation = cappedByWeight(memoryActivation, cap: 32, keyLimit: 128)
        self.workingMemoryRecordIDs = Set(workingMemoryRecordIDs.sorted().prefix(16).map { bounded($0, to: 128) })
        self.suppressedMemory = suppressedMemory
    }
}

// Task-extraction was removed from the subconscious (2026-06-30 redirect;
// machinery deleted in R8c, the assimilate() seam itself in this follow-up).
// Turn ingestion happens through CognitiveEventObserving; nothing extracts
// commitments/predictions from conversation.
public protocol CognitiveRuntimeProviding: CognitiveEventObserving, CognitiveContextProviding {}

public enum CognitiveCapsuleMode: String, Sendable, Equatable, CaseIterable {
    case off
    case inspectOnly
    case inject
}

public struct CognitiveWorkspaceItem: Sendable, Equatable, Identifiable {
    public var id: UUID { node.id }
    public var node: CognitiveNode
    public var score: Double
    public var reasons: [String]

    public init(node: CognitiveNode, score: Double, reasons: [String]) {
        self.node = node
        self.score = (score).clamped01()
        self.reasons = reasons
    }
}

public struct CognitiveWorkspaceSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var items: [CognitiveWorkspaceItem]
    public var inhibitedNodeIds: [UUID]

    public init(generatedAt: Date, items: [CognitiveWorkspaceItem], inhibitedNodeIds: [UUID] = []) {
        self.generatedAt = generatedAt
        self.items = items
        self.inhibitedNodeIds = inhibitedNodeIds
    }
}

public struct CognitiveCapsuleRequest: Sendable, Equatable {
    public var surface: String
    public var userMessage: String
    public var sessionId: String?
    public var mode: CognitiveCapsuleMode
    public var maximumCharacters: Int?
    public var organismProjection: OrganismProjection?
    /// Item 5 (2026-09-02) — the nearest open horizon, when the caller has one.
    /// Payload-free by construction (`OrganismTowardRead` is a label, a sign and
    /// a date). Carried on the REQUEST rather than folded into the projection
    /// because it comes from the prediction ledger, which the projection does
    /// not own; nil everywhere it is not supplied, and then the felt line has
    /// no forward object — silence, not an invented one.
    public var toward: OrganismTowardRead?
    /// Trusted local teammate bridges may read the current inner-state
    /// projection without allowing their diagnostic traffic to become felt
    /// experience. Event turn-kind filtering remains independent.
    public var allowNonLiveProjection: Bool
    /// Accepted chat provenance, when supplied by the shared turn owner.
    /// Bare diagnostic callers retain legacy inference for compatibility.
    public var turnKind: CognitiveTurnKind?
    /// Phase 5 B2: User started this turn himself, from one of his doors (Mac,
    /// phone, Telegram). Her wakes, peer threads and bridge lanes are not him,
    /// so they never open or close the "since we last talked" gap.
    public var fromUser: Bool
    /// Phase 5 B2/E2: User's verified turn before this one (`UserTurnStamp`),
    /// where the gap this turn closes opened. Nil when unknown or not his turn.
    public var previousUserTurnAt: Date?
    /// Cares lane 2: whose words these are, as cares key people (`owner`, a
    /// peer id, a helper's bot id). Nil for her own wake or a sender with no
    /// person key: only her own cares press then.
    public var speaker: String?

    public var resolvedTurnKind: CognitiveTurnKind {
        turnKind ?? CognitiveTurnKind.inferred(fromSignals: [
            surface, sessionId ?? "", userMessage,
        ])
    }

    public init(
        surface: String,
        userMessage: String,
        sessionId: String? = nil,
        mode: CognitiveCapsuleMode = .inspectOnly,
        maximumCharacters: Int? = nil,
        organismProjection: OrganismProjection? = nil,
        toward: OrganismTowardRead? = nil,
        allowNonLiveProjection: Bool = false,
        turnKind: CognitiveTurnKind? = nil,
        fromUser: Bool = false,
        previousUserTurnAt: Date? = nil,
        speaker: String? = nil
    ) {
        self.surface = surface
        self.userMessage = userMessage
        let trimmedSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionId = trimmedSession?.isEmpty == true ? nil : trimmedSession
        self.mode = mode
        self.maximumCharacters = maximumCharacters
        self.organismProjection = organismProjection
        self.toward = toward
        self.allowNonLiveProjection = allowNonLiveProjection
        self.turnKind = turnKind
        self.fromUser = fromUser
        self.previousUserTurnAt = previousUserTurnAt
        self.speaker = speaker
    }
}

public struct CognitiveCapsule: Sendable, Equatable {
    public var generatedAt: Date
    public var mode: CognitiveCapsuleMode
    public var stableKernel: String
    public var dynamicContext: String
    public var provenanceNodeIds: [UUID]
    public var sourcePeerIds: [String]?
    public var truncated: Bool

    public var combined: String {
        [stableKernel, dynamicContext]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public init(
        generatedAt: Date,
        mode: CognitiveCapsuleMode,
        stableKernel: String,
        dynamicContext: String,
        provenanceNodeIds: [UUID],
        truncated: Bool,
        sourcePeerIds: [String]? = nil
    ) {
        self.generatedAt = generatedAt
        self.mode = mode
        self.stableKernel = stableKernel
        self.dynamicContext = dynamicContext
        self.provenanceNodeIds = provenanceNodeIds
        self.sourcePeerIds = sourcePeerIds
        self.truncated = truncated
    }
}

/// Pure result of rendering one live injection against a frozen presentation
/// state. The substrate applies it only after the provider accepts that exact
/// turn; previews, reflections, failures, and retries merely discard it.
public struct CognitiveCapsulePresentationCommit: Sendable, Equatable {
    public let fixedAt: Date
    public let expected: CognitiveCapsulePresentationState
    public let next: CognitiveCapsulePresentationState

    public init(
        fixedAt: Date,
        expected: CognitiveCapsulePresentationState,
        next: CognitiveCapsulePresentationState
    ) {
        self.fixedAt = fixedAt
        self.expected = expected
        self.next = next
    }
}

public struct CognitivePreparedCapsule: Sendable, Equatable {
    public let capsule: CognitiveCapsule
    public let presentationCommit: CognitiveCapsulePresentationCommit?
    /// Phase 5 B0: why this cue (or none) — for the turn trace, never the prompt.
    public let why: JSONValue?

    public init(
        capsule: CognitiveCapsule,
        presentationCommit: CognitiveCapsulePresentationCommit? = nil,
        why: JSONValue? = nil
    ) {
        self.capsule = capsule
        self.presentationCommit = presentationCommit
        self.why = why
    }
    /// The capsule to inject, or nil when this turn's felt answer was "none".
    public var nonEmptyCapsule: CognitiveCapsule? {
        capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : capsule
    }
}

/// Bounded, immutable turn-scoped composition of the existing cognition and
/// organism owners. This is a read value, not a new state owner or global
/// transaction; effect-time authority remains independently revalidated.
public struct CognitiveTurnProjection: Sendable, Equatable {
    public let fixedAt: Date
    public let capsule: CognitiveCapsule?
    public let posture: OrganismBehaviorPosture?
    public let capsulePresentationCommit: CognitiveCapsulePresentationCommit?
    /// Phase 5 B0: the cue's `mind.why` record, fired into the turn trace once
    /// the turn is delivered.
    public let why: JSONValue?

    public init(
        fixedAt: Date,
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?,
        capsulePresentationCommit: CognitiveCapsulePresentationCommit? = nil,
        why: JSONValue? = nil
    ) {
        self.fixedAt = fixedAt
        self.capsule = capsule
        self.posture = posture
        self.capsulePresentationCommit = capsulePresentationCommit
        self.why = why
    }

    public var isEmpty: Bool { capsule == nil && posture == nil }
}

public struct CognitiveAffectState: Sendable, Equatable {
    public var arousal: Double
    public var uncertainty: Double
    public var taskPressure: Double
    public var socialWarmth: Double
    public var updatedAt: Date

    public init(
        arousal: Double = 0,
        uncertainty: Double = 0,
        taskPressure: Double = 0,
        socialWarmth: Double = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.arousal = (arousal).clamped01()
        self.uncertainty = (uncertainty).clamped01()
        self.taskPressure = (taskPressure).clamped01()
        self.socialWarmth = (socialWarmth).clamped01()
        self.updatedAt = updatedAt
    }
}

public struct CognitiveEpisodeReference: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var summary: String
    public var occurredAt: Date
    public var evidenceNodeIds: [UUID]
    public var externalEvidenceIds: [String]
    public var lineageId: String

    public init(
        id: UUID,
        title: String,
        summary: String,
        occurredAt: Date,
        evidenceNodeIds: [UUID] = [],
        externalEvidenceIds: [String] = [],
        lineageId: String = ""
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
        self.evidenceNodeIds = evidenceNodeIds
        self.externalEvidenceIds = externalEvidenceIds
        self.lineageId = lineageId
    }
}

public enum CognitiveSchemaProposalStatus: String, Sendable, Equatable, CaseIterable {
    case proposed
    case accepted
    case rejected
    case unavailable
}

public struct CognitiveSchemaProposal: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var target: String
    /// A read projection, never persisted as cognitive status.
    public var decision: Experience? = nil
    public var status: CognitiveSchemaProposalStatus {
        guard let decision else { return .unavailable }
        switch decision.outcome?.status {
        case "approved": return decision.claims.contains { $0.claim == "applied" } ? .accepted : .unavailable
        case "denied", "canceled": return .rejected
        default: return decision.isOpen ? .proposed : .rejected
        }
    }
    public var confidence: Double
    public var createdAt: Date
    public var evidenceNodeIds: [UUID]
    public var externalEvidenceIds: [String]
    public var lineageId: String

    public init(
        id: UUID,
        title: String,
        body: String,
        target: String,
        confidence: Double = 0,
        createdAt: Date,
        evidenceNodeIds: [UUID] = [],
        externalEvidenceIds: [String] = [],
        lineageId: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.target = target
        self.confidence = (confidence).clamped01()
        self.createdAt = createdAt
        self.evidenceNodeIds = evidenceNodeIds
        self.externalEvidenceIds = externalEvidenceIds
        self.lineageId = lineageId
    }
}

/// Personality lane 1 (2026-10-25): a CARE, something she cares about. One
/// form for what views, opinions, interests and open thoughts each held a
/// piece of: what it is, who it is held with, how deep it runs, what she
/// thinks about it, what is still open, and every time it moved her. Its
/// charge is read from that story, never stored.
public struct CognitiveCare: Sendable, Equatable, Identifiable, Codable {
    /// How deep it runs, which sets how long a feeling about it lasts.
    public enum Depth: String, Sendable, Equatable, Codable, CaseIterable {
        case now, lately, season, life

        public var halfLife: TimeInterval {
            switch self {
            case .now: return 2 * 3_600
            case .lately: return 12 * 3_600
            case .season: return 2 * 86_400
            case .life: return 4 * 86_400
            }
        }
    }

    /// What she thinks or wants about it. A care with a stance is an opinion.
    public struct Stance: Sendable, Equatable, Codable {
        public var text: String
        public var because: String
        public var wouldChangeMind: String

        public init(text: String, because: String, wouldChangeMind: String) {
            self.text = String(text.prefix(CognitiveCare.stanceCharacters))
            self.because = String(because.prefix(CognitiveCare.stanceCharacters))
            self.wouldChangeMind = String(wouldChangeMind.prefix(CognitiveCare.stanceCharacters))
        }
    }

    public enum Mover: String, Sendable, Equatable, Codable, CaseIterable {
        case them, her, world
    }

    public struct DepthChange: Sendable, Equatable, Codable {
        public var from: Depth
        public var to: Depth
        public init(from: Depth, to: Depth) { self.from = from; self.to = to }
    }

    /// One time it moved her: a pointer to what really happened (`source`:
    /// `exchange:<session>/<turn>` or a memory id), never a second copy of it.
    public struct Moment: Sendable, Equatable, Codable {
        public var at: Date
        /// -1...1: away from or toward what she cares about.
        public var moved: Double
        public var by: Mover
        /// The person key when `by` is them.
        public var who: String?
        public var felt: String
        public var note: String
        public var source: String
        public var depthChange: DepthChange?

        public init(at: Date, moved: Double, by: Mover, who: String? = nil, felt: String, note: String,
                    source: String, depthChange: DepthChange? = nil) {
            self.at = at
            self.moved = moved.isFinite ? min(1, max(-1, moved)) : 0
            self.by = by
            self.who = who
            self.felt = String(felt.prefix(CognitiveCare.feltCharacters))
            self.note = String(note.prefix(CognitiveCare.noteCharacters))
            self.source = source
            self.depthChange = depthChange
        }
    }

    /// Movements older than the newest `storyMovements`, folded into one line.
    public struct Folded: Sendable, Equatable, Codable {
        public var count: Int
        public var sumMoved: Double
        public var since: Date
    }

    public enum Origin: Sendable, Equatable, Codable {
        case seed, grown
        case migrated(String)
    }

    public var id: UUID
    public var about: String
    /// Person keys it is held between; empty means hers alone.
    public var with: [String]
    public var depth: Depth
    public var stance: Stance?
    /// The gap: an unanswered question or unfinished thing. nil is settled.
    public var open: String?
    public var story: [Moment]
    public var folded: Folded?
    public var origin: Origin
    public var createdAt: Date
    public var updatedAt: Date
    /// When the night faded it (never moved within its depth's horizon). It
    /// stays in the store and is not shown or read as live; touched again, it
    /// comes back.
    public var fadedAt: Date?

    public static let aboutCharacters = 120
    public static let stanceCharacters = 200
    public static let openCharacters = 200
    public static let noteCharacters = 120
    public static let feltCharacters = 40
    /// The newest movements kept whole; every depth change is always kept.
    public static let storyMovements = 24
    /// The owner's person key.
    public static let ownerKey = "owner"

    public init(id: UUID, about: String, with: [String] = [], depth: Depth, stance: Stance? = nil,
                open: String? = nil, story: [Moment] = [], origin: Origin, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.about = String(about.prefix(Self.aboutCharacters))
        self.with = with
        self.depth = depth
        self.stance = stance
        self.open = open.map { String($0.prefix(Self.openCharacters)) }
        self.story = []
        self.folded = nil
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        for moment in story { record(moment) }
    }

    /// Recent movement, signed, each decayed on this care's clock at read time.
    public func charge(at now: Date) -> Double {
        let halfLife = depth.halfLife
        return story.reduce(0) { sum, moment in
            sum + moment.moved * pow(0.5, max(0, now.timeIntervalSince(moment.at)) / halfLife)
        }
    }

    /// Place one moment in time order (a backdated one goes where it
    /// happened). Past the newest `storyMovements` movements the oldest folds
    /// into `folded`; depth changes never fold.
    public mutating func record(_ moment: Moment) {
        story.insert(moment, at: story.lastIndex(where: { $0.at <= moment.at }).map { $0 + 1 } ?? 0)
        updatedAt = max(updatedAt, moment.at)
        while story.filter({ $0.depthChange == nil }).count > Self.storyMovements,
              let oldest = story.firstIndex(where: { $0.depthChange == nil }) {
            let gone = story.remove(at: oldest)
            folded = Folded(count: (folded?.count ?? 0) + 1, sumMoved: (folded?.sumMoved ?? 0) + gone.moved,
                            since: min(folded?.since ?? gone.at, gone.at))
        }
    }
}

public enum CognitiveDevelopmentalTimelineKind: String, Sendable, Equatable, CaseIterable {
    case dreamEpisode
    case schemaProposal
    /// Read compatibility for developmental timeline rows written by the
    /// retired identity-proposal experiment. No production path emits it.
    case identityProposal
    case proposalResolution
    case replayRun
}

public struct CognitiveDevelopmentalTimelineEvent: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CognitiveDevelopmentalTimelineKind
    public var title: String
    public var summary: String
    public var occurredAt: Date
    public var artifactId: UUID?
    public var lineageId: String
    public var subjectId: String
    public var instanceId: String
    public var forkMetadata: [String: String]
    public var externalEvidenceIds: [String]

    public init(
        id: UUID,
        kind: CognitiveDevelopmentalTimelineKind,
        title: String,
        summary: String,
        occurredAt: Date,
        artifactId: UUID? = nil,
        lineageId: String = "",
        subjectId: String = "",
        instanceId: String = "",
        forkMetadata: [String: String] = [:],
        externalEvidenceIds: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
        self.artifactId = artifactId
        self.lineageId = lineageId
        self.subjectId = subjectId
        self.instanceId = instanceId
        self.forkMetadata = forkMetadata
        self.externalEvidenceIds = externalEvidenceIds
    }
}

public struct CognitiveDreamReplayReference: Sendable, Equatable, Identifiable {
    public var id: String
    public var date: String
    public var filename: String?
    public var content: String
    public var modifiedAt: String?

    public init(
        id: String,
        date: String,
        filename: String? = nil,
        content: String,
        modifiedAt: String? = nil
    ) {
        self.id = id
        self.date = date
        self.filename = filename
        self.content = content
        self.modifiedAt = modifiedAt
    }
}

public struct CognitiveREMProposalReference: Sendable, Equatable, Identifiable {
    public var id: String
    public var target: String
    public var text: String
    public var evidenceDates: [String]
    public var confidence: Double
    public var createdAt: String

    public init(
        id: String,
        target: String,
        text: String,
        evidenceDates: [String],
        confidence: Double,
        createdAt: String
    ) {
        self.id = id
        self.target = target
        self.text = text
        self.evidenceDates = evidenceDates
        self.confidence = (confidence).clamped01()
        self.createdAt = createdAt
    }
}

public struct CognitiveReplayIntegrationInput: Sendable, Equatable {
    public var reason: String
    public var dreamEntries: [CognitiveDreamReplayReference]
    public var remProposals: [CognitiveREMProposalReference]
    /// Evidence the reader could not read, each with its cause: the lists
    /// above are what was read, not the whole past.
    public var unavailableEvidence: [String]

    public init(
        reason: String,
        dreamEntries: [CognitiveDreamReplayReference] = [],
        remProposals: [CognitiveREMProposalReference] = [],
        unavailableEvidence: [String] = []
    ) {
        self.reason = reason
        self.dreamEntries = dreamEntries
        self.remProposals = remProposals
        self.unavailableEvidence = unavailableEvidence
    }
}

public struct CognitiveReplayIntegrationResult: Sendable, Equatable {
    public var episodeIds: [UUID]
    public var schemaProposalIds: [UUID]
    public var skippedEvidenceIds: [String]
    public var timelineEventIds: [UUID]

    public init(
        episodeIds: [UUID] = [],
        schemaProposalIds: [UUID] = [],
        skippedEvidenceIds: [String] = [],
        timelineEventIds: [UUID] = []
    ) {
        self.episodeIds = episodeIds
        self.schemaProposalIds = schemaProposalIds
        self.skippedEvidenceIds = skippedEvidenceIds
        self.timelineEventIds = timelineEventIds
    }
}

/// Material and captured provenance travel together from a committed wake to reflection.
public struct CognitiveReflectionCause: Codable, Sendable, Equatable {
    public var text: String
    public var sourcePeerIds: [String]?
    public var sourceNodeIds: [UUID]
    public var sourceRefs: [String]

    public init(text: String, sourcePeerIds: [String]? = nil, sourceNodeIds: [UUID] = [], sourceRefs: [String] = []) {
        self.text = text
        self.sourcePeerIds = sourcePeerIds
        self.sourceNodeIds = sourceNodeIds
        self.sourceRefs = sourceRefs
    }

    public init(text: String, sources: [String], material: [String: Self]) {
        self.init(text: text,
            sourcePeerIds: sources.isEmpty ? nil : Self.unionPeerIds(sources.map { material[$0]?.sourcePeerIds }),
            sourceRefs: Array(Set(sources + sources.flatMap { material[$0]?.sourceRefs ?? [] })).sorted())
    }

    /// Unknown input provenance stays unknown; selecting citations cannot lower the floor.
    public static func unionPeerIds(_ inputs: [[String]?]) -> [String]? {
        guard inputs.allSatisfy({ $0 != nil }) else { return nil }
        return Array(Set(inputs.flatMap { $0! })).sorted()
    }

}

/// One thinking call owns both the conclusion and its optional felt meaning.
public struct CognitiveReflectionJudgment: Codable, Sendable, Equatable {
    public var reflection: String
    public var affect: Double?
    public var takeaway: String?
    public var sources: [String]

    public func validate(material: [String: CognitiveReflectionCause]) throws {
        guard affect.map({ $0.isFinite && (-1...1).contains($0) }) ?? true,
              takeaway.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 240 }) ?? true,
              Set(sources).isSubset(of: Set(material.keys)),
              takeaway == nil || !sources.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "Invalid reflection judgment: affect must be -1...1 or null; a takeaway must be complete, at most 240 characters, and cite supplied causes."))
        }
    }
}

public struct CognitiveReflectionRequest: Sendable, Equatable {
    public var reservationId: UUID?
    public var reason: String
    public var prompt: String
    public var surface: String
    /// Configuration captured at planning time, not the executed route.
    /// Execution resolves the surface again through checked provider routing.
    public var model: String
    public var provider: String
    public var reasoningEffort: String
    public var requestedAt: Date
    /// The workspace nodes that ACTUALLY fed this prompt, frozen when the
    /// prompt was built. A reflection's care evidence must be this set, not
    /// whatever the workspace holds after the model returns (Astra audit
    /// 2026-09-11, finding 7).
    public var sourceNodeIds: [UUID]
    /// Historical receipt provenance; new requests keep selected causes in `material`.
    public var materialProvenance: String?
    /// Historical quoted lines, retained when decoding older receipts.
    public var sourceExcerpts: [String]
    /// Full peer identities captured with the sources; excerpt labels are presentation only.
    /// Nil means provenance is unknown, including receipts predating this field.
    public var sourcePeerIds: [String]?
    /// Full source material keyed by its canonical reference, frozen for this call.
    public var material: [String: CognitiveReflectionCause]

    public init(
        reservationId: UUID? = nil,
        reason: String,
        prompt: String,
        surface: String = "cognition_reflection",
        model: String = "",
        provider: String = "",
        reasoningEffort: String = "high",
        requestedAt: Date,
        sourceNodeIds: [UUID] = [],
        materialProvenance: String? = nil,
        sourceExcerpts: [String] = [],
        sourcePeerIds: [String]? = nil,
        material: [String: CognitiveReflectionCause] = [:]
    ) {
        self.reservationId = reservationId
        self.reason = reason
        self.prompt = prompt
        self.surface = surface
        self.model = model
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.requestedAt = requestedAt
        self.sourceNodeIds = sourceNodeIds
        self.materialProvenance = materialProvenance
        self.sourceExcerpts = sourceExcerpts
        self.sourcePeerIds = sourcePeerIds
        self.material = material
    }
}

public struct CognitiveReflectionReceipt: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var request: CognitiveReflectionRequest
    public var resultSummary: String
    public var provider: String
    public var createdAt: Date
    public var cancelled: Bool
    public var estimatedPromptTokens: Int
    public var estimatedResultTokens: Int
    public var estimatedCostUnits: Double
    public var proposalYieldScore: Double
    public var proposalIds: [UUID]
    public var judgment: CognitiveReflectionJudgment?

    public init(
        id: UUID,
        request: CognitiveReflectionRequest,
        resultSummary: String,
        provider: String,
        createdAt: Date,
        cancelled: Bool = false,
        estimatedPromptTokens: Int = 0,
        estimatedResultTokens: Int = 0,
        estimatedCostUnits: Double = 0,
        proposalYieldScore: Double = 0,
        proposalIds: [UUID] = [],
        judgment: CognitiveReflectionJudgment? = nil
    ) {
        self.id = id
        self.request = request
        self.resultSummary = resultSummary
        self.provider = provider
        self.createdAt = createdAt
        self.cancelled = cancelled
        self.estimatedPromptTokens = max(0, estimatedPromptTokens)
        self.estimatedResultTokens = max(0, estimatedResultTokens)
        self.estimatedCostUnits = max(0, estimatedCostUnits)
        self.proposalYieldScore = (proposalYieldScore).clamped01()
        self.proposalIds = proposalIds
        self.judgment = judgment
    }
}

public struct CognitiveReceiptRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String
    public var payload: JSONValue
    public var createdAt: Date

    public init(
        id: UUID,
        kind: String,
        payload: JSONValue,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct CognitiveFacultyMeasurement: Sendable, Equatable, Identifiable {
    public var id: String { faculty }
    public var faculty: String
    public var score: Double
    public var evidence: String
    public var generatedAt: Date

    public init(faculty: String, score: Double, evidence: String, generatedAt: Date) {
        self.faculty = faculty
        self.score = (score).clamped01()
        self.evidence = evidence
        self.generatedAt = generatedAt
    }
}

public enum CognitiveExperimentKind: String, Sendable, Equatable, CaseIterable {
    case continuity
    case providerSwap
    case selfModelAccuracy
    case ablation
}

public struct CognitiveExperimentResult: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CognitiveExperimentKind
    public var seed: String
    public var score: Double
    public var metrics: [String: Double]
    public var notes: [String]
    public var reproducibilityKey: String
    public var generatedAt: Date

    public init(
        id: UUID,
        kind: CognitiveExperimentKind,
        seed: String,
        score: Double,
        metrics: [String: Double],
        notes: [String],
        reproducibilityKey: String,
        generatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.seed = seed
        self.score = (score).clamped01()
        self.metrics = metrics
        self.notes = notes
        self.reproducibilityKey = reproducibilityKey
        self.generatedAt = generatedAt
    }
}

public struct CognitiveWelfareBounds: Sendable, Equatable {
    public var withinBounds: Bool
    public var maxAffectValue: Double
    public var reflectionBudgetPressure: Double
    public var notes: [String]
    public var generatedAt: Date

    public init(
        withinBounds: Bool,
        maxAffectValue: Double,
        reflectionBudgetPressure: Double,
        notes: [String],
        generatedAt: Date
    ) {
        self.withinBounds = withinBounds
        self.maxAffectValue = (maxAffectValue).clamped01()
        self.reflectionBudgetPressure = (reflectionBudgetPressure).clamped01()
        self.notes = notes
        self.generatedAt = generatedAt
    }
}

public struct CognitiveObservatorySnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var nodeCount: Int
    public var workspaceCount: Int
    public var episodeCount: Int
    public var reflectionCount: Int
    public var affect: CognitiveAffectState
    public var ablations: [String: Bool]

    public init(
        generatedAt: Date,
        nodeCount: Int,
        workspaceCount: Int,
        episodeCount: Int,
        reflectionCount: Int,
        affect: CognitiveAffectState,
        ablations: [String: Bool]
    ) {
        self.generatedAt = generatedAt
        self.nodeCount = nodeCount
        self.workspaceCount = workspaceCount
        self.episodeCount = episodeCount
        self.reflectionCount = reflectionCount
        self.affect = affect
        self.ablations = ablations
    }
}
