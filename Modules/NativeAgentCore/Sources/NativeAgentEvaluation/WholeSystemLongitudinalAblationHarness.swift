import CryptoKit
import Foundation
import PersistenceCore

/// An analytic timeline for generated/frozen longitudinal intervention proof.
/// Offsets are not wall-clock evidence; they describe how far the executor must
/// advance the exact copied state before measuring each checkpoint.
public struct WholeSystemLongitudinalTimeline: Codable, Sendable, Equatable {
    public static let maximumCheckpoints = 32

    public let elapsedSeconds: [TimeInterval]

    public init(elapsedSeconds: [TimeInterval]) {
        self.elapsedSeconds = elapsedSeconds
    }

    public var isValid: Bool {
        (2...Self.maximumCheckpoints).contains(elapsedSeconds.count)
            && elapsedSeconds.first == 0
            && elapsedSeconds.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 365 * 24 * 60 * 60 }
            && zip(elapsedSeconds, elapsedSeconds.dropFirst()).allSatisfy { $0.0 < $0.1 }
    }
}

public struct WholeSystemLongitudinalCheckpoint: Sendable, Equatable {
    public let elapsedSeconds: TimeInterval
    public let executionEvidenceDigestSHA256: String
    public let metrics: [WholeSystemMetric: Double]

    public init(
        elapsedSeconds: TimeInterval,
        executionEvidenceDigestSHA256: String,
        metrics: [WholeSystemMetric: Double]
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.executionEvidenceDigestSHA256 = executionEvidenceDigestSHA256
        self.metrics = metrics
    }
}

/// One arm executes as a sequence so state may genuinely accumulate, decay,
/// repair, restart, or recover across checkpoints. It is not a bag of unrelated
/// pre-filled numeric observations.
public struct WholeSystemLongitudinalMeasurement: Sendable, Equatable {
    public let scenarioID: String
    public let fixtureDigestSHA256: String
    public let condition: WholeSystemHarnessCondition
    public let executionEffects: WholeSystemExecutionEffects
    public let checkpoints: [WholeSystemLongitudinalCheckpoint]

    public init(
        scenarioID: String,
        fixtureDigestSHA256: String,
        condition: WholeSystemHarnessCondition,
        executionEffects: WholeSystemExecutionEffects,
        checkpoints: [WholeSystemLongitudinalCheckpoint]
    ) {
        self.scenarioID = scenarioID
        self.fixtureDigestSHA256 = fixtureDigestSHA256
        self.condition = condition
        self.executionEffects = executionEffects
        self.checkpoints = checkpoints
    }
}

public protocol WholeSystemLongitudinalHarnessExecuting: Sendable {
    func executeTrajectory(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition,
        timeline: WholeSystemLongitudinalTimeline
    ) async throws -> WholeSystemLongitudinalMeasurement
}

/// Per-checkpoint matched causal contrast. `signedLoss` uses the same direction
/// as the convergence evaluator: positive means disabling the faculty harmed
/// the metric. Generated/frozen interventions prove mechanism sensitivity, not
/// personal causality.
public struct WholeSystemLongitudinalContrast: Codable, Sendable, Equatable {
    public let ablation: WholeSystemAblation
    public let metric: WholeSystemMetric
    public let elapsedSeconds: TimeInterval
    public let matchedPairCount: Int
    public let baselineMean: Double
    public let ablatedMean: Double
    public let signedLoss: Double
    public let lossDirectionFraction: Double
}

public struct WholeSystemLongitudinalHarnessResult: Sendable, Equatable {
    public let evidenceClass: WholeSystemEvidenceClass
    public let simulatedElapsedTime: Bool
    public let timeline: WholeSystemLongitudinalTimeline
    public let trials: [WholeSystemAblationTrial]
    public let contrasts: [WholeSystemLongitudinalContrast]
    public let trajectoryExecutionCount: Int
    public let checkpointExecutionCount: Int
    public let runDigestSHA256: String
}

