import Foundation
import Experiences
import PersistenceCore

// Blueprint: | `CognitiveTurnCapsule.swift` | Attention, workspace, prepared capsule and fixed-time turn projections; advisory cognition runtime contract |
public protocol CognitiveRuntimeProviding: Sendable {
    /// Ingest turns without extracting conversational commitments or predictions.
    func observe(_ event: CognitiveEvent) async
    /// One fixed-time value for the ordinary turn's cognition/organism seam.
    /// The value is advisory and owns no authority.
    func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitionAtTurn
    /// Commits presentation bookkeeping at confirmed provider delivery, never preparation.
    func commitTurnProjection(
        _ projection: CognitionAtTurn,
        request: CognitiveCapsuleRequest
    ) async
    /// A bounded, pure attention read for context selection; nil leaves turn preparation unchanged.
    func attentionSignals(at date: Date) async -> CognitiveAttentionSignals?
}
/// What her mind is holding right now, shaped for the context selector.
/// All fields are bounded at CONSTRUCTION so no producer can flood the
/// selector: terms ≤ 16 (64 chars each), tool groups ≤ 8, memory ids ≤ 32;
/// free-text intents ≤ 200 chars. Weights clamp to 0…1.
/// Memory entries carry MEMORY RECORD ids — never context atom ids; the
/// app layer owns the projection's stable-ID derivation.
public struct CognitiveAttentionSignals: Sendable, Equatable {
    // Immutable fields preserve the initializer's bounding contract.
    public let terms: [String: Double]
    public let unresolvedQuestion: String?
    public let completionWindow: CognitiveSubstrate.OpenCompletionRead?
    public let activeTask: String?
    public let goal: String?
    /// Provenance bit for an activeTask/goal supplied by the resident Desk
    /// pursuit overlay. The turn engine keeps this intent out of ordinary
    /// conversation relevance; the Desk context projection remains available
    /// for explicit, query-selected work recall.
    public let residentWorkIntent: Bool
    public let predictedToolGroups: Set<String>
    public let memoryActivation: [String: Double]
    /// Phase 5 B0: memory record id → the signatures she rejected it for
    /// (empty signature: never). ≤ 48 rows, already capped by the owner.
    public let suppressedMemory: [String: [[String]]]

    public var isEmpty: Bool {
        terms.isEmpty && unresolvedQuestion == nil && activeTask == nil
            && goal == nil && predictedToolGroups.isEmpty
            && memoryActivation.isEmpty
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
        completionWindow: CognitiveSubstrate.OpenCompletionRead? = nil,
        activeTask: String? = nil,
        goal: String? = nil,
        residentWorkIntent: Bool = false,
        predictedToolGroups: Set<String> = [],
        memoryActivation: [String: Double] = [:],
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
        self.completionWindow = completionWindow
        self.activeTask = activeTask.map { bounded($0, to: 200) }
        self.goal = goal.map { bounded($0, to: 200) }
        self.residentWorkIntent = residentWorkIntent
        self.predictedToolGroups = Set(predictedToolGroups.sorted().prefix(8).map { bounded($0, to: 64) })
        self.memoryActivation = cappedByWeight(memoryActivation, cap: 32, keyLimit: 128)
        self.suppressedMemory = suppressedMemory
    }
}
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
    public var organismProjection: OrganismReadout?
    /// The caller supplies a payload-free nearest open horizon; absent evidence leaves the forward object silent.
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
        turnKind ?? .live
    }
    public init(
        surface: String,
        userMessage: String,
        sessionId: String? = nil,
        mode: CognitiveCapsuleMode = .inspectOnly,
        maximumCharacters: Int? = nil,
        organismProjection: OrganismReadout? = nil,
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
public struct CognitionAtTurn: Sendable, Equatable {
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
public struct CognitiveAffectState: Codable, Sendable, Equatable {
    public var arousal: Double
    public var uncertainty: Double
    public var taskPressure: Double
    public var socialWarmth: Double
    public var updatedAt: Date
    /// The fold seq of the last lived moment that changed this affect
    /// (docs/SUBCONSCIOUS.md, "Lived moments"). Saved with the axes and their
    /// temporal anchors in the one affect row, so whichever writer saves the
    /// change saves its proof. 0: none (or a row an older binary wrote).
    public var lived: UInt64

    public init(
        arousal: Double = 0,
        uncertainty: Double = 0,
        taskPressure: Double = 0,
        socialWarmth: Double = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        lived: UInt64 = 0
    ) {
        self.arousal = (arousal).clamped01()
        self.uncertainty = (uncertainty).clamped01()
        self.taskPressure = (taskPressure).clamped01()
        self.socialWarmth = (socialWarmth).clamped01()
        self.updatedAt = updatedAt
        self.lived = lived
    }
}
