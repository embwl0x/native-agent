import Foundation
@testable import NativeAgentEvaluation
@testable import PersistenceCore

/// Read-only proof that NativeAgent can fit and evaluate a transparent
/// conditional transition baseline without touching personal traces or any
/// live runtime owner. The fixture is generated entirely in memory and the
/// resulting model has no persistence, prompt, scheduling, approval, or
/// action surface.
public enum SyntheticCausalFrontierSimulation {
    public static let schema = "synthetic-causal-frontier-report.v1"
    public static let baselineVersion = "categorical-conditional-transition.v1"

    public static func run() -> SyntheticCausalFrontierReport {
        let fixture = SyntheticCausalFixture.make()
        let model = SyntheticCausalConditionalModel.fit(fixture.training)

        return SyntheticCausalFrontierReport(
            schema: schema,
            baselineVersion: baselineVersion,
            evidenceScope: "generated_synthetic_operational_transitions",
            personalTraceCount: 0,
            shadowOnly: true,
            controlAuthority: false,
            approvalInferred: false,
            learnedRuleCount: model.ruleCount,
            trainingCount: fixture.training.count,
            stable: SyntheticCausalEvaluator.evaluate(
                model: model,
                training: fixture.training,
                holdout: fixture.stableHoldout
            ),
            counterfactual: SyntheticCausalEvaluator.evaluate(
                model: model,
                training: fixture.training,
                holdout: fixture.counterfactualHoldout
            ),
            shifted: SyntheticCausalEvaluator.evaluate(
                model: model,
                training: fixture.training,
                holdout: fixture.shiftedHoldout
            ),
            limitations: [
                "Synthetic interventions prove evaluation mechanics, not real-world causality.",
                "The baseline predicts operational transitions only and has no runtime control.",
                "Personal-trace learning remains behind privacy, holdout, drift, rollback, and explicit-approval gates.",
            ]
        )
    }
}

public struct SyntheticCausalFrontierReport: Sendable, Equatable {
    public let schema: String
    public let baselineVersion: String
    public let evidenceScope: String
    public let personalTraceCount: Int
    public let shadowOnly: Bool
    public let controlAuthority: Bool
    public let approvalInferred: Bool
    public let learnedRuleCount: Int
    public let trainingCount: Int
    public let stable: SyntheticCausalEvaluationReport
    public let counterfactual: SyntheticCausalEvaluationReport
    public let shifted: SyntheticCausalEvaluationReport
    public let limitations: [String]
}

public enum SyntheticCausalAbstentionReason: String, Sendable, Equatable {
    case unseenCondition = "unseen_condition"
    case insufficientConfidence = "insufficient_confidence"
}

public struct SyntheticCausalEvaluationReport: Sendable, Equatable {
    public let evaluationCount: Int
    public let coveredCount: Int
    public let abstainedCount: Int
    public let unseenConditionCount: Int
    public let insufficientConfidenceCount: Int
    public let coverage: Double
    public let accuracy: Double?
    public let meanLogLoss: Double?
    public let meanConfidence: Double?
    public let expectedCalibrationError: Double?
    public let counterfactualComparisonCount: Int
    public let interventionSensitiveComparisonCount: Int
    public let interventionSensitivityRate: Double?
    public let drift: AdaptiveCausalDriftEvaluation
}

// MARK: - Transparent categorical baseline

struct SyntheticCausalFeature: Hashable, Sendable {
    let domain: String
    let priorState: String
    let intervention: String
    let expectedEvidence: String
}

struct SyntheticCausalTarget: Hashable, Sendable {
    let nextState: String
    let outcome: String
}

struct SyntheticCausalExample: Sendable, Equatable {
    let feature: SyntheticCausalFeature
    let target: SyntheticCausalTarget
    let evidence: CausalTransitionEvidence
    let counterfactualSetID: String?
}

struct SyntheticCausalPrediction: Sendable, Equatable {
    let target: SyntheticCausalTarget?
    let confidence: Double?
    let probabilities: [SyntheticCausalTarget: Double]
    let abstentionReason: SyntheticCausalAbstentionReason?
}

