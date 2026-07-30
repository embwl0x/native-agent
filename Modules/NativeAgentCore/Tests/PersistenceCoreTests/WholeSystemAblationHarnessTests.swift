import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import PersistenceCore

@Suite("Whole-system executable ablation harness")
struct WholeSystemAblationHarnessTests {
    @Test("paired values are created by actual matched executions")
    func executesBothConditions() async throws {
        let declaration = WholeSystemAblationDeclaration(
            ablation: .contextUtilityShuffled,
            claimMode: .repeatableLoss,
            primaryMetrics: [.contextRelevance]
        )
        let manifest = WholeSystemConvergenceManifest(
            manifestVersion: "generated.executable.test.v1",
            declarations: [declaration],
            thresholds: WholeSystemMetric.allCases.map {
                .init(metric: $0, minimumMeaningfulLoss: 0.02, parityTolerance: 0.02)
            },
            requiredGates: [],
            performanceLimits: [],
            requiredFossilDimensions: []
        )
        let executor = CountingAblationExecutor()
        let scenarios = (0..<4).map {
            WholeSystemHarnessScenario(
                id: "scenario-\($0)",
                fixtureDigestSHA256: String(repeating: String($0 + 1), count: 64)
            )
        }

        let result = try await WholeSystemExecutableHarness.run(
            manifest: manifest,
            scenarios: scenarios,
            evidenceClass: .generatedDeterministic,
            executor: executor
        )
        let executions = await executor.executionCount()
        #expect(executions == 8)
        #expect(result.executionCount == 8)
        #expect(result.runDigestSHA256.count == 64)
        let conditions = await executor.conditions()
        for scenarioID in scenarios.map(\.id) {
            let pair = conditions.filter { $0.scenarioID == scenarioID }.map(\.condition)
            #expect(pair.count == 2)
            #expect(Set(pair.map(\.matchedPairDigestSHA256)).count == 1)
            #expect(Set(pair.map(\.facultyEnabled)) == Set([true, false]))
        }

        let report = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: result.trials,
            gates: [],
            performance: [],
            fossilEvidence: []
        )
        #expect(report.overallVerdict == .passed)
        #expect(report.ablations.first?.verdict == .passed)
        #expect(report.executionBoundaryVerdict == .passed)
        #expect(report.providerCallCount == 8)
        #expect(report.canonicalStateMutationCount == 0)
    }

    @Test("personal evidence cannot enter the generated executable harness")
    func rejectsPersonalEvidence() async throws {
        await #expect(throws: WholeSystemExecutableHarnessError.unsupportedEvidenceClass) {
            _ = try await WholeSystemExecutableHarness.run(
                manifest: .wave12,
                scenarios: [.init(id: "safe", fixtureDigestSHA256: String(repeating: "a", count: 64))],
                evidenceClass: .authorizedPersonalOutcome,
                executor: CountingAblationExecutor()
            )
        }
    }

    @Test("executor must echo exact fixture and intervention condition")
    func rejectsMismatchedExecutionEvidence() async throws {
        let manifest = singleMetricManifest()
        let scenario = WholeSystemHarnessScenario(
            id: "exact-scenario",
            fixtureDigestSHA256: String(repeating: "a", count: 64)
        )
        await #expect(throws: WholeSystemExecutableHarnessError.mismatchedScenario) {
            _ = try await WholeSystemExecutableHarness.run(
                manifest: manifest,
                scenarios: [scenario],
                evidenceClass: .generatedDeterministic,
                executor: MismatchedAblationExecutor(mode: .fixture)
            )
        }
        await #expect(throws: WholeSystemExecutableHarnessError.mismatchedCondition) {
            _ = try await WholeSystemExecutableHarness.run(
                manifest: manifest,
                scenarios: [scenario],
                evidenceClass: .generatedDeterministic,
                executor: MismatchedAblationExecutor(mode: .condition)
            )
        }
    }

    @Test("primary metric cannot hide missing whole-system collateral effects")
    func requiresCompleteMeasurementVector() async throws {
        await #expect(throws: WholeSystemExecutableHarnessError.missingMetric) {
            _ = try await WholeSystemExecutableHarness.run(
                manifest: singleMetricManifest(),
                scenarios: [.init(
                    id: "complete-vector",
                    fixtureDigestSHA256: String(repeating: "f", count: 64)
                )],
                evidenceClass: .generatedDeterministic,
                executor: IncompleteAblationExecutor()
            )
        }
    }

    @Test("adapter effects are measured and control authority fails the report")
    func measuredExecutionAuthorityCannotBeHardCodedAway() async throws {
        let manifest = singleMetricManifest()
        let result = try await WholeSystemExecutableHarness.run(
            manifest: manifest,
            scenarios: [.init(
                id: "authority-boundary",
                fixtureDigestSHA256: String(repeating: "c", count: 64)
            )],
            evidenceClass: .generatedDeterministic,
            executor: AuthorityBearingAblationExecutor()
        )
        let report = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: result.trials,
            gates: [],
            performance: [],
            fossilEvidence: []
        )

        #expect(report.actionAuthority)
        #expect(report.executionBoundaryVerdict == .failed)
        #expect(report.overallVerdict == .failed)
        #expect(report.providerCallCount == 2)
    }
}

