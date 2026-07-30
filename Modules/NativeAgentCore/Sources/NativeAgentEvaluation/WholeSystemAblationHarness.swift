import CryptoKit
import Foundation
import PersistenceCore

/// One payload-free generated or frozen scenario. The harness never accepts
/// personal prompts, message text, tool payloads, or file paths.
public struct WholeSystemHarnessScenario: Codable, Sendable, Equatable {
    public let id: String
    public let fixtureDigestSHA256: String

    public init(id: String, fixtureDigestSHA256: String) {
        self.id = String(id.prefix(96))
        self.fixtureDigestSHA256 = fixtureDigestSHA256
    }
}

public struct WholeSystemHarnessCondition: Codable, Sendable, Equatable {
    public let ablation: WholeSystemAblation
    public let facultyEnabled: Bool
    /// One deterministic identity shared by the baseline and intervention for
    /// an exact scenario/ablation pair. Executors use it to create or restore
    /// isolated matched state instead of carrying mutations between arms.
    public let matchedPairDigestSHA256: String

    package init(
        ablation: WholeSystemAblation,
        facultyEnabled: Bool,
        matchedPairDigestSHA256: String
    ) {
        self.ablation = ablation
        self.facultyEnabled = facultyEnabled
        self.matchedPairDigestSHA256 = matchedPairDigestSHA256
    }
}

/// Exact metrics observed by an executable scenario adapter. The adapter owns
/// the actual intervention; this type deliberately contains no pre-filled
/// baseline/ablation arrays and no authority-bearing output.
public struct WholeSystemHarnessMeasurement: Sendable, Equatable {
    public let scenarioID: String
    public let fixtureDigestSHA256: String
    public let condition: WholeSystemHarnessCondition
    /// Digest of the adapter's exact payload-free execution receipt. The
    /// harness binds it into the run digest so measurements remain traceable
    /// to executed conditions instead of becoming unattached numeric arrays.
    public let executionEvidenceDigestSHA256: String
    public let executionEffects: WholeSystemExecutionEffects
    public let metrics: [WholeSystemMetric: Double]

    public init(
        scenarioID: String,
        fixtureDigestSHA256: String,
        condition: WholeSystemHarnessCondition,
        executionEvidenceDigestSHA256: String,
        executionEffects: WholeSystemExecutionEffects,
        metrics: [WholeSystemMetric: Double]
    ) {
        self.scenarioID = scenarioID
        self.fixtureDigestSHA256 = fixtureDigestSHA256
        self.condition = condition
        self.executionEvidenceDigestSHA256 = executionEvidenceDigestSHA256
        self.executionEffects = executionEffects
        self.metrics = metrics
    }
}

public protocol WholeSystemHarnessExecuting: Sendable {
    func execute(
        scenario: WholeSystemHarnessScenario,
        condition: WholeSystemHarnessCondition
    ) async throws -> WholeSystemHarnessMeasurement
}

public struct WholeSystemExecutableHarnessResult: Sendable, Equatable {
    public let trials: [WholeSystemAblationTrial]
    public let executionCount: Int
    public let runDigestSHA256: String

    public init(
        trials: [WholeSystemAblationTrial],
        executionCount: Int,
        runDigestSHA256: String
    ) {
        self.trials = trials
        self.executionCount = executionCount
        self.runDigestSHA256 = runDigestSHA256
    }
}

public enum WholeSystemExecutableHarnessError: String, Error, Sendable, Equatable {
    case unsupportedEvidenceClass = "unsupported_evidence_class"
    case invalidScenario = "invalid_scenario"
    case duplicateScenario = "duplicate_scenario"
    case duplicateAblation = "duplicate_ablation"
    case invalidManifest = "invalid_manifest"
    case mismatchedScenario = "mismatched_scenario"
    case mismatchedCondition = "mismatched_condition"
    case invalidExecutionEvidence = "invalid_execution_evidence"
    case invalidExecutionEffects = "invalid_execution_effects"
    case missingMetric = "missing_metric"
    case invalidMetric = "invalid_metric"
}