struct SyntheticCausalConditionalModel: Sendable {
    private let counts: [SyntheticCausalFeature: [SyntheticCausalTarget: Int]]
    let minimumConfidence: Double

    var ruleCount: Int { counts.count }

    static func fit(
        _ examples: [SyntheticCausalExample],
        minimumConfidence: Double = 0.60
    ) -> Self {
        var counts: [SyntheticCausalFeature: [SyntheticCausalTarget: Int]] = [:]
        for example in examples {
            counts[example.feature, default: [:]][example.target, default: 0] += 1
        }
        return Self(
            counts: counts,
            minimumConfidence: min(1, max(0, minimumConfidence))
        )
    }

    func predict(_ feature: SyntheticCausalFeature) -> SyntheticCausalPrediction {
        guard let targetCounts = counts[feature], !targetCounts.isEmpty else {
            return SyntheticCausalPrediction(
                target: nil,
                confidence: nil,
                probabilities: [:],
                abstentionReason: .unseenCondition
            )
        }
        let total = Double(targetCounts.values.reduce(0, +))
        let probabilities = targetCounts.mapValues { Double($0) / total }
        let winner = probabilities.sorted(by: syntheticTargetProbabilityOrder).first!
        guard winner.value >= minimumConfidence else {
            return SyntheticCausalPrediction(
                target: nil,
                confidence: winner.value,
                probabilities: probabilities,
                abstentionReason: .insufficientConfidence
            )
        }
        return SyntheticCausalPrediction(
            target: winner.key,
            confidence: winner.value,
            probabilities: probabilities,
            abstentionReason: nil
        )
    }
}

private func syntheticTargetProbabilityOrder(
    _ lhs: (key: SyntheticCausalTarget, value: Double),
    _ rhs: (key: SyntheticCausalTarget, value: Double)
) -> Bool {
    if lhs.value != rhs.value { return lhs.value > rhs.value }
    if lhs.key.nextState != rhs.key.nextState { return lhs.key.nextState < rhs.key.nextState }
    return lhs.key.outcome < rhs.key.outcome
}

// MARK: - Evaluation

enum SyntheticCausalEvaluator {
    static func evaluate(
        model: SyntheticCausalConditionalModel,
        training: [SyntheticCausalExample],
        holdout: [SyntheticCausalExample]
    ) -> SyntheticCausalEvaluationReport {
        var correct = 0
        var logLoss = 0.0
        var confidenceTotal = 0.0
        var calibrationBins = Array(
            repeating: CalibrationBin(),
            count: 10
        )
        var abstentions: [SyntheticCausalAbstentionReason: Int] = [:]
        var counterfactualPredictions: [String: [SyntheticCausalTarget]] = [:]

        for example in holdout {
            let prediction = model.predict(example.feature)
            guard let predicted = prediction.target,
                  let confidence = prediction.confidence else {
                if let reason = prediction.abstentionReason {
                    abstentions[reason, default: 0] += 1
                }
                continue
            }

            let isCorrect = predicted == example.target
            if isCorrect { correct += 1 }
            confidenceTotal += confidence
            let probabilityOfObserved = max(
                prediction.probabilities[example.target, default: 0],
                1e-12
            )
            logLoss += -log(probabilityOfObserved)

            let binIndex = min(calibrationBins.count - 1, Int(confidence * 10))
            calibrationBins[binIndex].count += 1
            calibrationBins[binIndex].confidence += confidence
            calibrationBins[binIndex].correct += isCorrect ? 1 : 0

            if let setID = example.counterfactualSetID {
                counterfactualPredictions[setID, default: []].append(predicted)
            }
        }

        let covered = holdout.count - abstentions.values.reduce(0, +)
        let comparisons = counterfactualPredictions.values.reduce(0) { total, predictions in
            total + max(0, predictions.count * (predictions.count - 1) / 2)
        }
        let sensitiveComparisons = counterfactualPredictions.values.reduce(0) { total, predictions in
            guard predictions.count > 1 else { return total }
            var count = 0
            for left in predictions.indices {
                for right in predictions.indices where right > left {
                    if predictions[left] != predictions[right] { count += 1 }
                }
            }
            return total + count
        }

        let calibrationError: Double? = covered > 0 ? calibrationBins.reduce(0.0) { total, bin in
            guard bin.count > 0 else { return total }
            let averageConfidence = bin.confidence / Double(bin.count)
            let observedAccuracy = Double(bin.correct) / Double(bin.count)
            return total + (Double(bin.count) / Double(covered))
                * abs(averageConfidence - observedAccuracy)
        } : nil

        return SyntheticCausalEvaluationReport(
            evaluationCount: holdout.count,
            coveredCount: covered,
            abstainedCount: holdout.count - covered,
            unseenConditionCount: abstentions[.unseenCondition, default: 0],
            insufficientConfidenceCount: abstentions[.insufficientConfidence, default: 0],
            coverage: holdout.isEmpty ? 0 : Double(covered) / Double(holdout.count),
            accuracy: covered > 0 ? Double(correct) / Double(covered) : nil,
            meanLogLoss: covered > 0 ? logLoss / Double(covered) : nil,
            meanConfidence: covered > 0 ? confidenceTotal / Double(covered) : nil,
            expectedCalibrationError: calibrationError,
            counterfactualComparisonCount: comparisons,
            interventionSensitiveComparisonCount: sensitiveComparisons,
            interventionSensitivityRate: comparisons > 0
                ? Double(sensitiveComparisons) / Double(comparisons)
                : nil,
            drift: AdaptiveCausalDriftEvaluator.evaluate(
                training: training.map(\.evidence),
                holdout: holdout.map(\.evidence)
            )
        )
    }

