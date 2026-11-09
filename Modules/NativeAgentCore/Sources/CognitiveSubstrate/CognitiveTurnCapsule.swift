import Foundation
import NativeAgentCore
import Experiences
import PersistenceCore

// Blueprint: | `CognitiveTurnCapsule.swift` | Attention, workspace, prepared capsule and fixed-time turn projections; advisory cognition runtime contract |
public protocol CognitiveRuntimeProviding: Sendable {
    /// Ingest turns without extracting conversational commitments or predictions.
    func observe(_ event: CognitiveEvent) async
    /// One fixed-time value for the ordinary turn's cognition/organism seam. The value is advisory and owns no authority.
    func prepareTurnProjection(_ request: CognitiveCapsuleRequest, turn: Turn) async -> CognitionAtTurn
    /// Commits presentation bookkeeping at confirmed provider delivery, never preparation.
    func commitTurnProjection(
        _ projection: CognitionAtTurn,
        request: CognitiveCapsuleRequest,
        turn: Turn
    ) async
    /// Publish the feeling reference only from completed-reply settlement.
    func commitReplyFeeling(_ projection: CognitionAtTurn, request: CognitiveCapsuleRequest) async
    /// A bounded, pure attention read for context selection; nil leaves turn preparation unchanged.
    func attentionSignals(at date: Date) async -> CognitiveAttentionSignals?
}
/// Construction caps terms (16), tool groups (8), memory ids (32) and text so producers cannot flood selection. Record ids stay native; the app derives atom
/// ids.
public struct CognitiveAttentionSignals: Sendable, Equatable {
    // Immutable fields preserve the initializer's bounding contract.
    public let terms: [String: Double]
    public let unresolvedQuestion: String?
    public let completionWindow: CognitiveSubstrate.OpenCompletionRead?
    public let activeTask: String?
    public let goal: String?
    /// Keep Desk pursuit intent out of ordinary relevance; explicit work queries still reach its context projection.
    public let residentWorkIntent: Bool
    public let predictedToolGroups: Set<String>
    public let memoryActivation: [String: Double]
    /// Carry at most 48 owner-capped memory suppression signatures; an empty signature suppresses every context.
    public let suppressedMemory: [String: [[String]]]

    public var isEmpty: Bool {
        terms.isEmpty && unresolvedQuestion == nil && activeTask == nil
            && goal == nil && predictedToolGroups.isEmpty
            && memoryActivation.isEmpty
            && suppressedMemory.isEmpty
    }
    /// Memory suppression remains specific to this message context.
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
        // Sort strength then lexical identity so equal weights cannot thrash packet fingerprints or selection caches.
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
/// Attention's recorded admission and the saved dream owner's completion within it.
public struct CognitiveSleepDreamReading: Sendable, Equatable {
    public struct Completion: Sendable, Equatable {
        public let id: UUID
        public let occurredAt: Date

        public init(id: UUID, occurredAt: Date) {
            self.id = id
            self.occurredAt = occurredAt
        }
    }

    public let beganAt: Date?
    public let completion: Completion?
    public let failure: String?

    public init(beganAt: Date?, completion: Completion? = nil, failure: String? = nil) {
        self.beganAt = beganAt
        self.completion = completion
        self.failure = failure
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
    /// Trusted local teammate bridges may read the current inner-state projection without allowing their diagnostic traffic to become felt experience. Event
    /// turn-kind filtering remains independent.
    public var allowNonLiveProjection: Bool
    /// Accepted chat provenance, when supplied by the shared turn owner. An unclassified diagnostic read never becomes a live exchange.
    public var turnKind: CognitiveTurnKind?
    /// Only person-started turns across local doors move the conversation-gap boundary; wakes and peer or bridge traffic cannot.
    public var fromUser: Bool
    /// `UserTurnStamp` provides the prior verified user turn; unknown or non-user turns leave it nil.
    public var previousUserTurnAt: Date?
    /// Care speaker identity limits privacy; nil wakes or unidentified senders may press only self-held cares.
    public var speaker: String?
    public var sleepDream: CognitiveSleepDreamReading?

    public var resolvedTurnKind: CognitiveTurnKind {
        turnKind ?? .debug
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
        speaker: String? = nil,
        sleepDream: CognitiveSleepDreamReading? = nil
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
        self.sleepDream = sleepDream
    }
}
/// The full feeling paragraph and the described words that supplied it; subjects and dream prose are not vocabulary.
public struct CognitiveFeelingFrame: Sendable, Equatable {
    public static let header = "How you feel:"
    public let paragraph: String
    public let words: [String]

