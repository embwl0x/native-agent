import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import PersistenceCore

@Suite("Adaptive causal learning gate")
struct AdaptiveCausalLearningGateTests {
    @Test("fresh traces cannot authorize shadow training")
    func freshEvidenceFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 25,
            outcomeCompleteCount: 12,
            transitionSchemaVersion: nil,
            privacyClassificationVersion: nil,
            holdoutDays: 0,
            driftDetectionReady: false,
            rollbackArtifactReady: false,
            personalTraceLearningApproved: false
        ))
        #expect(!result.readyForShadowTraining)
        #expect(Set(result.blockers) == [
            .insufficientObservationWindow, .insufficientTransitions, .incompleteOutcomes,
            .missingSchemaVersion, .missingPrivacyClassification, .insufficientHoldout,
            .driftDetectionMissing, .rollbackMissing, .userApprovalMissing,
        ])
        #expect(result.observationDays == 1)
        #expect(result.transitionCount == 25)
        #expect(result.outcomeCompleteCount == 12)
        #expect(result.outcomeCoverage == 0.48)
        #expect(result.observationDaysRemaining == 20)
        #expect(result.transitionsRemaining == 475)
        #expect(result.holdoutDaysRemaining == 7)
    }

    @Test("complete longitudinal evidence permits shadow training only")
    func completeEvidencePasses() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-28 * 86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 1_000,
            outcomeCompleteCount: 950,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 7,
            driftDetectionReady: true,
            distributionDriftWithinLimit: true,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: true
        ))
        #expect(result.readyForShadowTraining)
        #expect(result.blockers.isEmpty)
        #expect(result.observationDays == 28)
        #expect(result.outcomeCoverage == 0.95)
        #expect(result.observationDaysRemaining == 0)
        #expect(result.transitionsRemaining == 0)
        #expect(result.holdoutDaysRemaining == 0)
    }

    @Test("non-approval readiness is distinct from authenticated user authority")
    func readyExceptForApproval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-28 * 86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 1_000,
            outcomeCompleteCount: 950,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 7,
            driftDetectionReady: true,
            distributionDriftWithinLimit: true,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: false
        ))
        #expect(!result.readyForShadowTraining)
        #expect(result.blockers == [.userApprovalMissing])
        #expect(result.satisfiesAllNonApprovalRequirements)
    }

    @Test("outcome counts cannot exceed transition reality")
    func impossibleCoverageFails() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-28 * 86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 500,
            outcomeCompleteCount: 501,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 7,
            driftDetectionReady: true,
            distributionDriftWithinLimit: true,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: true
        ))
        #expect(!result.readyForShadowTraining)
        #expect(result.blockers == [.incompleteOutcomes])
    }

    @Test("detected distribution shift blocks shadow training")
    func driftBlocks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-28 * 86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 500,
            outcomeCompleteCount: 500,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 7,
            driftDetectionReady: true,
            distributionDriftWithinLimit: false,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: true
        ))
        #expect(!result.readyForShadowTraining)
        #expect(result.blockers == [.distributionDriftDetected])
    }

    @Test("invalid timestamps fail closed even when aggregate counts pass")
    func invalidTimestampsBlock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-28 * 86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 500,
            outcomeCompleteCount: 500,
            invalidTransitionTimestampCount: 1,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 7,
            driftDetectionReady: true,
            distributionDriftWithinLimit: true,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: true
        ))
        #expect(result.blockers == [.invalidTransitionTimestamps])
    }

    @Test("stale or future-dated evidence fails closed")
    func staleEvidenceBlocks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func evaluate(last: Date) -> AdaptiveCausalLearningReadiness {
            AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
                firstTransitionAt: now.addingTimeInterval(-28 * 86_400),
                lastTransitionAt: last,
                evaluatedAt: now,
                transitionCount: 500,
                outcomeCompleteCount: 500,
                transitionSchemaVersion: "causal.transition.v1",
                privacyClassificationVersion: "privacy.v1",
                holdoutDays: 7,
                driftDetectionReady: true,
                distributionDriftWithinLimit: true,
                rollbackArtifactReady: true,
                personalTraceLearningApproved: true
            ))
        }

        #expect(evaluate(last: now.addingTimeInterval(-4 * 86_400)).blockers == [.staleEvidence])
        #expect(evaluate(last: now.addingTimeInterval(60)).blockers.contains(.staleEvidence))
    }

    @Test("sample sufficiency replaces calendar waiting for read-only evaluation")
    func sampleSufficientShadowEvaluation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 200,
            outcomeCompleteCount: 190,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 0,
            driftDetectionReady: true,
            distributionDriftWithinLimit: true,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: true,
            holdoutTransitionCount: 30,
            distributionAssessmentKind: .sampledParity
        ))
        #expect(result.readyForShadowTraining)
        #expect(result.sampleSufficiencyUsed)
        #expect(result.distributionAssessmentKind == .sampledParity)
    }

    @Test("sample parity cannot authorize adaptive production influence")
    func sampleParityCannotPromoteControl() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: now.addingTimeInterval(-86_400),
            lastTransitionAt: now,
            evaluatedAt: now,
            transitionCount: 600,
            outcomeCompleteCount: 590,
            transitionSchemaVersion: "causal.transition.v1",
            privacyClassificationVersion: "privacy.v1",
            holdoutDays: 0,
            driftDetectionReady: true,
            distributionDriftWithinLimit: true,
            rollbackArtifactReady: true,
            personalTraceLearningApproved: true,
            purpose: .adaptiveControlPromotion,
            holdoutTransitionCount: 100,
            controlledProductionTransitionCount: 600,
            distributionAssessmentKind: .sampledParity
        ))
        #expect(!result.readyForShadowTraining)
        #expect(result.blockers == [.longitudinalDriftEvidenceMissing])
    }

    @Test("personal evidence accounting reports sampled parity without inventing drift or control")
    func personalEvidenceAccounting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        let rows = (0..<250).map { index in
            CausalTransitionEvidence(
                domain: "github_command",
                operationId: CausalTransitionEvidence.opaqueIdentity("operation-\(index)"),
                occurredAt: formatter.string(from: now.addingTimeInterval(Double(index))),
                itemIdentity: CausalTransitionEvidence.opaqueIdentity("item-\(index)"),
                kind: "settled",
                beforeState: "verifying",
                afterState: "resolved",
                expectedNextEvidence: nil,
                outcome: "state_changed"
            )
        }
        let report = AdaptiveCausalEvidenceAccountingReport.evaluate(
            transitions: rows,
            evaluatedAt: now.addingTimeInterval(250),
            transitionSchemaVersion: "causal.transition.v1",
            validatedPrivacyClassificationVersion: "privacy.v1",
            validatedRollbackArtifactReady: true,
            personalTraceLearningApproved: false
        )
        #expect(report.transitionCount == 250)
        #expect(report.outcomeClassification.outcomeCoverage == 1)
        #expect(report.assessmentKind == .sampledParity)
        #expect(report.distributionAssessment.status == .withinLimit)
        #expect(report.holdoutMechanism == "sha256_operation_bucket_v1")
        #expect(report.readiness.blockers == [.userApprovalMissing])
        #expect(report.readiness.sampleSufficiencyUsed)
        #expect(report.payloadFree)
        #expect(!report.controlAuthority)
    }
}