    private struct CalibrationBin {
        var count = 0
        var confidence = 0.0
        var correct = 0
    }
}

// MARK: - Synthetic operational fixture

private struct SyntheticCausalPattern {
    let feature: SyntheticCausalFeature
    let dominant: SyntheticCausalTarget
    let alternate: SyntheticCausalTarget?
    let alternateEvery: Int?
}

private struct SyntheticCausalFixture {
    let training: [SyntheticCausalExample]
    let stableHoldout: [SyntheticCausalExample]
    let counterfactualHoldout: [SyntheticCausalExample]
    let shiftedHoldout: [SyntheticCausalExample]

    static func make() -> Self {
        let patterns = operationalPatterns
        let training = patterns.enumerated().flatMap { patternIndex, pattern in
            makeExamples(
                pattern: pattern,
                count: 100,
                cohort: "train-\(patternIndex)",
                day: 1
            )
        }
        let stable = patterns.enumerated().flatMap { patternIndex, pattern in
            makeExamples(
                pattern: pattern,
                count: 30,
                cohort: "stable-\(patternIndex)",
                day: 2
            )
        }

        var counterfactual: [SyntheticCausalExample] = []
        let pairs = [(0, 1), (5, 6), (8, 9)]
        for pairIndex in 0..<30 {
            for (left, right) in pairs {
                let setID = "counterfactual-\(left)-\(right)-\(pairIndex)"
                counterfactual.append(makeExample(
                    pattern: patterns[left],
                    target: patterns[left].dominant,
                    cohort: setID,
                    index: 0,
                    day: 3,
                    counterfactualSetID: setID
                ))
                counterfactual.append(makeExample(
                    pattern: patterns[right],
                    target: patterns[right].dominant,
                    cohort: setID,
                    index: 1,
                    day: 3,
                    counterfactualSetID: setID
                ))
            }
        }

        var shifted: [SyntheticCausalExample] = []
        for (offset, patternIndex) in [0, 5, 8].enumerated() {
            let pattern = patterns[patternIndex]
            let reversed = pattern.alternate ?? pattern.dominant
            shifted += (0..<100).map {
                makeExample(
                    pattern: pattern,
                    target: reversed,
                    cohort: "shifted-\(offset)",
                    index: $0,
                    day: 4
                )
            }
        }
        let unseen = SyntheticCausalPattern(
            feature: SyntheticCausalFeature(
                domain: "notification_delivery",
                priorState: "pending",
                intervention: "send",
                expectedEvidence: "delivery_receipt"
            ),
            dominant: SyntheticCausalTarget(nextState: "delivered", outcome: "verified_success"),
            alternate: nil,
            alternateEvery: nil
        )
        shifted += makeExamples(
            pattern: unseen,
            count: 100,
            cohort: "unseen-shift",
            day: 4
        )

        return Self(
            training: training,
            stableHoldout: stable,
            counterfactualHoldout: counterfactual,
            shiftedHoldout: shifted
        )
    }

