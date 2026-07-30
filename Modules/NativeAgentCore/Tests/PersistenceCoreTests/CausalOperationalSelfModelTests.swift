import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import PersistenceCore

@Suite("Causal operational and self model")
struct CausalOperationalSelfModelTests {
    @Test("generated controlled evidence recovers a known effect and a negative control")
    func generatedKnownEffectRecovery() throws {
        let training = fixture(
            experiment: "known_effect",
            family: "provider_completion",
            treatmentSuccesses: 80,
            baselineSuccesses: 20,
            perArm: 100,
            dayOffset: 0
        ) + fixture(
            experiment: "negative_control",
            family: "negative_control",
            treatmentSuccesses: 50,
            baselineSuccesses: 50,
            perArm: 100,
            dayOffset: 0
        )
        let validation = fixture(
            experiment: "known_effect_validation",
            family: "provider_completion",
            treatmentSuccesses: 40,
            baselineSuccesses: 10,
            perArm: 50,
            dayOffset: 2
        ) + fixture(
            experiment: "negative_control_validation",
            family: "negative_control",
            treatmentSuccesses: 25,
            baselineSuccesses: 25,
            perArm: 50,
            dayOffset: 2
        )
        let first = try CausalOperationalSelfModel.fit(
            training: training,
            validation: validation,
            authorization: .generatedAndFrozen
        )
        let second = try CausalOperationalSelfModel.fit(
            training: training.reversed(),
            validation: validation.reversed(),
            authorization: .generatedAndFrozen
        )

        #expect(first.artifact.modelFingerprintSHA256 == second.artifact.modelFingerprintSHA256)
        #expect(first.artifact.artifactID == second.artifact.artifactID)
        #expect(first.artifact.trainingTransitionIDs.count == 400)
        #expect(first.artifact.validationTransitionIDs.count == 200)
        #expect(first.artifact.controlledEvidenceSources == ["generated_mechanism"])
        #expect(!first.artifact.personalProductionEnabled)
        #expect(!first.artifact.adaptiveInfluenceEnabled)
        #expect(!first.artifact.promptAuthority)
        #expect(!first.artifact.actionAuthority)

        let effect = try #require(first.effect(for: condition(family: "provider_completion")))
        #expect(effect.posteriorRiskDifference > 0.55)
        #expect(effect.lower95 > 0.40)
        #expect(effect.causalClaimEligible)
        #expect(effect.treatmentTransitionIDs.count == 100)
        #expect(effect.baselineTransitionIDs.count == 100)

        let negative = try #require(first.effect(for: condition(family: "negative_control")))
        #expect(abs(negative.posteriorRiskDifference) < 0.01)
        #expect(negative.lower95 < 0)
        #expect(negative.upper95 > 0)

        let prediction = first.predict(
            condition: condition(family: "provider_completion"),
            chosenAlternative: "deep"
        )
        let output = try #require(prediction.output)
        #expect(prediction.covered)
        #expect(output.capabilitySuccess.posteriorMean > 0.78)
        #expect(try #require(output.providerOrToolCompletion).posteriorMean > 0.78)
        #expect(output.correctionOrOverclaim.posteriorMean < 0.22)
        #expect(output.contextRequired.posteriorMean < 0.22)
        #expect(!prediction.promptAuthority)
        #expect(!prediction.actionAuthority)
        #expect(!prediction.permissionAuthority)
        #expect(!prediction.identityAuthority)
        #expect(!prediction.memoryAuthority)
        #expect(!prediction.adaptiveInfluenceAuthority)

        let encoded = try JSONEncoder().encode(first.artifact)
        #expect(try JSONDecoder().decode(CausalOperationalSelfModelArtifact.self, from: encoded)
            == first.artifact)
    }

    @Test("observational rows never contribute to causal effects")
    func observationalRowsExcluded() throws {
        let controlledTraining = fixture(
            experiment: "controlled",
            family: "provider_completion",
            treatmentSuccesses: 16,
            baselineSuccesses: 4,
            perArm: 20,
            dayOffset: 0
        )
        let controlledValidation = fixture(
            experiment: "controlled_validation",
            family: "provider_completion",
            treatmentSuccesses: 16,
            baselineSuccesses: 4,
            perArm: 20,
            dayOffset: 2
        )
        let observational = (0..<1_000).map { index in
            transition(
                experiment: "observed",
                family: "provider_completion",
                arm: "direct",
                success: true,
                index: 10_000 + index,
                dayOffset: 0,
                evidenceClass: nil
            )
        }
        let assignedButObserved = (0..<50).map { index in
            transition(
                experiment: "observed_assignment",
                family: "provider_completion",
                arm: "direct",
                success: true,
                index: 20_000 + index,
                dayOffset: 0,
                evidenceClass: .canonicalObserved
            )
        }

        let model = try CausalOperationalSelfModel.fit(
            training: controlledTraining + observational + assignedButObserved,
            validation: controlledValidation,
            authorization: .generatedAndFrozen,
            configuration: .init(minimumDriftSampleCount: 20)
        )
        let effect = try #require(model.effect(for: condition(family: "provider_completion")))
        #expect(model.artifact.excludedObservationalCount == 1_050)
        #expect(model.artifact.acceptedTrainingCount == 40)
        #expect(effect.baselineProbability.sampleCount == 20)
        #expect(effect.posteriorRiskDifference > 0.50)
        #expect(model.artifact.associationOnlyForObservationalRows)
    }

    @Test("frozen controlled evidence supports calibrated self-knowledge without authority")
    func frozenControlledEvidence() throws {
        let training = fixture(
            experiment: "frozen_train",
            family: "context_requirement",
            treatmentSuccesses: 36,
            baselineSuccesses: 24,
            perArm: 60,
            dayOffset: 0,
            evidenceClass: .frozenControlled
        )
        let validation = fixture(
            experiment: "frozen_validation",
            family: "context_requirement",
            treatmentSuccesses: 18,
            baselineSuccesses: 12,
            perArm: 30,
            dayOffset: 2,
            evidenceClass: .frozenControlled
        )
        let model = try CausalOperationalSelfModel.fit(
            training: training,
            validation: validation,
            authorization: .generatedAndFrozen
        )

        #expect(model.artifact.controlledEvidenceSources == ["frozen_controlled"])
        #expect(model.artifact.calibration.coveredCount == 60)
        #expect(try #require(model.artifact.calibration.brierScore) < 0.26)
        #expect(try #require(model.artifact.calibration.expectedCalibrationError) < 0.05)
        let prediction = model.predict(
            condition: condition(family: "context_requirement"),
            chosenAlternative: "deep"
        )
        #expect(prediction.covered)
        #expect(prediction.advisoryOnly)
        #expect(!prediction.actionAuthority)
    }

    @Test("unseen, weak-support, uncalibrated, and shifted regions abstain")
    func abstentionAndDrift() throws {
        let stableTraining = fixture(
            experiment: "stable_train",
            family: "provider_completion",
            treatmentSuccesses: 24,
            baselineSuccesses: 6,
            perArm: 30,
            dayOffset: 0
        )
        let stableValidation = fixture(
            experiment: "stable_validation",
            family: "provider_completion",
            treatmentSuccesses: 24,
            baselineSuccesses: 6,
            perArm: 30,
            dayOffset: 2
        )
        let stable = try CausalOperationalSelfModel.fit(
            training: stableTraining,
            validation: stableValidation,
            authorization: .generatedAndFrozen
        )
        let unseen = CausalOperationalCondition(
            domain: "provider",
            taskScenarioFamily: "unseen_family",
            beforeState: "ready",
            expectedNextEvidence: "provider_terminal",
            treatment: "deep",
            baseline: "direct"
        )
        #expect(stable.predict(condition: unseen, chosenAlternative: "deep").abstentionReason
            == .unseenCondition)
        #expect(stable.predict(
            condition: condition(family: "provider_completion"),
            chosenAlternative: "unknown"
        ).abstentionReason == .unseenAlternative)

        let weak = try CausalOperationalSelfModel.fit(
            training: fixture(
                experiment: "weak",
                family: "provider_completion",
                treatmentSuccesses: 4,
                baselineSuccesses: 1,
                perArm: 5,
                dayOffset: 0
            ),
            validation: stableValidation,
            authorization: .generatedAndFrozen,
            configuration: .init(minimumArmSupport: 10)
        )
        #expect(weak.predict(
            condition: condition(family: "provider_completion"),
            chosenAlternative: "deep"
        ).abstentionReason == .insufficientSupport)

        let uncalibrated = try CausalOperationalSelfModel.fit(
            training: stableTraining,
            validation: [],
            authorization: .generatedAndFrozen
        )
        #expect(uncalibrated.predict(
            condition: condition(family: "provider_completion"),
            chosenAlternative: "deep"
        ).abstentionReason == .driftEvidenceInsufficient)

        let shiftedValidation = fixture(
            experiment: "shifted_validation",
            family: "provider_completion",
            treatmentSuccesses: 0,
            baselineSuccesses: 0,
            perArm: 30,
            dayOffset: 2
        )
        let shifted = try CausalOperationalSelfModel.fit(
            training: stableTraining,
            validation: shiftedValidation,
            authorization: .generatedAndFrozen
        )
        #expect(shifted.artifact.calibration.drift.status == "shifted")
        #expect(shifted.predict(
            condition: condition(family: "provider_completion"),
            chosenAlternative: "deep"
        ).abstentionReason == .distributionShift)
        #expect(shifted.effect(for: condition(family: "provider_completion"))?.causalClaimEligible == false)
    }

    @Test("invalid assignments and controlled production fail closed")
    func assignmentAndAuthorityBoundaries() throws {
        var invalid = fixture(
            experiment: "invalid",
            family: "provider_completion",
            treatmentSuccesses: 20,
            baselineSuccesses: 5,
            perArm: 25,
            dayOffset: 0
        )
        invalid[0] = transition(
            experiment: "invalid",
            family: "provider_completion",
            arm: "deep",
            success: true,
            index: 99_000,
            dayOffset: 0,
            evidenceClass: .generatedMechanism,
            confounders: ["provider_changed"]
        )
        let validation = fixture(
            experiment: "valid_validation",
            family: "provider_completion",
            treatmentSuccesses: 20,
            baselineSuccesses: 5,
            perArm: 25,
            dayOffset: 2
        )
        let model = try CausalOperationalSelfModel.fit(
            training: invalid,
            validation: validation,
            authorization: .generatedAndFrozen
        )
        #expect(model.artifact.invalidControlledCount == 1)

        let production = transition(
            experiment: "personal_production",
            family: "provider_completion",
            arm: "deep",
            success: true,
            index: 123_456,
            dayOffset: 0,
            evidenceClass: .controlledProduction
        )
        #expect(throws: CausalOperationalSelfModelError.controlledProductionNotAuthorized) {
            _ = try CausalOperationalSelfModel.fit(
                training: [production],
                validation: [],
                authorization: .generatedAndFrozen
            )
        }
        #expect(production.evidenceClass == .controlledProduction)
    }

    private func condition(family: String) -> CausalOperationalCondition {
        CausalOperationalCondition(
            domain: "provider",
            taskScenarioFamily: family,
            beforeState: "ready",
            expectedNextEvidence: "provider_terminal",
            treatment: "deep",
            baseline: "direct"
        )
    }

    private func fixture(
        experiment: String,
        family: String,
        treatmentSuccesses: Int,
        baselineSuccesses: Int,
        perArm: Int,
        dayOffset: Int,
        evidenceClass: CausalInterventionAssignment.EvidenceClass = .generatedMechanism
    ) -> [CausalTransitionEvidence] {
        let treatment = (0..<perArm).map { index in
            transition(
                experiment: experiment,
                family: family,
                arm: "deep",
                success: index < treatmentSuccesses,
                index: stableIndex(experiment, arm: "deep", index: index),
                dayOffset: dayOffset,
                evidenceClass: evidenceClass
            )
        }
        let baseline = (0..<perArm).map { index in
            transition(
                experiment: experiment,
                family: family,
                arm: "direct",
                success: index < baselineSuccesses,
                index: stableIndex(experiment, arm: "direct", index: index),
                dayOffset: dayOffset,
                evidenceClass: evidenceClass
            )
        }
        return treatment + baseline
    }

    private func transition(
        experiment: String,
        family: String,
        arm: String,
        success: Bool,
        index: Int,
        dayOffset: Int,
        evidenceClass: CausalInterventionAssignment.EvidenceClass?,
        confounders: [String] = []
    ) -> CausalTransitionEvidence {
        let raw = "\(experiment)|\(family)|\(arm)|\(index)|\(dayOffset)"
        let assignment = evidenceClass.map {
            CausalInterventionAssignment(
                assignmentID: "assignment_\(index)",
                intervention: "deep",
                evidenceClass: $0,
                experimentID: experiment,
                taskScenarioFamily: family,
                treatment: "deep",
                baseline: "direct",
                eligibleAlternatives: ["deep", "direct"],
                chosenAlternative: arm,
                confounderFlags: confounders,
                coverageFlags: ["complete"]
            )
        }
        let date = Date(timeIntervalSince1970: 1_783_900_800
            + Double(dayOffset * 86_400 + index % 80_000))
        return CausalTransitionEvidence(
            domain: "provider",
            operationId: CausalTransitionEvidence.opaqueIdentity("operation|\(raw)"),
            occurredAt: ISO8601DateFormatter().string(from: date),
            itemIdentity: CausalTransitionEvidence.opaqueIdentity("item|\(raw)"),
            kind: "assigned_provider_call",
            beforeState: "ready",
            afterState: success ? "completed" : "failed",
            expectedNextEvidence: "provider_terminal",
            outcome: success ? "verified_success" : "verified_failure",
            trajectoryID: CausalTransitionEvidence.opaqueIdentity("trajectory|\(raw)"),
            sequenceNumber: index,
            motorPhase: "terminal",
            verificationClass: success ? "verified" : "unverified",
            authorityClass: "test_only",
            deadlineClass: "not_applicable",
            terminalClass: success ? "completed" : "overclaim",
            completenessClass: "complete",
            interventionAssignment: assignment
        )
    }

    private func stableIndex(_ experiment: String, arm: String, index: Int) -> Int {
        let prefix = experiment.utf8.reduce(0) { ($0 * 31 + Int($1)) % 1_000_000 }
        return prefix * 1_000 + (arm == "deep" ? 0 : 500) + index
    }
}
