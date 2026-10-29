import Foundation
import Experiences
import PersistenceCore

// Blueprint: | `CognitiveReflection.swift` | Captured reflection provenance, judgment, request, receipts and observatory values |
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
        return Array(Set(inputs.compactMap { $0 }.flatMap { $0 })).sorted()
    }
}
/// One thinking call owns both the conclusion and its optional felt meaning.
public struct CognitiveReflectionJudgment: Codable, Sendable, Equatable {
    public var reflection: String
    public var affect: Double?
    public var takeaway: String?
    public var sources: [String]
    /// The care its view or takeaway belongs to: a key it was shown
    /// (`CognitiveReflectionRequest.cares`), or "new". Which care a thought is
    /// about is the reflection's to say, never a cosine's.
    public var care: String?

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
    /// Planning configuration, replaced by the bound checked route before execution and settlement.
    public var model: String
    public var provider: String
    public var reasoningEffort: String
    public var requestedAt: Date
    /// Reflection evidence uses the nodes frozen at prompt construction, never the workspace after the model returns.
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
    /// The cares the call was shown, by key, for naming the one its thought
    /// belongs to. Not persisted: the thought is placed when the call returns.
    public var cares: [CognitiveCareLine]

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
        material: [String: CognitiveReflectionCause] = [:],
        cares: [CognitiveCareLine] = []
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
        self.cares = cares
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
    /// The returned judgment remains available even if its undertone failed to save.
    public var dispositionSaveFailed: Bool

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
        judgment: CognitiveReflectionJudgment? = nil,
        dispositionSaveFailed: Bool = false
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
        self.dispositionSaveFailed = dispositionSaveFailed
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
