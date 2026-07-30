import Foundation
import PersistenceCore

public enum AdaptiveCausalLearningPurpose: String, Sendable, Equatable {
    /// Read-only personal model fitting/evaluation. It grants no live control.
    case personalShadowEvaluation = "personal_shadow_evaluation"
    /// A later production influence gate. This requires pre-outcome controlled
    /// production assignments in addition to ordinary readiness evidence.
    case adaptiveControlPromotion = "adaptive_control_promotion"
}

public enum AdaptiveCausalDistributionAssessmentKind: String, Sendable, Equatable {
    /// A later time window was compared with an earlier time window. This is
    /// the only assessment that may satisfy the longitudinal-drift condition
    /// for a production influence gate.
    case temporalLongitudinal = "temporal_longitudinal"
    /// A stable hash split compared two contemporaneous sample populations.
    /// Useful for read-only evaluation, but it is distribution parity rather
    /// than evidence about behavior over time.
    case sampledParity = "sampled_parity"
}

/// Evidence required before any personal-trace model may move beyond shadow
/// evaluation. This value is supplied by an explicit offline review; it is not
/// inferred from chat, organism state, or model prose.
public struct AdaptiveCausalLearningEvidence: Sendable, Equatable {
    public let firstTransitionAt: Date?
    public let lastTransitionAt: Date?
    public let evaluatedAt: Date
    public let transitionCount: Int
    public let outcomeCompleteCount: Int
    public let invalidTransitionTimestampCount: Int
    public let transitionSchemaVersion: String?
    public let privacyClassificationVersion: String?
    public let holdoutDays: Int
    public let driftDetectionReady: Bool
    public let distributionDriftWithinLimit: Bool
    public let rollbackArtifactReady: Bool
    public let personalTraceLearningApproved: Bool
    public let purpose: AdaptiveCausalLearningPurpose
    public let holdoutTransitionCount: Int
    public let controlledProductionTransitionCount: Int
    public let distributionAssessmentKind: AdaptiveCausalDistributionAssessmentKind

    public init(
        firstTransitionAt: Date?,
        lastTransitionAt: Date?,
        evaluatedAt: Date,
        transitionCount: Int,
        outcomeCompleteCount: Int,
        invalidTransitionTimestampCount: Int = 0,
        transitionSchemaVersion: String?,
        privacyClassificationVersion: String?,
        holdoutDays: Int,
        driftDetectionReady: Bool,
        distributionDriftWithinLimit: Bool = false,
        rollbackArtifactReady: Bool,
        personalTraceLearningApproved: Bool,
        purpose: AdaptiveCausalLearningPurpose = .personalShadowEvaluation,
        holdoutTransitionCount: Int = 0,
        controlledProductionTransitionCount: Int = 0,
        distributionAssessmentKind: AdaptiveCausalDistributionAssessmentKind = .temporalLongitudinal
    ) {
        self.firstTransitionAt = firstTransitionAt
        self.lastTransitionAt = lastTransitionAt
        self.evaluatedAt = evaluatedAt
        self.transitionCount = max(0, transitionCount)
        self.outcomeCompleteCount = max(0, outcomeCompleteCount)
        self.invalidTransitionTimestampCount = max(0, invalidTransitionTimestampCount)
        self.transitionSchemaVersion = transitionSchemaVersion
        self.privacyClassificationVersion = privacyClassificationVersion
        self.holdoutDays = max(0, holdoutDays)
        self.driftDetectionReady = driftDetectionReady
        self.distributionDriftWithinLimit = distributionDriftWithinLimit
        self.rollbackArtifactReady = rollbackArtifactReady
        self.personalTraceLearningApproved = personalTraceLearningApproved
        self.purpose = purpose
        self.holdoutTransitionCount = max(0, holdoutTransitionCount)
        self.controlledProductionTransitionCount = max(0, controlledProductionTransitionCount)
        self.distributionAssessmentKind = distributionAssessmentKind
    }
}

public enum AdaptiveCausalLearningBlocker: String, Sendable, Equatable, CaseIterable {
    case insufficientObservationWindow = "insufficient_observation_window"
    case insufficientTransitions = "insufficient_transitions"
    case incompleteOutcomes = "incomplete_outcomes"
    case invalidTransitionTimestamps = "invalid_transition_timestamps"
    case staleEvidence = "stale_evidence"
    case missingSchemaVersion = "missing_schema_version"
    case missingPrivacyClassification = "missing_privacy_classification"
    case insufficientHoldout = "insufficient_holdout"
    case driftDetectionMissing = "drift_detection_missing"
    case distributionDriftDetected = "distribution_drift_detected"
    case rollbackMissing = "rollback_missing"
    case userApprovalMissing = "user_approval_missing"
    case insufficientControlledProductionEvidence = "insufficient_controlled_production_evidence"
    case longitudinalDriftEvidenceMissing = "longitudinal_drift_evidence_missing"
}

public struct AdaptiveCausalLearningReadiness: Sendable, Equatable {
    public let readyForShadowTraining: Bool
    public let blockers: [AdaptiveCausalLearningBlocker]
    /// Exact, non-authorizing measurements for a readiness report. These do
    /// not infer approval, privacy classification, drift safety, or rollback
    /// readiness from runtime traces.
    public let observationDays: Double
    public let transitionCount: Int
    public let outcomeCompleteCount: Int
    public let outcomeCoverage: Double
    public let observationDaysRemaining: Double
    public let transitionsRemaining: Int
    public let holdoutDaysRemaining: Int
    public let lastEvidenceAgeDays: Double?
    public let purpose: AdaptiveCausalLearningPurpose
    public let holdoutTransitionCount: Int
    public let controlledProductionTransitionCount: Int
    public let sampleSufficiencyUsed: Bool
    public let distributionAssessmentKind: AdaptiveCausalDistributionAssessmentKind