public enum WholeSystemLongitudinalHarnessError: String, Error, Sendable, Equatable {
    case unsupportedEvidenceClass = "unsupported_evidence_class"
    case invalidTimeline = "invalid_timeline"
    case invalidScenario = "invalid_scenario"
    case invalidManifest = "invalid_manifest"
    case mismatchedScenario = "mismatched_scenario"
    case mismatchedCondition = "mismatched_condition"
    case mismatchedTimeline = "mismatched_timeline"
    case invalidExecutionEvidence = "invalid_execution_evidence"
    case invalidExecutionEffects = "invalid_execution_effects"
    case missingMetric = "missing_metric"
    case invalidMetric = "invalid_metric"
}

public enum WholeSystemLongitudinalAblationHarness {
    public static func run(
        manifest: WholeSystemConvergenceManifest,
        scenarios: [WholeSystemHarnessScenario],
        timeline: WholeSystemLongitudinalTimeline,
        evidenceClass: WholeSystemEvidenceClass,
        executor: any WholeSystemLongitudinalHarnessExecuting
    ) async throws -> WholeSystemLongitudinalHarnessResult {
        guard evidenceClass == .generatedDeterministic || evidenceClass == .frozenControlled else {
            throw WholeSystemLongitudinalHarnessError.unsupportedEvidenceClass
        }
        guard timeline.isValid else { throw WholeSystemLongitudinalHarnessError.invalidTimeline }
        guard !scenarios.isEmpty,
              scenarios.count * timeline.elapsedSeconds.count <= WholeSystemMetricObservation.maximumTrialValues,
              Set(scenarios.map(\.id)).count == scenarios.count,
              scenarios.allSatisfy({ validToken($0.id) && isSHA256($0.fixtureDigestSHA256) })
        else { throw WholeSystemLongitudinalHarnessError.invalidScenario }
        guard manifest.schema == WholeSystemConvergenceManifest.schema,
              !manifest.declarations.isEmpty,
              manifest.declarations.count <= manifest.maximumComparisons,
              Set(manifest.declarations.map(\.ablation)).count == manifest.declarations.count
        else { throw WholeSystemLongitudinalHarnessError.invalidManifest }

        let orderedScenarios = scenarios.sorted { $0.id < $1.id }
        let declarations = manifest.declarations.sorted { $0.ablation.rawValue < $1.ablation.rawValue }
        let conditionDigest = try digest(ConditionManifest(
            manifestVersion: manifest.manifestVersion,
            evidenceClass: evidenceClass,
            timeline: timeline,
            scenarios: orderedScenarios
        ))
        var trials: [WholeSystemAblationTrial] = []
        var contrasts: [WholeSystemLongitudinalContrast] = []
        var executionEvidence: [ExecutionEvidence] = []
        var seenEvidence = Set<String>()

        for declaration in declarations {
            var baselineByMetric: [WholeSystemMetric: [Double]] = [:]
            var ablatedByMetric: [WholeSystemMetric: [Double]] = [:]
            var valuesByCheckpoint: [TimeInterval: [WholeSystemMetric: (baseline: [Double], ablated: [Double])]] = [:]
            var executionEffects = WholeSystemExecutionEffects.noControl

            for (scenarioIndex, scenario) in orderedScenarios.enumerated() {
                let pairDigest = try digest(PairManifest(
                    conditionDigestSHA256: conditionDigest,
                    ablation: declaration.ablation,
                    scenario: scenario
                ))
                let baselineCondition = WholeSystemHarnessCondition(
                    ablation: declaration.ablation,
                    facultyEnabled: true,
                    matchedPairDigestSHA256: pairDigest
                )
                let ablatedCondition = WholeSystemHarnessCondition(
                    ablation: declaration.ablation,
                    facultyEnabled: false,
                    matchedPairDigestSHA256: pairDigest
                )
                let baseline: WholeSystemLongitudinalMeasurement
                let ablated: WholeSystemLongitudinalMeasurement
                if scenarioIndex.isMultiple(of: 2) {
                    baseline = try await executor.executeTrajectory(
                        scenario: scenario, condition: baselineCondition, timeline: timeline
                    )
                    ablated = try await executor.executeTrajectory(
                        scenario: scenario, condition: ablatedCondition, timeline: timeline
                    )
                } else {
                    ablated = try await executor.executeTrajectory(
                        scenario: scenario, condition: ablatedCondition, timeline: timeline
                    )
                    baseline = try await executor.executeTrajectory(
                        scenario: scenario, condition: baselineCondition, timeline: timeline
                    )
                }
                try validate(
                    baseline, scenario: scenario, condition: baselineCondition,
                    timeline: timeline, seenEvidence: &seenEvidence
                )
                try validate(
                    ablated, scenario: scenario, condition: ablatedCondition,
                    timeline: timeline, seenEvidence: &seenEvidence
                )
                guard let baselineEffects = executionEffects.adding(baseline.executionEffects),
                      let combinedEffects = baselineEffects.adding(ablated.executionEffects) else {
                    throw WholeSystemLongitudinalHarnessError.invalidExecutionEffects
                }
                executionEffects = combinedEffects
                executionEvidence.append(contentsOf: baseline.checkpoints.map {
                    ExecutionEvidence(
                        scenarioID: scenario.id, condition: baselineCondition,
                        elapsedSeconds: $0.elapsedSeconds,
                        digestSHA256: $0.executionEvidenceDigestSHA256,
                        executionEffects: baseline.executionEffects
                    )
                })
                executionEvidence.append(contentsOf: ablated.checkpoints.map {
                    ExecutionEvidence(
                        scenarioID: scenario.id, condition: ablatedCondition,
                        elapsedSeconds: $0.elapsedSeconds,
                        digestSHA256: $0.executionEvidenceDigestSHA256,
                        executionEffects: ablated.executionEffects
                    )
                })

                for (basePoint, ablatedPoint) in zip(baseline.checkpoints, ablated.checkpoints) {
                    for metric in WholeSystemMetric.allCases {
                        let base = basePoint.metrics[metric]!
                        let removed = ablatedPoint.metrics[metric]!
                        baselineByMetric[metric, default: []].append(base)
                        ablatedByMetric[metric, default: []].append(removed)
                        var checkpoint = valuesByCheckpoint[basePoint.elapsedSeconds, default: [:]]
                        var metricValues = checkpoint[metric, default: ([], [])]
                        metricValues.baseline.append(base)
                        metricValues.ablated.append(removed)
                        checkpoint[metric] = metricValues
                        valuesByCheckpoint[basePoint.elapsedSeconds] = checkpoint
                    }
                }
            }

            trials.append(WholeSystemAblationTrial(
                ablation: declaration.ablation,
                evidenceClass: evidenceClass,
                matchedConditionDigestSHA256: conditionDigest,
                baseline: .init(observations: WholeSystemMetric.allCases.map {
                    .measured($0, baselineByMetric[$0] ?? [])
                }),
                ablated: .init(observations: WholeSystemMetric.allCases.map {
                    .measured($0, ablatedByMetric[$0] ?? [])
                }),
                executionEffects: executionEffects
            ))
            for elapsed in timeline.elapsedSeconds {
                for metric in WholeSystemMetric.allCases {
                    guard let values = valuesByCheckpoint[elapsed]?[metric], !values.baseline.isEmpty else { continue }
                    let baseMean = mean(values.baseline)
                    let ablatedMean = mean(values.ablated)
                    let losses = zip(values.baseline, values.ablated).map { base, removed in
                        higherIsBetter(metric) ? base - removed : removed - base
                    }
                    contrasts.append(WholeSystemLongitudinalContrast(
                        ablation: declaration.ablation,
                        metric: metric,
                        elapsedSeconds: elapsed,
                        matchedPairCount: losses.count,
                        baselineMean: baseMean,
                        ablatedMean: ablatedMean,
                        signedLoss: mean(losses),
                        lossDirectionFraction: Double(losses.filter { $0 > 0 }.count) / Double(losses.count)
                    ))
                }
            }
        }

        let runDigest = try digest(RunManifest(
            conditionDigestSHA256: conditionDigest,
            timeline: timeline,
            evidence: executionEvidence,
            trials: trials,
            contrasts: contrasts
        ))
        return WholeSystemLongitudinalHarnessResult(
            evidenceClass: evidenceClass,
            simulatedElapsedTime: true,
            timeline: timeline,
            trials: trials,
            contrasts: contrasts,
            trajectoryExecutionCount: declarations.count * orderedScenarios.count * 2,
            checkpointExecutionCount: declarations.count * orderedScenarios.count
                * timeline.elapsedSeconds.count * 2,
            runDigestSHA256: runDigest
        )
    }

