import Foundation
import NativeAgentCore
// Blueprint: | `ContextSelectionReceipt.swift` | Selection degraded sources, budget, index and explicit current receipt evidence |
public struct ContextDegradedSourceNotice: Codable, Equatable, Sendable {
    public let sourceID: ContextSourceID
    public let reason: String

    public init(sourceID: ContextSourceID, reason: String) {
        self.sourceID = sourceID
        self.reason = reason
    }
}
public struct ContextBudgetUsage: Codable, Equatable, Sendable {
    public let characterLimit: Int
    public let usedCharacters: Int
    public let mandatoryCharacters: Int
}
/// Generation-pinned lexical material compiled once for the RAM hot path. The canonical atom remains authoritative; this is rebuildable derived state.
public struct ContextSelectionIndexEntry: Equatable, Sendable {
    public let bodyTokens: Set<String>
    public let searchableTokens: Set<String>
    public let normalizedSearchableText: String
    public let logicalByteCount: Int

    public init(atom: ContextAtomDraft) {
        let metadata = [atom.deterministicSummary].compactMap { $0 }
            + atom.headingPath
            + atom.triggers
            + atom.entities.flatMap { [$0.id, $0.label] }
        let searchableText = ([atom.body] + metadata).joined(separator: " ")
        let bodyTokens = ContextLexicalTokenizer.tokens(atom.body)
        var searchableTokens = bodyTokens
        searchableTokens.formUnion(ContextLexicalTokenizer.tokens(metadata.joined(separator: " ")))
        let normalizedSearchableText = searchableText.lowercased()
        self.bodyTokens = bodyTokens
        self.searchableTokens = searchableTokens
        self.normalizedSearchableText = normalizedSearchableText
        self.logicalByteCount = 64
            + normalizedSearchableText.utf8.count
            + bodyTokens.reduce(0) { $0 + 24 + $1.utf8.count }
            + searchableTokens.subtracting(bodyTokens).reduce(0) { $0 + 24 + $1.utf8.count }
    }
}
/// Live selection measures with the monotonic clock. Other provenance remains decodable for archived receipts and never enters a production latency window.
public enum ContextSelectionLatencyProvenance: String, Codable, Equatable, Sendable {
    case monotonicClock = "monotonic_clock"
    case callerSupplied = "caller_supplied"
    case unavailable
    case invalidCallerSupplied = "invalid_caller_supplied"
}
public struct ContextSelectionReceipt: Equatable, Sendable {
    public let id: String
    public let needFingerprint: String
    public let generationID: Int64
    public let sourceFingerprint: String
    public let selectionTimeBucket: Int64
    public let eligibility: [ContextEligibilityDecision]
    public let candidateScores: [ContextCandidateScore]
    public let selectedAtomIDs: [ContextAtomID]
    public let pointerAtomIDs: [ContextAtomID]
    public let mandatoryAtomIDs: [ContextAtomID]
    public let coveredMandatoryAtomIDs: [ContextAtomID]
    public let mandatoryCoverage: Double
    public let budget: ContextBudgetUsage
    public let degradedSources: [ContextDegradedSourceNotice]
    public let cacheState: ContextSelectionCacheState
    public let measuredSelectionMicroseconds: Int?
    /// Nil is unavailable latency provenance, never zero.
    public let selectionLatencyProvenance: ContextSelectionLatencyProvenance?
    /// Comparable memories × query readings, diagnostic population only; never changes the floor.
    public let memoryPopulation: Int
    public let memoryFloorDroppedCount: Int
    public let memoryRecall: [ContextMemoryRecallScore]
}
extension ContextSelectionReceipt: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, needFingerprint, generationID, sourceFingerprint, selectionTimeBucket
        case eligibility, candidateScores, selectedAtomIDs, pointerAtomIDs
        case mandatoryAtomIDs, coveredMandatoryAtomIDs, mandatoryCoverage
        case budget, degradedSources, cacheState
        case measuredSelectionMicroseconds, selectionLatencyProvenance
        case memoryFloorDroppedCount, memoryRecall, memoryPopulation
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            needFingerprint: try values.decode(String.self, forKey: .needFingerprint),
            generationID: try values.decode(Int64.self, forKey: .generationID),
            sourceFingerprint: try values.decode(String.self, forKey: .sourceFingerprint),
            selectionTimeBucket: try values.decode(Int64.self, forKey: .selectionTimeBucket),
            eligibility: try values.decode([ContextEligibilityDecision].self, forKey: .eligibility),
            candidateScores: try values.decode([ContextCandidateScore].self, forKey: .candidateScores),
            selectedAtomIDs: try values.decode([ContextAtomID].self, forKey: .selectedAtomIDs),
            pointerAtomIDs: try values.decode([ContextAtomID].self, forKey: .pointerAtomIDs),
            mandatoryAtomIDs: try values.decode([ContextAtomID].self, forKey: .mandatoryAtomIDs),
            coveredMandatoryAtomIDs: try values.decode([ContextAtomID].self, forKey: .coveredMandatoryAtomIDs),
            mandatoryCoverage: try values.decode(Double.self, forKey: .mandatoryCoverage),
            budget: try values.decode(ContextBudgetUsage.self, forKey: .budget),
            degradedSources: try values.decode([ContextDegradedSourceNotice].self, forKey: .degradedSources),
            cacheState: try values.decode(ContextSelectionCacheState.self, forKey: .cacheState),
            measuredSelectionMicroseconds: try values.decodeIfPresent(Int.self, forKey: .measuredSelectionMicroseconds),
            selectionLatencyProvenance: try values.decodeIfPresent(
                ContextSelectionLatencyProvenance.self,
                forKey: .selectionLatencyProvenance
            ),
            memoryPopulation: try values.decode(Int.self, forKey: .memoryPopulation),
            memoryFloorDroppedCount: try values.decode(
                Int.self,
                forKey: .memoryFloorDroppedCount
            ),
            memoryRecall: try values.decode(
                [ContextMemoryRecallScore].self,
                forKey: .memoryRecall
            )
        )
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(needFingerprint, forKey: .needFingerprint)
        try values.encode(generationID, forKey: .generationID)
        try values.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try values.encode(selectionTimeBucket, forKey: .selectionTimeBucket)
        try values.encode(eligibility, forKey: .eligibility)
        try values.encode(candidateScores, forKey: .candidateScores)
        try values.encode(selectedAtomIDs, forKey: .selectedAtomIDs)
        try values.encode(pointerAtomIDs, forKey: .pointerAtomIDs)
        try values.encode(mandatoryAtomIDs, forKey: .mandatoryAtomIDs)
        try values.encode(coveredMandatoryAtomIDs, forKey: .coveredMandatoryAtomIDs)
        try values.encode(mandatoryCoverage, forKey: .mandatoryCoverage)
        try values.encode(budget, forKey: .budget)
        try values.encode(degradedSources, forKey: .degradedSources)
        try values.encode(cacheState, forKey: .cacheState)
        try values.encodeIfPresent(measuredSelectionMicroseconds, forKey: .measuredSelectionMicroseconds)
        try values.encodeIfPresent(selectionLatencyProvenance, forKey: .selectionLatencyProvenance)
        try values.encode(memoryFloorDroppedCount, forKey: .memoryFloorDroppedCount)
        try values.encode(memoryRecall, forKey: .memoryRecall)
        try values.encode(memoryPopulation, forKey: .memoryPopulation)
    }
}
/// Separate lexical-only touch from population-relative semantic touch and history-based reachability.
public struct ContextMemoryRecallScore: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    /// Relative relevance, or the model-scaled semantic contribution when fewer than three comparable memories are available.
    public let relevance: Double?
    public let reachability: Double
    public let rested: Bool

    public init(atomID: ContextAtomID, relevance: Double?, reachability: Double, rested: Bool) {
        self.atomID = atomID
        self.relevance = relevance
        self.reachability = reachability
        self.rested = rested
    }
}
