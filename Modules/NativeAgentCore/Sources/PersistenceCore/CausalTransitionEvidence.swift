import CryptoKit
import Foundation

/// Immutable assignment captured before an observed transition begins.
///
/// This is evidence metadata, not authority. Production observational rows
/// leave it nil. Generated and frozen-mind laboratories may bind it before a
/// reducer runs so later evaluation can distinguish assigned interventions
/// from correlations inferred after the outcome.
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
    /// Additive v2 design metadata. Legacy assignments intentionally decode
    /// with nil values and cannot be upgraded into causal evidence by decode.
    public let experimentID: String?
    public let taskScenarioFamily: String?
    public let treatment: String?
    public let baseline: String?
    public let eligibleAlternatives: [String]?
    public let chosenAlternative: String?
    public let confounderFlags: [String]?
    public let coverageFlags: [String]?

    public init(
        assignmentID: String,
        intervention: String,
        evidenceClass: EvidenceClass,
        experimentID: String? = nil,
        taskScenarioFamily: String? = nil,
        treatment: String? = nil,
        baseline: String? = nil,
        eligibleAlternatives: [String]? = nil,
        chosenAlternative: String? = nil,
        confounderFlags: [String]? = nil,
        coverageFlags: [String]? = nil
    ) {
        self.assignmentID = assignmentID
        self.intervention = intervention
        self.evidenceClass = evidenceClass
        self.experimentID = experimentID
        self.taskScenarioFamily = taskScenarioFamily
        self.treatment = treatment
        self.baseline = baseline
        self.eligibleAlternatives = eligibleAlternatives
        self.chosenAlternative = chosenAlternative
        self.confounderFlags = confounderFlags
        self.coverageFlags = coverageFlags
    }
}

/// Authority class used by the causal model. It is deliberately derived from
/// the immutable pre-outcome assignment rather than inferred from outcomes.
public enum CausalTransitionEvidenceClass: String, Codable, Sendable, Equatable, Hashable {
    case observational
    case controlledSynthetic = "controlled_synthetic"
    case controlledProduction = "controlled_production"
}

/// Small cross-domain read model for offline/shadow causal evaluation.
/// Domain owners remain authoritative; this value cannot mutate or authorize.
public struct CausalTransitionEvidence: Codable, Sendable, Equatable {
    public let domain: String
    public let operationId: String
    public let occurredAt: String
    public let itemIdentity: String
    public let kind: String
    public let beforeState: String?
    public let afterState: String?
    public let expectedNextEvidence: String?
    public let outcome: String

    // Additive v2 trajectory/motor facts. Old v1 JSON rows decode with nil
    // fields and therefore remain observational; no decoder migration can
    // manufacture assignment authority for historical evidence.
    public let trajectoryID: String?
    public let parentOperationID: String?
    public let sequenceNumber: Int?
    public let motorPhase: String?
    public let verificationClass: String?
    public let authorityClass: String?
    public let deadlineClass: String?
    public let terminalClass: String?
    public let completenessClass: String?
    /// Procedure-compilation facts are schema/identity metadata only. Domain
    /// owners must never put parameter values, payloads, paths, or outputs in
    /// these fields. Missing facts remain nil and make compilation abstain.
    public let taskFamily: String?
    public let inputClass: String?
    public let inputInstanceIdentity: String?
    public let parameterSchemaClass: String?
    public let parameterSchemaIdentity: String?
    public let procedureShapeIdentity: String?
    public let actionKind: String?
    public let evidenceKind: String?
    public let checkpointClass: String?
    public let retryClass: String?
    public let retryCount: Int?
    public let cancellationClass: String?
    public let externalEffectClass: String?
    public let latencyMilliseconds: Int?
    public let providerCallCount: Int?
    public let toolCallCount: Int?
    public let providerCostMicros: Int?
    public let toolCostMicros: Int?
    /// Count of frontier orchestration calls that an equivalent declarative
    /// table can remove. This is deliberately distinct from provider calls
    /// still required by an action and must be nil unless an owner proves it.
    public let removableOrchestrationProviderCallCount: Int?
    public let interventionAssignment: CausalInterventionAssignment?