    public var promptText: String { Self.header + "\n" + paragraph }

    public init(paragraph: String, words: [String]) {
        self.paragraph = paragraph
        self.words = words
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
    /// Present only when the whole paragraph fits the delivered capsule.
    public var feelingFrame: CognitiveFeelingFrame?

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
        sourcePeerIds: [String]? = nil,
        feelingFrame: CognitiveFeelingFrame? = nil
    ) {
        self.generatedAt = generatedAt
        self.mode = mode
        self.stableKernel = stableKernel
        self.dynamicContext = dynamicContext
        self.provenanceNodeIds = provenanceNodeIds
        self.sourcePeerIds = sourcePeerIds
        self.truncated = truncated
        self.feelingFrame = feelingFrame
    }
}
/// Cue presentation commits on context acceptance; the whole feeling frame becomes a reference only at completed-reply settlement.
public struct CognitiveCapsulePresentationCommit: Sendable, Equatable {
    public let mindEpoch: UInt64
    public let fixedAt: Date
    public let expected: CognitiveCapsulePresentationState
    public let next: CognitiveCapsulePresentationState
    public let feelingFrameShown: Bool

    public init(
        mindEpoch: UInt64,
        fixedAt: Date,
        expected: CognitiveCapsulePresentationState,
        next: CognitiveCapsulePresentationState,
        feelingFrameShown: Bool
    ) {
        self.mindEpoch = mindEpoch
        self.fixedAt = fixedAt
        self.expected = expected
        self.next = next
        self.feelingFrameShown = feelingFrameShown
    }
}
public struct CognitivePreparedCapsule: Sendable, Equatable {
    public let capsule: CognitiveCapsule
    public let presentationCommit: CognitiveCapsulePresentationCommit?
    /// Cue explanations reach traces only, never provider prompts.
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
    /// The capsule to inject; an off or zero-budget projection carries no frame.
    public var nonEmptyCapsule: CognitiveCapsule? {
        capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : capsule
    }
}
/// Bounded, immutable turn-scoped composition of the existing cognition and organism owners. This is a read value, not a new state owner or global transaction;
/// effect-time authority remains independently revalidated.
public struct CognitionAtTurn: Sendable, Equatable {
    public let fixedAt: Date
    public let capsule: CognitiveCapsule?
    public let posture: OrganismBehaviorPosture?
    public let capsulePresentationCommit: CognitiveCapsulePresentationCommit?
    /// Trace `mind.why` only after delivery so previews cannot claim a cue was read.
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
    /// Save the lived fold seq with affect axes and anchors so every writer retains the mutation's proof; zero carries no watermark.
    public var lived: UInt64
    public var chosenRegister: CognitiveChosenRegister?

    public init(
        arousal: Double = 0,
        uncertainty: Double = 0,
        taskPressure: Double = 0,
        socialWarmth: Double = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        lived: UInt64 = 0,
        chosenRegister: CognitiveChosenRegister? = nil
    ) {
        self.arousal = (arousal).clamped01()
        self.uncertainty = (uncertainty).clamped01()
        self.taskPressure = (taskPressure).clamped01()
        self.socialWarmth = (socialWarmth).clamped01()
        self.updatedAt = updatedAt
        self.lived = lived
        self.chosenRegister = chosenRegister
    }
}