/// Runs matched baseline and intervention executions. This closes the gap
/// between the evaluator and a real ablation adapter: numeric trial arrays are
/// produced only by executing both conditions over the same ordered scenarios.
/// It remains authority-free and supports generated/frozen evidence only.
public enum WholeSystemExecutableHarness {
    public static func run(
        manifest: WholeSystemConvergenceManifest,
        scenarios: [WholeSystemHarnessScenario],
        evidenceClass: WholeSystemEvidenceClass,
        executor: any WholeSystemHarnessExecuting
    ) async throws -> WholeSystemExecutableHarnessResult {
        guard evidenceClass == .generatedDeterministic || evidenceClass == .frozenControlled else {
            throw WholeSystemExecutableHarnessError.unsupportedEvidenceClass
        }
        try validate(scenarios)
        try validate(manifest)

        let orderedScenarios = scenarios.sorted { $0.id < $1.id }
        let declarations = manifest.declarations.sorted { $0.ablation.rawValue < $1.ablation.rawValue }
        let matchedDigest = try digest(ScenarioManifest(
            manifestVersion: manifest.manifestVersion,
            evidenceClass: evidenceClass,
            scenarios: orderedScenarios
        ))
        var trials: [WholeSystemAblationTrial] = []
        var executionEvidence: [ExecutionEvidence] = []
        var seenExecutionEvidence = Set<String>()
        var executionCount = 0

        for declaration in declarations {
            var baseline: [WholeSystemMetric: [Double]] = [:]
            var ablated: [WholeSystemMetric: [Double]] = [:]
            var executionEffects = WholeSystemExecutionEffects.noControl
            for (scenarioIndex, scenario) in orderedScenarios.enumerated() {
                let pairDigest = try digest(MatchedPairManifest(
                    matchedConditionDigestSHA256: matchedDigest,
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
                // Alternate arm order to avoid silently baking a systematic
                // warm-cache/order advantage into every pair. The shared pair
                // digest still requires executor-side state isolation.
                let baselineMeasurement: WholeSystemHarnessMeasurement
                let ablatedMeasurement: WholeSystemHarnessMeasurement
                if scenarioIndex.isMultiple(of: 2) {
                    baselineMeasurement = try await executor.execute(
                        scenario: scenario,
                        condition: baselineCondition
                    )
                    ablatedMeasurement = try await executor.execute(
                        scenario: scenario,
                        condition: ablatedCondition
                    )
                } else {
                    ablatedMeasurement = try await executor.execute(
                        scenario: scenario,
                        condition: ablatedCondition
                    )
                    baselineMeasurement = try await executor.execute(
                        scenario: scenario,
                        condition: baselineCondition
                    )
                }
                executionCount += 2
                guard baselineMeasurement.scenarioID == scenario.id,
                      ablatedMeasurement.scenarioID == scenario.id,
                      baselineMeasurement.fixtureDigestSHA256 == scenario.fixtureDigestSHA256,
                      ablatedMeasurement.fixtureDigestSHA256 == scenario.fixtureDigestSHA256 else {
                    throw WholeSystemExecutableHarnessError.mismatchedScenario
                }
                guard baselineMeasurement.condition == baselineCondition,
                      ablatedMeasurement.condition == ablatedCondition else {
                    throw WholeSystemExecutableHarnessError.mismatchedCondition
                }
                guard isSHA256(baselineMeasurement.executionEvidenceDigestSHA256),
                      isSHA256(ablatedMeasurement.executionEvidenceDigestSHA256) else {
                    throw WholeSystemExecutableHarnessError.invalidExecutionEvidence
                }
                guard let baselineEffects = executionEffects.adding(
                    baselineMeasurement.executionEffects
                ), let combinedEffects = baselineEffects.adding(
                    ablatedMeasurement.executionEffects
                ) else {
                    throw WholeSystemExecutableHarnessError.invalidExecutionEffects
                }
                executionEffects = combinedEffects
                guard seenExecutionEvidence.insert(
                    baselineMeasurement.executionEvidenceDigestSHA256
                ).inserted,
                seenExecutionEvidence.insert(
                    ablatedMeasurement.executionEvidenceDigestSHA256
                ).inserted else {
                    throw WholeSystemExecutableHarnessError.invalidExecutionEvidence
                }
                let baselineEvidence = ExecutionEvidence(
                    scenarioID: scenario.id,
                    condition: baselineCondition,
                    executionEvidenceDigestSHA256:
                        baselineMeasurement.executionEvidenceDigestSHA256,
                    executionEffects: baselineMeasurement.executionEffects
                )
                let ablatedEvidence = ExecutionEvidence(
                    scenarioID: scenario.id,
                    condition: ablatedCondition,
                    executionEvidenceDigestSHA256:
                        ablatedMeasurement.executionEvidenceDigestSHA256,
                    executionEffects: ablatedMeasurement.executionEffects
                )
                if scenarioIndex.isMultiple(of: 2) {
                    executionEvidence.append(baselineEvidence)
                    executionEvidence.append(ablatedEvidence)
                } else {
                    executionEvidence.append(ablatedEvidence)
                    executionEvidence.append(baselineEvidence)
                }
                // A whole-system ablation must preserve the complete matched
                // measurement vector. `primaryMetrics` determines the claim
                // verdict; it is not permission to omit collateral effects.
                for metric in WholeSystemMetric.allCases {
                    guard let baselineValue = baselineMeasurement.metrics[metric],
                          let ablatedValue = ablatedMeasurement.metrics[metric] else {
                        throw WholeSystemExecutableHarnessError.missingMetric
                    }
                    guard metric.acceptsHarnessValue(baselineValue),
                          metric.acceptsHarnessValue(ablatedValue) else {
                        throw WholeSystemExecutableHarnessError.invalidMetric
                    }
                    baseline[metric, default: []].append(baselineValue)
                    ablated[metric, default: []].append(ablatedValue)
                }
            }
            trials.append(WholeSystemAblationTrial(
                ablation: declaration.ablation,
                evidenceClass: evidenceClass,
                matchedConditionDigestSHA256: matchedDigest,
                baseline: .init(observations: WholeSystemMetric.allCases.map {
                    .measured($0, baseline[$0] ?? [])
                }),
                ablated: .init(observations: WholeSystemMetric.allCases.map {
                    .measured($0, ablated[$0] ?? [])
                }),
                executionEffects: executionEffects
            ))
        }

        let runDigest = try digest(RunManifest(
            matchedConditionDigestSHA256: matchedDigest,
            executionCount: executionCount,
            executionEvidence: executionEvidence,
            trials: trials
        ))
        return WholeSystemExecutableHarnessResult(
            trials: trials,
            executionCount: executionCount,
            runDigestSHA256: runDigest
        )
    }

    private static func validate(_ scenarios: [WholeSystemHarnessScenario]) throws {
        guard !scenarios.isEmpty, scenarios.count <= WholeSystemMetricObservation.maximumTrialValues else {
            throw WholeSystemExecutableHarnessError.invalidScenario
        }
        var ids = Set<String>()
        for scenario in scenarios {
            guard scenario.id.count >= 1,
                  scenario.id.count <= 96,
                  scenario.id.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
                  }),
                  isSHA256(scenario.fixtureDigestSHA256) else {
                throw WholeSystemExecutableHarnessError.invalidScenario
            }
            guard ids.insert(scenario.id).inserted else {
                throw WholeSystemExecutableHarnessError.duplicateScenario
            }
        }
    }

