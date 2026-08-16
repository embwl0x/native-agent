import Foundation
import PersistenceCore

public protocol CognitiveEventObserving: Sendable {
    func observe(_ event: CognitiveEvent) async
}

public protocol CognitiveContextProviding: Sendable {
    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule?
    /// One fixed-time value for the ordinary turn's cognition/organism seam.
    /// Implementations that own both sides can override this to avoid separate
    /// posture and capsule reads. The value is advisory and owns no authority.
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

    /// Compatibility composition for providers that do not own organism state.
    /// NativeAgent's app runtime overrides this with one fixed-time read.
    public func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitiveTurnProjection {
        let posture = await (self as? any OrganismPostureProviding)?.organismBehaviorPosture()
        let capsule = await prepareCapsule(request)
        return CognitiveTurnProjection(
            fixedAt: capsule?.generatedAt ?? posture?.generatedAt ?? Date(),
            capsule: capsule,
            posture: posture
        )
    }

    public func commitTurnProjection(
        _ projection: CognitiveTurnProjection,
        request: CognitiveCapsuleRequest
    ) async {}
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
    public let predictedToolGroups: Set<String>
    public let memoryActivation: [String: Double]
    public let workingMemoryRecordIDs: Set<String>

    public var isEmpty: Bool {
        terms.isEmpty && unresolvedQuestion == nil && activeTask == nil
            && goal == nil && predictedToolGroups.isEmpty
            && memoryActivation.isEmpty && workingMemoryRecordIDs.isEmpty
    }

    public init(
        terms: [String: Double] = [:],
        unresolvedQuestion: String? = nil,
        activeTask: String? = nil,
        goal: String? = nil,
        predictedToolGroups: Set<String> = [],
        memoryActivation: [String: Double] = [:],
        workingMemoryRecordIDs: Set<String> = []
    ) {
        func bounded(_ text: String, to limit: Int) -> String {
            text.count <= limit ? text : String(text.prefix(limit))
        }
        func clamp(_ value: Double) -> Double { value.clamped01() }
        // Deterministic keep-order under the caps: strongest first, then
        // lexicographic so equal weights can't reshuffle across calls (the
        // packet fingerprint folds these in — nondeterminism would thrash
        // the selection cache).
        func cappedByWeight(_ dict: [String: Double], cap: Int, keyLimit: Int) -> [String: Double] {
            var entries: [(key: String, value: Double)] = dict.map { entry in
                (key: bounded(entry.key, to: keyLimit), value: clamp(entry.value))
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
        self.predictedToolGroups = Set(predictedToolGroups.sorted().prefix(8).map { bounded($0, to: 64) })
        self.memoryActivation = cappedByWeight(memoryActivation, cap: 32, keyLimit: 128)
        self.workingMemoryRecordIDs = Set(workingMemoryRecordIDs.sorted().prefix(16).map { bounded($0, to: 128) })
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
    /// Trusted local teammate bridges may read the current inner-state
    /// projection without allowing their diagnostic traffic to become felt
    /// experience. Event turn-kind filtering remains independent.
    public var allowNonLiveProjection: Bool

    public init(
        surface: String,
        userMessage: String,
        sessionId: String? = nil,
        mode: CognitiveCapsuleMode = .inspectOnly,
        maximumCharacters: Int? = nil,
        organismProjection: OrganismProjection? = nil,
        allowNonLiveProjection: Bool = false
    ) {
        self.surface = surface
        self.userMessage = userMessage
        let trimmedSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionId = trimmedSession?.isEmpty == true ? nil : trimmedSession
        self.mode = mode
        self.maximumCharacters = maximumCharacters
        self.organismProjection = organismProjection
        self.allowNonLiveProjection = allowNonLiveProjection
    }
}

public struct CognitiveCapsule: Sendable, Equatable {
    public var generatedAt: Date
    public var mode: CognitiveCapsuleMode
    public var stableKernel: String
    public var dynamicContext: String
    public var provenanceNodeIds: [UUID]
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
        truncated: Bool
    ) {
        self.generatedAt = generatedAt
        self.mode = mode
        self.stableKernel = stableKernel
        self.dynamicContext = dynamicContext
        self.provenanceNodeIds = provenanceNodeIds
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

    public init(
        capsule: CognitiveCapsule,
        presentationCommit: CognitiveCapsulePresentationCommit? = nil
    ) {
        self.capsule = capsule
        self.presentationCommit = presentationCommit
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

    public init(
        fixedAt: Date,
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?,
        capsulePresentationCommit: CognitiveCapsulePresentationCommit? = nil
    ) {
        self.fixedAt = fixedAt
        self.capsule = capsule
        self.posture = posture
        self.capsulePresentationCommit = capsulePresentationCommit
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
        self.arousal = Self.clamp(arousal)
        self.uncertainty = Self.clamp(uncertainty)
        self.taskPressure = Self.clamp(taskPressure)
        self.socialWarmth = Self.clamp(socialWarmth)
        self.updatedAt = updatedAt
    }

    static func clamp(_ value: Double) -> Double { value.clamped01() }
}

public enum CognitiveThoughtSeedKind: String, Sendable, Equatable, CaseIterable {
    case openQuestion
    case anomaly
    case followUp
    case reflectionTakeaway
}

public struct CognitiveThoughtSeed: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CognitiveThoughtSeedKind
    public var text: String
    public var priority: Double
    public var createdAt: Date
    public var lastUpdatedAt: Date
    public var sourceNodeIds: [UUID]

    public init(
        id: UUID,
        kind: CognitiveThoughtSeedKind,
        text: String,
        priority: Double,
        createdAt: Date,
        lastUpdatedAt: Date,
        sourceNodeIds: [UUID] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.priority = (priority).clamped01()
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.sourceNodeIds = sourceNodeIds
    }
}

public struct CognitiveThoughtSuggestion: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var seedId: UUID
    public var kind: CognitiveThoughtSeedKind
    public var text: String
    public var interruptionScore: Double
    public var priority: Double
    public var createdAt: Date
    public var surface: String
    public var reason: String
    public var sourceNodeIds: [UUID]
    public var workspaceNodeIds: [UUID]

    public init(
        id: UUID,
        seedId: UUID,
        kind: CognitiveThoughtSeedKind,
        text: String,
        interruptionScore: Double,
        priority: Double,
        createdAt: Date,
        surface: String,
        reason: String,
        sourceNodeIds: [UUID] = [],
        workspaceNodeIds: [UUID] = []
    ) {
        self.id = id
        self.seedId = seedId
        self.kind = kind
        self.text = text
        self.interruptionScore = (interruptionScore).clamped01()
        self.priority = (priority).clamped01()
        self.createdAt = createdAt
        self.surface = surface
        self.reason = reason
        self.sourceNodeIds = sourceNodeIds
        self.workspaceNodeIds = workspaceNodeIds
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
}

public struct CognitiveSchemaProposal: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var target: String
    public var status: CognitiveSchemaProposalStatus
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
        status: CognitiveSchemaProposalStatus = .proposed,
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
        self.status = status
        self.confidence = (confidence).clamped01()
        self.createdAt = createdAt
        self.evidenceNodeIds = evidenceNodeIds
        self.externalEvidenceIds = externalEvidenceIds
        self.lineageId = lineageId
    }
}

/// Wave E — a STANDING VIEW: a durable disposition Agent's reflection has settled into
/// (a way she sees something, not a task or a rule). Proposal-shaped: every view enters
/// `.proposed` and only User's `resolveStandingView(approved:)` activates it. Grounded in
/// felt evidence — the mood valence and top felt workspace nodes at formation. Additive.
public struct CognitiveStandingView: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var status: Status
    public var moodValenceAtFormation: Double
    public var evidenceNodeIds: [UUID]
    public var createdAt: Date
    public var updatedAt: Date
    public var lineageId: String