    /// True only when every mechanical/privacy/holdout/rollback requirement
    /// passes. The missing user-approval row may remain because the canonical
    /// ApprovalInbox receipt is validated separately at the authorization
    /// boundary; a Boolean inside this value is never sufficient authority.
    public var satisfiesAllNonApprovalRequirements: Bool {
        blockers.allSatisfy { $0 == .userApprovalMissing }
    }
}

/// Fail-closed policy for Wave 6. Passing this gate permits only an immutable
/// local shadow model evaluation; it grants no runtime control or authority.
public enum AdaptiveCausalLearningGate {
    public static let minimumObservationDays = 21
    public static let minimumTransitions = 500
    public static let minimumOutcomeCoverage = 0.90
    public static let minimumHoldoutDays = 7
    public static let maximumLastEvidenceAgeDays = 3.0
    /// Sample support may replace arbitrary elapsed-calendar waits for a
    /// shadow-only evaluation. The holdout remains deterministic and drift,
    /// privacy, rollback, freshness, and exact local approval still fail shut.
    public static let minimumSampleSufficientTransitions = 200
    public static let minimumSampleHoldoutTransitions = 30
    public static let minimumControlledProductionTransitions = 500

    public static func evaluate(
        _ evidence: AdaptiveCausalLearningEvidence
    ) -> AdaptiveCausalLearningReadiness {
        var blockers: [AdaptiveCausalLearningBlocker] = []
        let observationDays: Double = {
            guard let first = evidence.firstTransitionAt,
                  let last = evidence.lastTransitionAt,
                  last >= first else { return 0 }
            return last.timeIntervalSince(first) / 86_400
        }()
        let sampleSufficient = evidence.transitionCount >= minimumSampleSufficientTransitions
            && evidence.holdoutTransitionCount >= minimumSampleHoldoutTransitions
        if !sampleSufficient && observationDays < Double(minimumObservationDays) {
            blockers.append(.insufficientObservationWindow)
        }
        let requiredTransitions = sampleSufficient
            ? minimumSampleSufficientTransitions : minimumTransitions
        if evidence.transitionCount < requiredTransitions {
            blockers.append(.insufficientTransitions)
        }
        let coverage = evidence.transitionCount > 0
            ? Double(evidence.outcomeCompleteCount) / Double(evidence.transitionCount)
            : 0
        if coverage < minimumOutcomeCoverage || evidence.outcomeCompleteCount > evidence.transitionCount {
            blockers.append(.incompleteOutcomes)
        }
        if evidence.invalidTransitionTimestampCount > 0 {
            blockers.append(.invalidTransitionTimestamps)
        }
        let lastEvidenceAgeDays: Double? = evidence.lastTransitionAt.map {
            evidence.evaluatedAt.timeIntervalSince($0) / 86_400
        }
        if lastEvidenceAgeDays == nil
            || lastEvidenceAgeDays! < 0
            || lastEvidenceAgeDays! > maximumLastEvidenceAgeDays {
            blockers.append(.staleEvidence)
        }
        if evidence.transitionSchemaVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            blockers.append(.missingSchemaVersion)
        }
        if evidence.privacyClassificationVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            blockers.append(.missingPrivacyClassification)
        }
        if evidence.holdoutTransitionCount < minimumSampleHoldoutTransitions
            && evidence.holdoutDays < minimumHoldoutDays {
            blockers.append(.insufficientHoldout)
        }
        if !evidence.driftDetectionReady { blockers.append(.driftDetectionMissing) }
        if evidence.driftDetectionReady && !evidence.distributionDriftWithinLimit {
            blockers.append(.distributionDriftDetected)
        }
        if !evidence.rollbackArtifactReady { blockers.append(.rollbackMissing) }
        if !evidence.personalTraceLearningApproved { blockers.append(.userApprovalMissing) }
        if evidence.purpose == .adaptiveControlPromotion,
           evidence.controlledProductionTransitionCount < minimumControlledProductionTransitions {
            blockers.append(.insufficientControlledProductionEvidence)
        }
        if evidence.purpose == .adaptiveControlPromotion,
           evidence.distributionAssessmentKind != .temporalLongitudinal {
            blockers.append(.longitudinalDriftEvidenceMissing)
        }
        return AdaptiveCausalLearningReadiness(
            readyForShadowTraining: blockers.isEmpty,
            blockers: blockers,
            observationDays: observationDays,
            transitionCount: evidence.transitionCount,
            outcomeCompleteCount: evidence.outcomeCompleteCount,
            outcomeCoverage: coverage,
            observationDaysRemaining: sampleSufficient
                ? 0 : max(0, Double(minimumObservationDays) - observationDays),
            transitionsRemaining: max(0, requiredTransitions - evidence.transitionCount),
            holdoutDaysRemaining: evidence.holdoutTransitionCount >= minimumSampleHoldoutTransitions
                ? 0 : max(0, minimumHoldoutDays - evidence.holdoutDays),
            lastEvidenceAgeDays: lastEvidenceAgeDays,
            purpose: evidence.purpose,
            holdoutTransitionCount: evidence.holdoutTransitionCount,
            controlledProductionTransitionCount: evidence.controlledProductionTransitionCount,
            sampleSufficiencyUsed: sampleSufficient,
            distributionAssessmentKind: evidence.distributionAssessmentKind
        )
    }
}
