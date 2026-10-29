import Foundation
import NativeAgentCore
// Blueprint: | `ContextSelectionConfiguration.swift` | Context selector limits, ranking weights and named admission errors |
public enum ContextSelectionError: Error, Equatable, Sendable {
    case invalidCharacterBudget
    case requestedGenerationMismatch(requested: Int64, actual: Int64)
    case snapshotGenerationMismatch(snapshot: Int64, generation: Int64)
    case snapshotFingerprintMismatch
    case invalidConflictResolution(conflictID: String, atomID: ContextAtomID)
    case mandatoryUnavailable([ContextAtomID])
    case mandatoryBudgetExceeded(required: Int, limit: Int)
}
/// Shipped ranking weights have one owner.
public struct ContextScoreWeights: Equatable, Sendable {
    public let lexicalExact: Double = 2.4
    public let tokenOverlap: Double = 1.7
    /// Meaning weighs what the words weigh (exact 2.4 + overlap 1.7), read
    /// from the model's floor (`ContextSelection.score`).
    public let semanticCosine: Double = 4.0
    public let sharedIdentifiers: Double = 1.5
    public let activation: Double = 1.2
    public let authority: Double = 1.0
    public let confidence: Double = 0.8
    public let recency: Double = 0.5
    public let usefulness: Double = 0.7
    public let decay: Double = 0.5
    public let redundancyPenalty: Double = 1.1
    public let characterCostPenaltyCap: Double = 0.35
    /// Message-coverage weight; 0 disables its contribution while scores remain in receipts.
    public let messageCoverage: Double = 1.5
    /// Rank penalty applied while an atom's conflict group is unresolved.
    public let conflictPenalty: Double = 0.12
    /// Rerank bonus for the first atom from a not-yet-selected source.
    public let diversityNewSourceBonus: Double = 0.14
    /// Rerank bonus for the first atom of a not-yet-selected kind.
    public let diversityNewKindBonus: Double = 0.10

    public init() {}
}
public struct ContextSelectionConfiguration: Equatable, Sendable {
    public let maximumCandidates: Int = 256
    public let maximumDynamicAtoms: Int = 12
    public let maximumAtomsPerSource: Int = 2
    public let maximumAtomsPerKind: Int = 4
    /// Kind-specific overrides of `maximumAtomsPerKind`. Memory atoms get a
    /// larger quota by default so high-scoring memories are not crowded out
    /// of the 12-atom dynamic budget by the uniform per-kind cap.
    public let maximumAtomsPerKindOverrides: [ContextAtomKind: Int] = [.memory: 8, .relationship: 4]
    public let minimumRelevance: Double = 0.05
    /// Per embedding model (`model_id`): the cosine that model reads as
    /// unrelated, so `score` can put meaning on the model's own scale (raw bge
    /// cosine bunches every memory between 0.5 and 0.66). With fewer than three
    /// comparable memories, its scaled semantic contribution supplies relevance;
    /// larger populations use relative relevance.
    public let memorySemanticFloors: [String: Double] = ["bge-large-en-v1.5": 0.55]
    /// Effective memory row cap on a message of at most
    /// `shortMessageTokenCount` content tokens — the same token set (and the
    /// boundary) the `messageCoverage` length damp uses, so a message
    /// too short to evidence coverage is also too short to earn a full memory
    /// lane. Applied as `min(cap, shortMessageMemoryRowCap)`.
    public let shortMessageMemoryRowCap: Int = 6
    /// Relevance requires lexical evidence or standing out against the
    /// leave-one-out population (each memory's general pull removed) by two
    /// standard deviations: what the message brings to mind. Fewer than three
    /// comparable vectors use the model-scaled semantic contribution at
    /// `minimumRelevance`. (10-29: a chance bar over memories × readings, about
    /// four deviations at her store's size, let ~0.1 memories a turn through
    /// from 10-27 on; two deviations gave most turns one or two.)
    public static let memoryStandoutDeviations: Double = 2.0
    /// An ambient moment's bar. With her ~70 memories, chance alone puts one or
    /// two past two deviations for any text, so a moment nobody addressed to
    /// her ("could not read: bad_input") surfaced noise (10-29); past three,
    /// chance passes about one memory in ten moments.
    public static let ambientStandoutDeviations: Double = 3.0
    /// REST. A memory served on one of the last `memoryRestTurns` turns is
    /// already in the conversation; it comes again only when it stands out one
    /// deviation more than the bar (`ContextSelector.memoryStandout` + 1), so
    /// nothing rides every turn on a touch that barely clears.
    public let memoryRestTurns: Int = 3
    public let weights: ContextScoreWeights = ContextScoreWeights()

    /// Content-token count at or below which a message counts as short.
    public static let shortMessageTokenCount = 4

    public init() {}

    /// The unrelated-cosine mark for vectors from `modelID`; nil for a model
    /// with no entry (its meaning then scores on the raw cosine).
    public func memorySemanticFloor(forModel modelID: String?) -> Double? {
        modelID.flatMap { memorySemanticFloors[$0] }
    }
    /// Effective per-kind cap: the override for `kind` when present, else the
    /// uniform `maximumAtomsPerKind`.
    public func maximumAtoms(forKind kind: ContextAtomKind) -> Int {
        maximumAtomsPerKindOverrides[kind] ?? maximumAtomsPerKind
    }
}
