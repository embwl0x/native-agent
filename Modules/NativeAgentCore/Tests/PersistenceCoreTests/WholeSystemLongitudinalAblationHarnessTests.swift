import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import PersistenceCore

@Suite("Whole-system longitudinal ablation harness")
struct WholeSystemLongitudinalAblationHarnessTests {
    @Test("time-compressed trajectories preserve matched state and expose checkpoint losses")
    func matchedLongitudinalContrasts() async throws {
        let manifest = WholeSystemConvergenceManifest(
            manifestVersion: "longitudinal.generated.v1",
            declarations: [
                .init(
                    ablation: .residualRepairDisabled,
                    claimMode: .repeatableLoss,
                    primaryMetrics: [.taskSuccess, .falseCompletion]
                ),
            ],
            thresholds: WholeSystemMetric.allCases.map {
                .init(metric: $0, minimumMeaningfulLoss: 0.02, parityTolerance: 0.02)
            },
            requiredGates: [],
            performanceLimits: [],
            requiredFossilDimensions: [],
            minimumPairedTrials: 4
        )
        let timeline = WholeSystemLongitudinalTimeline(
            elapsedSeconds: [0, 3_600, 86_400, 3 * 86_400, 7 * 86_400]
        )
        let scenarios = (0..<4).map {
            WholeSystemHarnessScenario(
                id: "longitudinal-\($0)",
                fixtureDigestSHA256: String(repeating: String($0 + 1), count: 64)
            )
        }
        let executor = StatefulLongitudinalExecutor()

        let result = try await WholeSystemLongitudinalAblationHarness.run(
            manifest: manifest,
            scenarios: scenarios,
            timeline: timeline,
            evidenceClass: .generatedDeterministic,
            executor: executor
        )

        #expect(result.simulatedElapsedTime)
        #expect(result.trajectoryExecutionCount == 8)
        #expect(result.checkpointExecutionCount == 40)
        #expect(result.runDigestSHA256.count == 64)
        let lateTask = try #require(result.contrasts.first {
            $0.metric == .taskSuccess && $0.elapsedSeconds == 7 * 86_400
        })
        #expect(lateTask.matchedPairCount == 4)
        #expect(lateTask.signedLoss > 0.2)
        #expect(lateTask.lossDirectionFraction == 1)

        let report = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: result.trials,
            gates: [],
            performance: [],
            fossilEvidence: []
        )
        #expect(report.overallVerdict == .passed)
        #expect(report.executionBoundaryVerdict == .passed)
        #expect(report.providerCallCount == 8)
        #expect(await executor.trajectoryCount() == 8)
    }

    @Test("accelerated timeline cannot enter installed or personal evidence classes")
    func rejectsInstalledEvidenceClaim() async throws {
        let timeline = WholeSystemLongitudinalTimeline(elapsedSeconds: [0, 86_400])
        let scenario = WholeSystemHarnessScenario(
            id: "claim-boundary",
            fixtureDigestSHA256: String(repeating: "a", count: 64)
        )
        for evidenceClass in [
            WholeSystemEvidenceClass.installedMatchedAggregate,
            .authorizedPersonalOutcome,
        ] {
            await #expect(throws: WholeSystemLongitudinalHarnessError.unsupportedEvidenceClass) {
                _ = try await WholeSystemLongitudinalAblationHarness.run(
                    manifest: .wave12,
                    scenarios: [scenario],
                    timeline: timeline,
                    evidenceClass: evidenceClass,
                    executor: StatefulLongitudinalExecutor()
                )
            }
        }
    }

    @Test("trajectory must return exact checkpoints and unique execution evidence")
    func rejectsFabricatedTrajectory() async throws {
        let manifest = WholeSystemConvergenceManifest(
            manifestVersion: "longitudinal.strict.v1",
            declarations: [.init(
                ablation: .residualRepairDisabled,
                claimMode: .repeatableLoss,
                primaryMetrics: [.taskSuccess]
            )],
            thresholds: WholeSystemMetric.allCases.map {
                .init(metric: $0, minimumMeaningfulLoss: 0.02, parityTolerance: 0.02)
            },
            requiredGates: [], performanceLimits: [], requiredFossilDimensions: []
        )
        await #expect(throws: WholeSystemLongitudinalHarnessError.mismatchedTimeline) {
            _ = try await WholeSystemLongitudinalAblationHarness.run(
                manifest: manifest,
                scenarios: [.init(id: "strict", fixtureDigestSHA256: String(repeating: "b", count: 64))],
                timeline: .init(elapsedSeconds: [0, 86_400]),
                evidenceClass: .generatedDeterministic,
                executor: WrongTimelineLongitudinalExecutor()
            )
        }
    }
}

private actor StatefulLongitudinalExecutor: WholeSystemLongitudinalHarnessExecuting {
    private var count = 0

    func executeTrajectory(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition,
        timeline: WholeSystemLongitudinalTimeline
    ) async throws -> WholeSystemLongitudinalMeasurement {
        count += 1
        var accumulated = 0.0
        let points = timeline.elapsedSeconds.enumerated().map { index, elapsed in
            // A copied arm evolves as one sequence: with repair enabled,
            // accumulated residual falls; with it removed, residual compounds.
            accumulated += condition.facultyEnabled ? -0.015 : 0.06
            accumulated = min(0.4, max(0, accumulated))
            let task = condition.facultyEnabled ? 0.90 : max(0.50, 0.86 - accumulated)
            let falseCompletion = condition.facultyEnabled ? 0.04 : min(0.45, 0.08 + accumulated)
            let seed = "\(scenario.id)|\(condition.matchedPairDigestSHA256)|\(condition.facultyEnabled)|\(index)|\(elapsed)"
            return WholeSystemLongitudinalCheckpoint(
                elapsedSeconds: elapsed,
                executionEvidenceDigestSHA256: CausalTransitionEvidence.opaqueIdentity(seed),
                metrics: longitudinalMetrics(task: task, falseCompletion: falseCompletion)
            )
        }
        return WholeSystemLongitudinalMeasurement(
            scenarioID: scenario.id,
            fixtureDigestSHA256: scenario.fixtureDigestSHA256,
            condition: condition,
            executionEffects: .init(providerCallCount: 1),
            checkpoints: points
        )
    }

    func trajectoryCount() -> Int { count }
}

private struct WrongTimelineLongitudinalExecutor: WholeSystemLongitudinalHarnessExecuting {
    func executeTrajectory(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition,
        timeline: WholeSystemLongitudinalTimeline
    ) async throws -> WholeSystemLongitudinalMeasurement {
        WholeSystemLongitudinalMeasurement(
            scenarioID: scenario.id,
            fixtureDigestSHA256: scenario.fixtureDigestSHA256,
            condition: condition,
            executionEffects: .noControl,
            checkpoints: [
                .init(
                    elapsedSeconds: 1,
                    executionEvidenceDigestSHA256: CausalTransitionEvidence.opaqueIdentity(
                        "wrong|\(condition.facultyEnabled)"
                    ),
                    metrics: longitudinalMetrics(task: 0.8, falseCompletion: 0.1)
                ),
            ]
        )
    }
}

private func longitudinalMetrics(task: Double, falseCompletion: Double) -> [WholeSystemMetric: Double] {
    [
        .taskSuccess: task,
        .falseCompletion: falseCompletion,
        .correctionRate: falseCompletion,
        .latencyMilliseconds: 120,
        .providerCalls: 1,
        .contextRelevance: task,
        .actionVerification: task,
        .identityContractAdherence: 0.95,
        .userTrustSignal: max(0, 1 - falseCompletion),
    ]
}