    public enum Status: String, Sendable, Equatable, CaseIterable {
        case proposed, active, retired
    }

    public init(
        id: UUID,
        title: String,
        body: String,
        status: Status = .proposed,
        moodValenceAtFormation: Double,
        evidenceNodeIds: [UUID] = [],
        createdAt: Date,
        updatedAt: Date,
        lineageId: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.moodValenceAtFormation = (moodValenceAtFormation).clampedSigned()
        self.evidenceNodeIds = evidenceNodeIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lineageId = lineageId
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
    public var status: String
    public var confidence: Double
    public var createdAt: String

    public init(
        id: String,
        target: String,
        text: String,
        evidenceDates: [String],
        status: String,
        confidence: Double,
        createdAt: String
    ) {
        self.id = id
        self.target = target
        self.text = text
        self.evidenceDates = evidenceDates
        self.status = status
        self.confidence = (confidence).clamped01()
        self.createdAt = createdAt
    }
}

public struct CognitiveReplayIntegrationInput: Sendable, Equatable {
    public var reason: String
    public var dreamEntries: [CognitiveDreamReplayReference]
    public var remProposals: [CognitiveREMProposalReference]

    public init(
        reason: String,
        dreamEntries: [CognitiveDreamReplayReference] = [],
        remProposals: [CognitiveREMProposalReference] = []
    ) {
        self.reason = reason
        self.dreamEntries = dreamEntries
        self.remProposals = remProposals
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

public struct CognitiveReflectionRequest: Sendable, Equatable {
    public var reservationId: UUID?
    public var reason: String
    public var prompt: String
    public var surface: String
    public var model: String
    public var provider: String
    public var reasoningEffort: String
    public var requestedAt: Date

    public init(
        reservationId: UUID? = nil,
        reason: String,
        prompt: String,
        surface: String = "cognition_reflection",
        model: String = "claude-opus-4-8",
        provider: String = "anthropic_oauth_direct",
        reasoningEffort: String = "high",
        requestedAt: Date
    ) {
        self.reservationId = reservationId
        self.reason = reason
        self.prompt = prompt
        self.surface = surface
        self.model = model
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.requestedAt = requestedAt
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
        proposalIds: [UUID] = []
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
    public var thoughtSeedCount: Int
    public var episodeCount: Int
    public var reflectionCount: Int
    public var affect: CognitiveAffectState
    public var ablations: [String: Bool]

    public init(
        generatedAt: Date,
        nodeCount: Int,
        workspaceCount: Int,
        thoughtSeedCount: Int,
        episodeCount: Int,
        reflectionCount: Int,
        affect: CognitiveAffectState,
        ablations: [String: Bool]
    ) {
        self.generatedAt = generatedAt
        self.nodeCount = nodeCount
        self.workspaceCount = workspaceCount
        self.thoughtSeedCount = thoughtSeedCount
        self.episodeCount = episodeCount
        self.reflectionCount = reflectionCount
        self.affect = affect
        self.ablations = ablations
    }
}
