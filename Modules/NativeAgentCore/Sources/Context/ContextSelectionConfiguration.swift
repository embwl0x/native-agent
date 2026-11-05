import Foundation
import NativeAgentCore
// Blueprint: | `ContextSelectionConfiguration.swift` | Context selector limits, ranking weights and named admission errors |
public enum ContextSelectionError: Error, Equatable, Sendable {
    case invalidCharacterBudget
    case requestedGenerationMismatch(requested: Int64, actual: Int64)
    case snapshotGenerationMismatch(snapshot: Int64, generation: Int64)
    case snapshotFingerprintMismatch
    case mandatoryUnavailable([ContextAtomID])
    case mandatoryBudgetExceeded(required: Int, limit: Int)
}
/// Shipped ranking weights have one owner.
public struct ContextScoreWeights: Equatable, Sendable {
    public let lexicalExact: Double = 2.4
    public let tokenOverlap: Double = 1.7
    /// Scale meaning to lexical weight (exact 2.4 + overlap 1.7) from the model's floor.
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
    /// Zero disables coverage contribution without removing its receipt.
    public let messageCoverage: Double = 1.5
    public let diversityNewSourceBonus: Double = 0.14
    public let diversityNewKindBonus: Double = 0.10

    public init() {}
}
public struct ContextSelectionConfiguration: Equatable, Sendable {
    public let maximumCandidates: Int = 256
    public let maximumDynamicAtoms: Int = 12
    public let maximumAtomsPerSource: Int = 2
    public let maximumAtomsPerKind: Int = 4
    /// Give memory a larger kind quota so the uniform cap cannot crowd high-scoring memories out of the 12-atom budget.
    public let maximumAtomsPerKindOverrides: [ContextAtomKind: Int] = [.memory: 8, .relationship: 4]
    public let minimumRelevance: Double = 0.05
    /// Per-model floors account for compressed cosine ranges. Fewer than three comparable memories use scaled semantics; larger populations use relative
    /// relevance.
    public let memorySemanticFloors: [String: Double] = ["bge-large-en-v1.5": 0.55]
    /// Use the coverage damp's token set and short-message boundary so weak coverage cannot earn a full memory allocation.
    public let shortMessageMemoryRowCap: Int = 6
    /// Require lexical evidence or two leave-one-out deviations after removing general pull. Fewer than three vectors use model-scaled semantics; receipt
    /// populations never change the floor.
    public static let memoryStandoutDeviations: Double = 2.0
    /// Three deviations reduce chance matches for ambient moments to about one memory per ten moments at a population near 70.
    public static let ambientStandoutDeviations: Double = 3.0
    /// Recently served memories are already in conversation; require one extra standout deviation so a marginal touch cannot repeat every turn.
    public let memoryRestTurns: Int = 3
    public let weights: ContextScoreWeights = ContextScoreWeights()

    public static let shortMessageTokenCount = 4

    public init() {}

    /// The unrelated-cosine mark for vectors from `modelID`; nil for a model with no entry (its meaning then scores on the raw cosine).
    public func memorySemanticFloor(forModel modelID: String?) -> Double? {
        modelID.flatMap { memorySemanticFloors[$0] }
    }
    public func maximumAtoms(forKind kind: ContextAtomKind) -> Int {
        maximumAtomsPerKindOverrides[kind] ?? maximumAtomsPerKind
    }
}