    private static func validate(_ manifest: WholeSystemConvergenceManifest) throws {
        guard manifest.schema == WholeSystemConvergenceManifest.schema,
              !manifest.manifestVersion.isEmpty,
              !manifest.declarations.isEmpty,
              manifest.declarations.count <= manifest.maximumComparisons,
              manifest.maximumComparisons > 0 else {
            throw WholeSystemExecutableHarnessError.invalidManifest
        }
        var ablations = Set<WholeSystemAblation>()
        for declaration in manifest.declarations {
            guard ablations.insert(declaration.ablation).inserted else {
                throw WholeSystemExecutableHarnessError.duplicateAblation
            }
            guard !declaration.primaryMetrics.isEmpty else {
                throw WholeSystemExecutableHarnessError.invalidManifest
            }
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

    private struct ScenarioManifest: Encodable {
        let manifestVersion: String
        let evidenceClass: WholeSystemEvidenceClass
        let scenarios: [WholeSystemHarnessScenario]
    }

    private struct RunManifest: Encodable {
        let matchedConditionDigestSHA256: String
        let executionCount: Int
        let executionEvidence: [ExecutionEvidence]
        let trials: [WholeSystemAblationTrial]
    }

    private struct ExecutionEvidence: Encodable {
        let scenarioID: String
        let condition: WholeSystemHarnessCondition
        let executionEvidenceDigestSHA256: String
        let executionEffects: WholeSystemExecutionEffects
    }

    private struct MatchedPairManifest: Encodable {
        let matchedConditionDigestSHA256: String
        let ablation: WholeSystemAblation
        let scenario: WholeSystemHarnessScenario
    }
}

private extension WholeSystemMetric {
    func acceptsHarnessValue(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .taskSuccess, .falseCompletion, .correctionRate, .contextRelevance,
             .actionVerification, .identityContractAdherence, .userTrustSignal:
            return (0...1).contains(value)
        case .latencyMilliseconds, .providerCalls:
            return (0...1_000_000_000).contains(value)
        }
    }
}