private actor CountingAblationExecutor: WholeSystemHarnessExecuting {
    private var count = 0
    private var observed: [(scenarioID: String, condition: WholeSystemHarnessCondition)] = []

    func execute(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition
    ) async throws -> WholeSystemHarnessMeasurement {
        count += 1
        observed.append((scenario.id, condition))
        return WholeSystemHarnessMeasurement(
            scenarioID: scenario.id,
            fixtureDigestSHA256: scenario.fixtureDigestSHA256,
            condition: condition,
            executionEvidenceDigestSHA256: CausalTransitionEvidence.opaqueIdentity(
                "\(scenario.id)|\(condition.matchedPairDigestSHA256)|\(condition.facultyEnabled)"
            ),
            executionEffects: .init(providerCallCount: 1),
            metrics: completeMetrics(facultyEnabled: condition.facultyEnabled)
        )
    }

    func executionCount() -> Int { count }
    func conditions() -> [(scenarioID: String, condition: WholeSystemHarnessCondition)] { observed }
}

private enum MismatchMode: Sendable { case fixture, condition }

private struct MismatchedAblationExecutor: WholeSystemHarnessExecuting {
    let mode: MismatchMode

    func execute(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition
    ) async throws -> WholeSystemHarnessMeasurement {
        let echoedCondition = mode == .condition
            ? WholeSystemHarnessCondition(
                ablation: condition.ablation,
                facultyEnabled: !condition.facultyEnabled,
                matchedPairDigestSHA256: condition.matchedPairDigestSHA256
            )
            : condition
        return WholeSystemHarnessMeasurement(
            scenarioID: scenario.id,
            fixtureDigestSHA256: mode == .fixture
                ? String(repeating: "b", count: 64)
                : scenario.fixtureDigestSHA256,
            condition: echoedCondition,
            executionEvidenceDigestSHA256: CausalTransitionEvidence.opaqueIdentity(
                "\(scenario.id)|\(condition.matchedPairDigestSHA256)|\(condition.facultyEnabled)"
            ),
            executionEffects: .noControl,
            metrics: completeMetrics(facultyEnabled: condition.facultyEnabled)
        )
    }
}

private struct IncompleteAblationExecutor: WholeSystemHarnessExecuting {
    func execute(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition
    ) async throws -> WholeSystemHarnessMeasurement {
        WholeSystemHarnessMeasurement(
            scenarioID: scenario.id,
            fixtureDigestSHA256: scenario.fixtureDigestSHA256,
            condition: condition,
            executionEvidenceDigestSHA256: CausalTransitionEvidence.opaqueIdentity(
                "\(scenario.id)|\(condition.matchedPairDigestSHA256)|\(condition.facultyEnabled)"
            ),
            executionEffects: .noControl,
            metrics: [.contextRelevance: 0.8]
        )
    }
}

private struct AuthorityBearingAblationExecutor: WholeSystemHarnessExecuting {
    func execute(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition
    ) async throws -> WholeSystemHarnessMeasurement {
        WholeSystemHarnessMeasurement(
            scenarioID: scenario.id,
            fixtureDigestSHA256: scenario.fixtureDigestSHA256,
            condition: condition,
            executionEvidenceDigestSHA256: CausalTransitionEvidence.opaqueIdentity(
                "authority|\(condition.facultyEnabled)"
            ),
            executionEffects: .init(providerCallCount: 1, actionAuthority: true),
            metrics: completeMetrics(facultyEnabled: condition.facultyEnabled)
        )
    }
}

private func singleMetricManifest() -> WholeSystemConvergenceManifest {
    WholeSystemConvergenceManifest(
        manifestVersion: "generated.exact-pair.test.v1",
        declarations: [.init(
            ablation: .contextUtilityShuffled,
            claimMode: .repeatableLoss,
            primaryMetrics: [.contextRelevance]
        )],
        thresholds: WholeSystemMetric.allCases.map {
            .init(metric: $0, minimumMeaningfulLoss: 0.02, parityTolerance: 0.02)
        },
        requiredGates: [],
        performanceLimits: [],
        requiredFossilDimensions: []
    )
}

private func completeMetrics(facultyEnabled: Bool) -> [WholeSystemMetric: Double] {
    [
        .taskSuccess: facultyEnabled ? 0.9 : 0.6,
        .falseCompletion: facultyEnabled ? 0.05 : 0.25,
        .correctionRate: facultyEnabled ? 0.05 : 0.25,
        .latencyMilliseconds: facultyEnabled ? 100 : 150,
        .providerCalls: facultyEnabled ? 1 : 2,
        .contextRelevance: facultyEnabled ? 0.9 : 0.6,
        .actionVerification: facultyEnabled ? 0.95 : 0.7,
        .identityContractAdherence: facultyEnabled ? 0.95 : 0.8,
        .userTrustSignal: facultyEnabled ? 0.9 : 0.7,
    ]
}
