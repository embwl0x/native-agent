import Testing
@testable import PersistenceCore

@Suite("Synthetic causal frontier simulation")
struct SyntheticCausalFrontierSimulationTests {
    @Test("stable operational holdout is covered, accurate, and calibrated")
    func stableHoldout() throws {
        let report = SyntheticCausalFrontierSimulation.run()

        #expect(report.schema == "synthetic-causal-frontier-report.v1")
        #expect(report.trainingCount == 1_000)
        #expect(report.learnedRuleCount == 10)
        #expect(report.personalTraceCount == 0)
        #expect(report.shadowOnly)
        #expect(!report.controlAuthority)
        #expect(!report.approvalInferred)

        #expect(report.stable.evaluationCount == 300)
        #expect(report.stable.coverage == 1)
        #expect(try #require(report.stable.accuracy) >= 0.90)
        #expect(try #require(report.stable.meanLogLoss) < 0.35)
        #expect(try #require(report.stable.expectedCalibrationError) < 0.02)
        #expect(report.stable.drift.status == .withinLimit)
    }

    @Test("controlled counterfactual interventions change predicted futures")
    func counterfactualInterventions() throws {
        let report = SyntheticCausalFrontierSimulation.run().counterfactual

        #expect(report.evaluationCount == 180)
        #expect(report.coverage == 1)
        #expect(report.counterfactualComparisonCount == 90)
        #expect(report.interventionSensitiveComparisonCount == 90)
        #expect(try #require(report.interventionSensitivityRate) == 1)
        #expect(try #require(report.accuracy) == 1)
    }

    @Test("unknown conditions abstain and outcome shift is surfaced")
    func shiftAndAbstention() throws {
        let report = SyntheticCausalFrontierSimulation.run().shifted

        #expect(report.evaluationCount == 400)
        #expect(report.coveredCount == 300)
        #expect(report.abstainedCount == 100)
        #expect(report.unseenConditionCount == 100)
        #expect(report.insufficientConfidenceCount == 0)
        #expect(report.coverage == 0.75)
        #expect(try #require(report.accuracy) == 0)
        #expect(try #require(report.meanLogLoss) > 1.5)
        #expect(report.drift.status == .shifted)
        #expect(!report.drift.withinLimit)
    }

    @Test("simulation is byte-for-byte deterministic at the value boundary")
    func deterministic() {
        #expect(SyntheticCausalFrontierSimulation.run() == SyntheticCausalFrontierSimulation.run())
    }

    @Test("ambiguous and unseen conditions abstain instead of inventing confidence")
    func modelAbstention() {
        let ambiguousFeature = SyntheticCausalFeature(
            domain: "fixture",
            priorState: "ready",
            intervention: "choose",
            expectedEvidence: "result"
        )
        let one = SyntheticCausalTarget(nextState: "left", outcome: "observed")
        let two = SyntheticCausalTarget(nextState: "right", outcome: "observed")
        func example(_ target: SyntheticCausalTarget, _ index: Int) -> SyntheticCausalExample {
            SyntheticCausalExample(
                feature: ambiguousFeature,
                target: target,
                evidence: CausalTransitionEvidence(
                    domain: "fixture",
                    operationId: CausalTransitionEvidence.opaqueIdentity("operation-\(index)"),
                    occurredAt: "2026-07-01T12:00:00Z",
                    itemIdentity: CausalTransitionEvidence.opaqueIdentity("item-\(index)"),
                    kind: "choose",
                    beforeState: "ready",
                    afterState: target.nextState,
                    expectedNextEvidence: "result",
                    outcome: target.outcome
                ),
                counterfactualSetID: nil
            )
        }
        let model = SyntheticCausalConditionalModel.fit([
            example(one, 1), example(two, 2),
        ])

        #expect(model.predict(ambiguousFeature).abstentionReason == .insufficientConfidence)
        #expect(model.predict(SyntheticCausalFeature(
            domain: "unknown",
            priorState: "ready",
            intervention: "choose",
            expectedEvidence: "result"
        )).abstentionReason == .unseenCondition)
    }
}