    private static func validate(
        _ measurement: WholeSystemLongitudinalMeasurement,
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition,
        timeline: WholeSystemLongitudinalTimeline,
        seenEvidence: inout Set<String>
    ) throws {
        guard measurement.scenarioID == scenario.id,
              measurement.fixtureDigestSHA256 == scenario.fixtureDigestSHA256 else {
            throw WholeSystemLongitudinalHarnessError.mismatchedScenario
        }
        guard measurement.condition == condition else {
            throw WholeSystemLongitudinalHarnessError.mismatchedCondition
        }
        guard measurement.executionEffects.isStructurallyValid else {
            throw WholeSystemLongitudinalHarnessError.invalidExecutionEffects
        }
        guard measurement.checkpoints.map(\.elapsedSeconds) == timeline.elapsedSeconds else {
            throw WholeSystemLongitudinalHarnessError.mismatchedTimeline
        }
        for point in measurement.checkpoints {
            guard isSHA256(point.executionEvidenceDigestSHA256),
                  seenEvidence.insert(point.executionEvidenceDigestSHA256).inserted else {
                throw WholeSystemLongitudinalHarnessError.invalidExecutionEvidence
            }
            for metric in WholeSystemMetric.allCases {
                guard let value = point.metrics[metric] else {
                    throw WholeSystemLongitudinalHarnessError.missingMetric
                }
                guard accepts(value, for: metric) else {
                    throw WholeSystemLongitudinalHarnessError.invalidMetric
                }
            }
        }
    }

