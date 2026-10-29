import Foundation
import NativeAgentCore
// Blueprint: | `ContextCandidateScore.swift` | Context eligibility decisions and candidate scoring values with their existing codecs |
public enum ContextEligibilityReason: String, Codable, Sendable {
    case missingSource = "missing_source"
    case generationMismatch = "generation_mismatch"
    case deleted
    case tombstoned
    case sourceRemoved = "source_removed"
    case originDenied = "origin_denied"
    case permissionDenied = "permission_denied"
    case surfaceDenied = "surface_denied"
    case privacyDenied = "privacy_denied"
    case neverInject = "never_inject"
    case outsideContextScope = "outside_context_scope"
    case expired
    case staleRuntime = "stale_runtime"
    case secretBearing = "secret_bearing"
    case supersededByConflictResolution = "superseded_by_conflict_resolution"
}
public struct ContextEligibilityDecision: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let eligible: Bool
    public let exclusionReason: ContextEligibilityReason?

    public init(
        atomID: ContextAtomID,
        eligible: Bool,
        exclusionReason: ContextEligibilityReason? = nil
    ) {
        self.atomID = atomID
        self.eligible = eligible
        self.exclusionReason = exclusionReason
    }
}
public struct ContextCandidateScoreFeatures: Codable, Equatable, Sendable {
    public let lexicalExact: Double
    public let tokenOverlap: Double
    public let semanticCosine: Double
    public let sharedIdentifiers: Double
    public let activation: Double
    public let authority: Double
    public let confidence: Double
    public let recency: Double
    public let usefulness: Double
    public let decay: Double
    /// Share of current message tokens covered (0…1); a missing receipt key decodes as 0.
    public let messageCoverage: Double
    public internal(set) var diversityBonus: Double
    public internal(set) var redundancyPenalty: Double
    public let conflictPenalty: Double
    public let characterCostPenalty: Double
    public internal(set) var total: Double
}
extension ContextCandidateScoreFeatures {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lexicalExact = try c.decode(Double.self, forKey: .lexicalExact)
        tokenOverlap = try c.decode(Double.self, forKey: .tokenOverlap)
        semanticCosine = try c.decode(Double.self, forKey: .semanticCosine)
        sharedIdentifiers = try c.decode(Double.self, forKey: .sharedIdentifiers)
        activation = try c.decode(Double.self, forKey: .activation)
        authority = try c.decode(Double.self, forKey: .authority)
        confidence = try c.decode(Double.self, forKey: .confidence)
        recency = try c.decode(Double.self, forKey: .recency)
        usefulness = try c.decode(Double.self, forKey: .usefulness)
        decay = try c.decode(Double.self, forKey: .decay)
        messageCoverage = try c.decodeIfPresent(Double.self, forKey: .messageCoverage) ?? 0
        diversityBonus = try c.decode(Double.self, forKey: .diversityBonus)
        redundancyPenalty = try c.decode(Double.self, forKey: .redundancyPenalty)
        conflictPenalty = try c.decode(Double.self, forKey: .conflictPenalty)
        characterCostPenalty = try c.decode(Double.self, forKey: .characterCostPenalty)
        total = try c.decode(Double.self, forKey: .total)
    }
}
public struct ContextCandidateScore: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let features: ContextCandidateScoreFeatures
    public let selectionOrdinal: Int?
}
