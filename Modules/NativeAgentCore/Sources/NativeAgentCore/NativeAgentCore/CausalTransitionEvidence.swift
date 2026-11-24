import NativeAgentShared
import Foundation

// Blueprint: | `CausalTransitionEvidence.swift` | `CausalInterventionAssignment`: assignment evidence grants no authority; `CausalTransitionEvidence.opaqueIdentity` |

/// Pre-transition assignment distinguishes intervention from later correlation; production observations carry no assignment authority.
public struct CausalInterventionAssignment: Codable, Sendable, Equatable {
    public enum EvidenceClass: String, Codable, Sendable, Equatable {
        case generatedMechanism = "generated_mechanism"
        case frozenControlled = "frozen_controlled"
        case canonicalObserved = "canonical_observed"
        case controlledSynthetic = "controlled_synthetic"
        case controlledProduction = "controlled_production"
    }

    public let assignmentID: String
    public let intervention: String
    public let evidenceClass: EvidenceClass
    /// Missing design metadata stays nil; decoding cannot manufacture causal authority.
    public let experimentID: String?
    public let taskScenarioFamily: String?
    public let treatment: String?
    public let baseline: String?
    public let eligibleAlternatives: [String]?
    public let chosenAlternative: String?
    public let confounderFlags: [String]?
    public let coverageFlags: [String]?
}

public enum CausalTransitionEvidence {
    public static func opaqueIdentity(_ raw: String) -> String {
        SHA256Hex.of(utf8: raw)
    }
}