    private static let operationalPatterns: [SyntheticCausalPattern] = [
        pattern("github_command", "needs_codex", "dispatch_codex", "codex_callback", "codex_working", "accepted", alternate: ("needs_codex", "retryable"), every: 10),
        pattern("github_command", "needs_codex", "wait", "codex_callback", "needs_codex", "waiting"),
        pattern("github_command", "codex_working", "observe_callback", "verification_ready", "verifying", "observed", alternate: ("codex_working", "waiting"), every: 10),
        pattern("github_command", "verifying", "verify_thread", "thread_state", "resolved", "verified_success", alternate: ("needs_codex", "retryable"), every: 10),
        pattern("workshop_execution", "ready", "execute_step", "step_result", "running", "accepted"),
        pattern("workshop_execution", "running", "observe_step", "step_result", "completed", "verified_success", alternate: ("failed", "verified_failure"), every: 5),
        pattern("workshop_execution", "running", "cancel", "cancellation_receipt", "cancelled", "cancelled"),
        pattern("workflow_orchestration", "ready", "start", "step_result", "running", "accepted"),
        pattern("workflow_orchestration", "running", "observe_step", "step_result", "verifying", "observed", alternate: ("failed", "verified_failure"), every: 5),
        pattern("workflow_orchestration", "running", "cancel", "cancellation_receipt", "cancelled", "cancelled"),
    ]

    private static func pattern(
        _ domain: String,
        _ priorState: String,
        _ intervention: String,
        _ expectedEvidence: String,
        _ nextState: String,
        _ outcome: String,
        alternate: (String, String)? = nil,
        every: Int? = nil
    ) -> SyntheticCausalPattern {
        SyntheticCausalPattern(
            feature: SyntheticCausalFeature(
                domain: domain,
                priorState: priorState,
                intervention: intervention,
                expectedEvidence: expectedEvidence
            ),
            dominant: SyntheticCausalTarget(nextState: nextState, outcome: outcome),
            alternate: alternate.map { SyntheticCausalTarget(nextState: $0.0, outcome: $0.1) },
            alternateEvery: every
        )
    }

    private static func makeExamples(
        pattern: SyntheticCausalPattern,
        count: Int,
        cohort: String,
        day: Int
    ) -> [SyntheticCausalExample] {
        (0..<count).map { index in
            let useAlternate = pattern.alternate != nil
                && pattern.alternateEvery.map { index % $0 == 0 } == true
            return makeExample(
                pattern: pattern,
                target: useAlternate ? pattern.alternate! : pattern.dominant,
                cohort: cohort,
                index: index,
                day: day
            )
        }
    }

    private static func makeExample(
        pattern: SyntheticCausalPattern,
        target: SyntheticCausalTarget,
        cohort: String,
        index: Int,
        day: Int,
        counterfactualSetID: String? = nil
    ) -> SyntheticCausalExample {
        let identity = "synthetic-\(cohort)-\(index)"
        let operation = "\(identity)-\(pattern.feature.intervention)"
        let occurredAt = String(format: "2026-07-%02dT12:%02d:00Z", day, index % 60)
        return SyntheticCausalExample(
            feature: pattern.feature,
            target: target,
            evidence: CausalTransitionEvidence(
                domain: pattern.feature.domain,
                operationId: CausalTransitionEvidence.opaqueIdentity(operation),
                occurredAt: occurredAt,
                itemIdentity: CausalTransitionEvidence.opaqueIdentity(identity),
                kind: pattern.feature.intervention,
                beforeState: pattern.feature.priorState,
                afterState: target.nextState,
                expectedNextEvidence: pattern.feature.expectedEvidence,
                outcome: target.outcome
            ),
            counterfactualSetID: counterfactualSetID
        )
    }
}