    public init(
        domain: String,
        operationId: String,
        occurredAt: String,
        itemIdentity: String,
        kind: String,
        beforeState: String?,
        afterState: String?,
        expectedNextEvidence: String?,
        outcome: String,
        trajectoryID: String? = nil,
        parentOperationID: String? = nil,
        sequenceNumber: Int? = nil,
        motorPhase: String? = nil,
        verificationClass: String? = nil,
        authorityClass: String? = nil,
        deadlineClass: String? = nil,
        terminalClass: String? = nil,
        completenessClass: String? = nil,
        taskFamily: String? = nil,
        inputClass: String? = nil,
        inputInstanceIdentity: String? = nil,
        parameterSchemaClass: String? = nil,
        parameterSchemaIdentity: String? = nil,
        procedureShapeIdentity: String? = nil,
        actionKind: String? = nil,
        evidenceKind: String? = nil,
        checkpointClass: String? = nil,
        retryClass: String? = nil,
        retryCount: Int? = nil,
        cancellationClass: String? = nil,
        externalEffectClass: String? = nil,
        latencyMilliseconds: Int? = nil,
        providerCallCount: Int? = nil,
        toolCallCount: Int? = nil,
        providerCostMicros: Int? = nil,
        toolCostMicros: Int? = nil,
        removableOrchestrationProviderCallCount: Int? = nil,
        interventionAssignment: CausalInterventionAssignment? = nil
    ) {
        self.domain = domain
        self.operationId = operationId
        self.occurredAt = occurredAt
        self.itemIdentity = itemIdentity
        self.kind = kind
        self.beforeState = beforeState
        self.afterState = afterState
        self.expectedNextEvidence = expectedNextEvidence
        self.outcome = outcome
        self.trajectoryID = trajectoryID
        self.parentOperationID = parentOperationID
        self.sequenceNumber = sequenceNumber
        self.motorPhase = motorPhase
        self.verificationClass = verificationClass
        self.authorityClass = authorityClass
        self.deadlineClass = deadlineClass
        self.terminalClass = terminalClass
        self.completenessClass = completenessClass
        self.taskFamily = taskFamily
        self.inputClass = inputClass
        self.inputInstanceIdentity = inputInstanceIdentity
        self.parameterSchemaClass = parameterSchemaClass
        self.parameterSchemaIdentity = parameterSchemaIdentity
        self.procedureShapeIdentity = procedureShapeIdentity
        self.actionKind = actionKind
        self.evidenceKind = evidenceKind
        self.checkpointClass = checkpointClass
        self.retryClass = retryClass
        self.retryCount = retryCount
        self.cancellationClass = cancellationClass
        self.externalEffectClass = externalEffectClass
        self.latencyMilliseconds = latencyMilliseconds
        self.providerCallCount = providerCallCount
        self.toolCallCount = toolCallCount
        self.providerCostMicros = providerCostMicros
        self.toolCostMicros = toolCostMicros
        self.removableOrchestrationProviderCallCount = removableOrchestrationProviderCallCount
        self.interventionAssignment = interventionAssignment
    }

    /// Historical rows and normal production observations never gain
    /// intervention authority merely because they decode through the v2 type.
    public var evidenceClass: CausalTransitionEvidenceClass {
        guard let assignment = interventionAssignment else { return .observational }
        switch assignment.evidenceClass {
        case .canonicalObserved:
            return .observational
        case .generatedMechanism, .frozenControlled, .controlledSynthetic:
            return .controlledSynthetic
        case .controlledProduction:
            return .controlledProduction
        }
    }

    public var isObservational: Bool { evidenceClass == .observational }

    public static func opaqueIdentity(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