    private static func accepts(_ value: Double, for metric: WholeSystemMetric) -> Bool {
        guard value.isFinite else { return false }
        switch metric {
        case .taskSuccess, .falseCompletion, .correctionRate, .contextRelevance,
             .actionVerification, .identityContractAdherence, .userTrustSignal:
            return (0...1).contains(value)
        case .latencyMilliseconds, .providerCalls:
            return (0...1_000_000_000).contains(value)
        }
    }

    private static func higherIsBetter(_ metric: WholeSystemMetric) -> Bool {
        switch metric {
        case .falseCompletion, .correctionRate, .latencyMilliseconds, .providerCalls: false
        default: true
        }
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ConditionManifest: Encodable {
        let manifestVersion: String
        let evidenceClass: WholeSystemEvidenceClass
        let timeline: WholeSystemLongitudinalTimeline
        let scenarios: [WholeSystemHarnessScenario]
    }

    private struct PairManifest: Encodable {
        let conditionDigestSHA256: String
        let ablation: WholeSystemAblation
        let scenario: WholeSystemHarnessScenario
    }

    private struct ExecutionEvidence: Encodable {
        let scenarioID: String
        let condition: WholeSystemHarnessCondition
        let elapsedSeconds: TimeInterval
        let digestSHA256: String
        let executionEffects: WholeSystemExecutionEffects
    }

    private struct RunManifest: Encodable {
        let conditionDigestSHA256: String
        let timeline: WholeSystemLongitudinalTimeline
        let evidence: [ExecutionEvidence]
        let trials: [WholeSystemAblationTrial]
        let contrasts: [WholeSystemLongitudinalContrast]
    }
}
