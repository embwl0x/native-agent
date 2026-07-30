import CryptoKit
import Foundation
import PersistenceCore

public struct AdaptiveCausalSampleHoldout: Sendable, Equatable {
    public let training: [CausalTransitionEvidence]
    public let holdout: [CausalTransitionEvidence]
    public let invalidTimestampCount: Int
    public let assignmentMechanism: String
}

/// Stable payload-free fallback when a dataset has enough real samples but not
/// seven arbitrary calendar days. It is evaluation-only and grants no causal
/// or production authority to observational rows.
public enum AdaptiveCausalDeterministicSampleHoldoutPolicy {
    public static func split(
        _ transitions: [CausalTransitionEvidence],
        holdoutPercent: Int = 20
    ) -> AdaptiveCausalSampleHoldout {
        let percent = min(50, max(10, holdoutPercent))
        var training: [CausalTransitionEvidence] = []
        var holdout: [CausalTransitionEvidence] = []
        var invalid = 0
        for row in transitions {
            guard parseDate(row.occurredAt) != nil else {
                invalid += 1
                continue
            }
            let bytes = SHA256.hash(data: Data(
                "adaptive-causal-holdout-v1|\(row.domain)|\(row.operationId)".utf8
            ))
            let bucket = Int(bytes.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }) % 100
            if bucket < percent { holdout.append(row) } else { training.append(row) }
        }
        func ordered(_ lhs: CausalTransitionEvidence, _ rhs: CausalTransitionEvidence) -> Bool {
            let left = parseDate(lhs.occurredAt) ?? .distantPast
            let right = parseDate(rhs.occurredAt) ?? .distantPast
            if left != right { return left < right }
            if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
            return lhs.operationId < rhs.operationId
        }
        return AdaptiveCausalSampleHoldout(
            training: training.sorted(by: ordered),
            holdout: holdout.sorted(by: ordered),
            invalidTimestampCount: invalid,
            assignmentMechanism: "sha256_operation_bucket_v1"
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// One payload-free accounting report over canonical historical transitions.
/// It reports what personal evidence actually exists and why a gate is open or
/// closed. It never creates transitions, labels missing outcomes, fits a
/// model, or grants control.
public struct AdaptiveCausalEvidenceAccountingReport: Sendable, Equatable {
    public let transitionCount: Int
    public let domainCounts: [String: Int]
    public let evidenceClassCounts: [CausalTransitionEvidenceClass: Int]
    public let outcomeClassification: CausalOutcomeClassificationReport
    public let holdoutMechanism: String
    public let trainingCount: Int
    public let holdoutCount: Int
    /// For a temporal holdout this is longitudinal drift. For a stable hash
    /// holdout it is only sampled distribution parity; `assessmentKind`
    /// carries that distinction explicitly so a report cannot overclaim.
    public let distributionAssessment: AdaptiveCausalDriftEvaluation
    public let assessmentKind: AdaptiveCausalDistributionAssessmentKind
    public let readiness: AdaptiveCausalLearningReadiness
    public let payloadFree: Bool
    public let controlAuthority: Bool

    public static func evaluate(
        transitions: [CausalTransitionEvidence],
        authoritativeOutcomes: [AuthoritativeTerminalOutcomeEvidence] = [],
        evaluatedAt: Date,
        transitionSchemaVersion: String,
        validatedPrivacyClassificationVersion: String?,
        validatedRollbackArtifactReady: Bool,
        personalTraceLearningApproved: Bool,
        purpose: AdaptiveCausalLearningPurpose = .personalShadowEvaluation
    ) -> Self {
        let dated = transitions.compactMap { row -> Date? in
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: row.occurredAt)
                ?? ISO8601DateFormatter().date(from: row.occurredAt)
        }
        let temporal = AdaptiveCausalTimeHoldoutPolicy.split(transitions)
        let sample = AdaptiveCausalDeterministicSampleHoldoutPolicy.split(transitions)
        let useTemporal = temporal.ready
            && temporal.holdout.count >= AdaptiveCausalLearningGate.minimumSampleHoldoutTransitions
            && temporal.training.count >= AdaptiveCausalDriftEvaluatorMinimum.training
        let training = useTemporal ? temporal.training : sample.training
        let holdout = useTemporal ? temporal.holdout : sample.holdout
        let invalid = useTemporal ? temporal.invalidTimestampCount : sample.invalidTimestampCount
        let assessment = AdaptiveCausalDriftEvaluator.evaluate(
            training: training, holdout: holdout
        )
        let assessmentKind: AdaptiveCausalDistributionAssessmentKind = useTemporal
            ? .temporalLongitudinal : .sampledParity
        let outcomes = CausalTerminalOutcomeClassifier.classify(
            transitions: transitions, authoritative: authoritativeOutcomes
        )
        let controlled = transitions.count { $0.evidenceClass == .controlledProduction }
        let readiness = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: dated.min(),
            lastTransitionAt: dated.max(),
            evaluatedAt: evaluatedAt,
            transitionCount: transitions.count,
            outcomeCompleteCount: outcomes.outcomeCompleteTransitionCount,
            invalidTransitionTimestampCount: invalid,
            transitionSchemaVersion: transitionSchemaVersion,
            privacyClassificationVersion: validatedPrivacyClassificationVersion,
            holdoutDays: useTemporal ? temporal.elapsedHoldoutDays : 0,
            driftDetectionReady: assessment.detectorReady,
            distributionDriftWithinLimit: assessment.withinLimit,
            rollbackArtifactReady: validatedRollbackArtifactReady,
            personalTraceLearningApproved: personalTraceLearningApproved,
            purpose: purpose,
            holdoutTransitionCount: holdout.count,
            controlledProductionTransitionCount: controlled,
            distributionAssessmentKind: assessmentKind
        ))
        return Self(
            transitionCount: transitions.count,
            domainCounts: Dictionary(grouping: transitions, by: \.domain).mapValues(\.count),
            evidenceClassCounts: Dictionary(grouping: transitions, by: \.evidenceClass).mapValues(\.count),
            outcomeClassification: outcomes,
            holdoutMechanism: useTemporal
                ? "latest_utc_days_v1" : sample.assignmentMechanism,
            trainingCount: training.count,
            holdoutCount: holdout.count,
            distributionAssessment: assessment,
            assessmentKind: assessmentKind,
            readiness: readiness,
            payloadFree: true,
            controlAuthority: false
        )
    }
}

private enum AdaptiveCausalDriftEvaluatorMinimum {
    static let training = 30
}
