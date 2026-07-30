import CryptoKit
import Foundation
import PersistenceCore

/// Test/frozen-evaluation authority only. There is intentionally no public or
/// package factory for personal controlled-production evidence in this wave.
/// Adding one later requires an ApprovalInbox-bound, schema-versioned privacy
/// review rather than a Boolean passed by a caller.
public struct CausalOperationalSelfModelAuthorization: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable {
        case generatedAndFrozen = "generated_and_frozen"
    }

    public let scope: Scope

    private init(scope: Scope) {
        self.scope = scope
    }

    static let generatedAndFrozen = Self(scope: .generatedAndFrozen)
}

public enum CausalOperationalSelfModelError: String, Error, Sendable, Equatable {
    case controlledProductionNotAuthorized = "controlled_production_not_authorized"
    case noControlledEvidence = "no_controlled_evidence"
}

public struct CausalOperationalSelfModelConfiguration: Sendable, Equatable {
    public var maximumTrainingRows: Int
    public var maximumValidationRows: Int
    public var maximumRules: Int
    public var maximumArtifactTransitionIDs: Int
    public var minimumArmSupport: Int
    public var betaPriorAlpha: Double
    public var betaPriorBeta: Double
    public var maximumPosteriorIntervalWidth: Double
    public var minimumDriftSampleCount: Int
    public var maximumAllowedDrift: Double

    public init(
        maximumTrainingRows: Int = 50_000,
        maximumValidationRows: Int = 20_000,
        maximumRules: Int = 4_096,
        maximumArtifactTransitionIDs: Int = 50_000,
        minimumArmSupport: Int = 10,
        betaPriorAlpha: Double = 1,
        betaPriorBeta: Double = 1,
        maximumPosteriorIntervalWidth: Double = 0.50,
        minimumDriftSampleCount: Int = 30,
        maximumAllowedDrift: Double = 0.20
    ) {
        self.maximumTrainingRows = min(100_000, max(1, maximumTrainingRows))
        self.maximumValidationRows = min(100_000, max(1, maximumValidationRows))
        self.maximumRules = min(16_384, max(1, maximumRules))
        self.maximumArtifactTransitionIDs = min(100_000, max(1, maximumArtifactTransitionIDs))
        self.minimumArmSupport = min(10_000, max(1, minimumArmSupport))
        self.betaPriorAlpha = min(1_000, max(0.000_001, betaPriorAlpha))
        self.betaPriorBeta = min(1_000, max(0.000_001, betaPriorBeta))
        self.maximumPosteriorIntervalWidth = min(1, max(0, maximumPosteriorIntervalWidth))
        self.minimumDriftSampleCount = min(100_000, max(1, minimumDriftSampleCount))
        self.maximumAllowedDrift = min(1, max(0, maximumAllowedDrift))
    }

    public static let `default` = Self()
}

/// Exact conditional stratum. It contains bounded categorical facts only; no
/// message, tool output, objective text, path, or generated self-description.
public struct CausalOperationalCondition: Codable, Hashable, Sendable, Equatable {
    public let domain: String
    public let taskScenarioFamily: String
    public let beforeState: String
    public let expectedNextEvidence: String
    public let treatment: String
    public let baseline: String

    public init(
        domain: String,
        taskScenarioFamily: String,
        beforeState: String,
        expectedNextEvidence: String,
        treatment: String,
        baseline: String
    ) {
        self.domain = domain
        self.taskScenarioFamily = taskScenarioFamily
        self.beforeState = beforeState
        self.expectedNextEvidence = expectedNextEvidence
        self.treatment = treatment
        self.baseline = baseline
    }
}

public struct CausalBayesianProbability: Codable, Sendable, Equatable {
    public let positiveCount: Int
    public let sampleCount: Int
    public let posteriorMean: Double
    public let lower95: Double
    public let upper95: Double

    public var intervalWidth: Double { upper95 - lower95 }
}

/// Operational self-knowledge is numeric and evidence-backed. It never uses a
/// generated first-person explanation as evidence.
public struct CausalOperationalSelfOutput: Codable, Sendable, Equatable {
    public let capabilitySuccess: CausalBayesianProbability
    public let correctionOrOverclaim: CausalBayesianProbability
    public let contextRequired: CausalBayesianProbability
    public let providerOrToolCompletion: CausalBayesianProbability?
    public let evidenceTransitionIDs: [String]
}

public enum CausalOperationalAbstentionReason: String, Codable, Sendable, Equatable {
    case unseenCondition = "unseen_condition"
    case unseenAlternative = "unseen_alternative"
    case insufficientSupport = "insufficient_support"
    case lowConfidence = "low_confidence"
    case driftEvidenceInsufficient = "drift_evidence_insufficient"
    case distributionShift = "distribution_shift"
}

public struct CausalOperationalPrediction: Sendable, Equatable {
    public let condition: CausalOperationalCondition
    public let chosenAlternative: String
    public let output: CausalOperationalSelfOutput?
    public let abstentionReason: CausalOperationalAbstentionReason?
    public let explanationTransitionIDs: [String]
    public let advisoryOnly: Bool
    public let promptAuthority: Bool
    public let actionAuthority: Bool
    public let permissionAuthority: Bool
    public let identityAuthority: Bool
    public let memoryAuthority: Bool
    public let adaptiveInfluenceAuthority: Bool

    public var covered: Bool { output != nil && abstentionReason == nil }
}

public struct CausalOperationalEffectEstimate: Codable, Sendable, Equatable {
    public let condition: CausalOperationalCondition
    public let treatmentProbability: CausalBayesianProbability
    public let baselineProbability: CausalBayesianProbability
    public let posteriorRiskDifference: Double
    public let lower95: Double
    public let upper95: Double
    public let treatmentTransitionIDs: [String]
    public let baselineTransitionIDs: [String]
    public let causalClaimEligible: Bool
}

public struct CausalOperationalDriftArtifact: Codable, Sendable, Equatable {
    public let schema: String
    public let trainingCount: Int
    public let validationCount: Int
    public let jensenShannonDivergence: Double?
    public let maximumAllowedDivergence: Double
    public let status: String
}

public struct CausalOperationalCalibrationArtifact: Codable, Sendable, Equatable {
    public let schema: String
    public let evaluatedCount: Int
    public let coveredCount: Int
    public let abstainedCount: Int
    public let brierScore: Double?
    public let meanLogLoss: Double?
    public let expectedCalibrationError: Double?
    public let drift: CausalOperationalDriftArtifact
}

/// Immutable evaluation product. It is keyed to opaque transition identities
/// and can be rederived; it is not a canonical outcome or model-authority log.
public struct CausalOperationalSelfModelArtifact: Codable, Sendable, Equatable {
    public static let schemaVersion = "causal-operational-self-model-artifact.v1"

    public let schema: String
    public let modelVersion: String
    public let transitionSchemaVersion: String
    public let artifactID: String
    public let modelFingerprintSHA256: String
    public let trainingTransitionIDs: [String]
    public let validationTransitionIDs: [String]
    public let acceptedTrainingCount: Int
    public let acceptedValidationCount: Int
    public let excludedObservationalCount: Int
    public let invalidControlledCount: Int
    public let duplicateCount: Int
    public let conflictingDuplicateCount: Int
    public let rowLimitDropCount: Int
    public let ruleLimitDropCount: Int
    public let controlledEvidenceSources: [String]
    public let effects: [CausalOperationalEffectEstimate]
    public let calibration: CausalOperationalCalibrationArtifact
    public let associationOnlyForObservationalRows: Bool
    public let personalProductionEnabled: Bool
    public let promptAuthority: Bool
    public let actionAuthority: Bool
    public let permissionAuthority: Bool
    public let identityAuthority: Bool
    public let memoryAuthority: Bool
    public let adaptiveInfluenceEnabled: Bool
}

/// Bounded, deterministic conditional/Bayesian model over controlled outcome
/// transitions. It does not read files, call providers, write prompts, select
/// tools, alter policy, or mutate any canonical state.
public struct CausalOperationalSelfModel: Sendable {
    public static let modelVersion = "beta-conditional-operational-self.v1"
    public static let transitionSchemaVersion = "causal-transition-evidence.v2"

    fileprivate struct Arm: Sendable {
        let sampleCount: Int
        let capabilitySuccesses: Int
        let correctionOrOverclaimCount: Int
        let contextRequiredCount: Int
        let providerOrToolCompletionCount: Int
        let transitionIDs: [String]
    }

    fileprivate struct Rule: Sendable {
        let treatment: Arm?
        let baseline: Arm?
    }

    private let rules: [CausalOperationalCondition: Rule]
    private let driftStatus: AdaptiveCausalDriftStatus
    public let configuration: CausalOperationalSelfModelConfiguration
    public let artifact: CausalOperationalSelfModelArtifact

    public static func fit(
        training: [CausalTransitionEvidence],
        validation: [CausalTransitionEvidence],
        authorization: CausalOperationalSelfModelAuthorization,
        configuration: CausalOperationalSelfModelConfiguration = .default
    ) throws -> Self {
        _ = authorization
        if training.contains(where: { $0.evidenceClass == .controlledProduction })
            || validation.contains(where: { $0.evidenceClass == .controlledProduction }) {
            throw CausalOperationalSelfModelError.controlledProductionNotAuthorized
        }

        let normalizedTraining = normalizeControlled(training)
        let normalizedValidation = normalizeControlled(validation)
        guard !normalizedTraining.rows.isEmpty else {
            throw CausalOperationalSelfModelError.noControlledEvidence
        }

        let orderedTraining = normalizedTraining.rows.sorted(by: rowOrder)
        let retainedTraining = Array(orderedTraining.suffix(configuration.maximumTrainingRows))
        let trainingDrops = orderedTraining.count - retainedTraining.count
        let orderedValidation = normalizedValidation.rows.sorted(by: rowOrder)
        let retainedValidation = Array(orderedValidation.suffix(configuration.maximumValidationRows))
        let validationDrops = orderedValidation.count - retainedValidation.count

        let grouped = Dictionary(grouping: retainedTraining, by: \.condition)
        let rankedConditions = grouped.keys.sorted {
            let left = grouped[$0]?.count ?? 0
            let right = grouped[$1]?.count ?? 0
            if left != right { return left > right }
            return conditionKey($0) < conditionKey($1)
        }
        let retainedConditions = Array(rankedConditions.prefix(configuration.maximumRules))
        let droppedRules = rankedConditions.dropFirst(configuration.maximumRules)
        let ruleDrops = droppedRules.reduce(0) { $0 + (grouped[$1]?.count ?? 0) }

        var rules: [CausalOperationalCondition: Rule] = [:]
        for condition in retainedConditions {
            let rows = grouped[condition] ?? []
            rules[condition] = Rule(
                treatment: makeArm(
                    rows.filter { $0.chosenAlternative == condition.treatment }
                ),
                baseline: makeArm(
                    rows.filter { $0.chosenAlternative == condition.baseline }
                )
            )
        }

        let drift = AdaptiveCausalDriftEvaluator.evaluate(
            training: retainedTraining.map(\.evidence),
            holdout: retainedValidation.map(\.evidence),
            minimumSampleCount: configuration.minimumDriftSampleCount,
            maximumAllowedDivergence: configuration.maximumAllowedDrift
        )
        let calibration = calibrationArtifact(
            validation: retainedValidation,
            rules: rules,
            configuration: configuration,
            drift: drift
        )
        let effects = retainedConditions.compactMap { condition -> CausalOperationalEffectEstimate? in
            guard let rule = rules[condition],
                  let treatment = rule.treatment,
                  let baseline = rule.baseline else { return nil }
            return effectEstimate(
                condition: condition,
                treatment: treatment,
                baseline: baseline,
                configuration: configuration,
                driftStatus: drift.status
            )
        }.sorted { conditionKey($0.condition) < conditionKey($1.condition) }

        let trainingIDs = Array(retainedTraining.map(\.transitionID).sorted()
            .prefix(configuration.maximumArtifactTransitionIDs))
        let validationIDs = Array(retainedValidation.map(\.transitionID).sorted()
            .prefix(configuration.maximumArtifactTransitionIDs))
        let sources = Set((retainedTraining + retainedValidation).map(\.sourceClass)).sorted()
        let fingerprint = modelFingerprint(
            rules: rules,
            configuration: configuration,
            drift: drift,
            trainingIDs: trainingIDs,
            validationIDs: validationIDs
        )
        let artifactID = digest([
            CausalOperationalSelfModelArtifact.schemaVersion,
            modelVersion,
            transitionSchemaVersion,
            fingerprint,
            trainingIDs.joined(separator: ","),
            validationIDs.joined(separator: ","),
        ].joined(separator: "\n"))
        let artifact = CausalOperationalSelfModelArtifact(
            schema: CausalOperationalSelfModelArtifact.schemaVersion,
            modelVersion: modelVersion,
            transitionSchemaVersion: transitionSchemaVersion,
            artifactID: artifactID,
            modelFingerprintSHA256: fingerprint,
            trainingTransitionIDs: trainingIDs,
            validationTransitionIDs: validationIDs,
            acceptedTrainingCount: retainedTraining.count,
            acceptedValidationCount: retainedValidation.count,
            excludedObservationalCount: normalizedTraining.observationalCount
                + normalizedValidation.observationalCount,
            invalidControlledCount: normalizedTraining.invalidControlledCount
                + normalizedValidation.invalidControlledCount,
            duplicateCount: normalizedTraining.duplicateCount + normalizedValidation.duplicateCount,
            conflictingDuplicateCount: normalizedTraining.conflictingDuplicateCount
                + normalizedValidation.conflictingDuplicateCount,
            rowLimitDropCount: trainingDrops + validationDrops,
            ruleLimitDropCount: ruleDrops,
            controlledEvidenceSources: sources,
            effects: effects,
            calibration: calibration,
            associationOnlyForObservationalRows: true,
            personalProductionEnabled: false,
            promptAuthority: false,
            actionAuthority: false,
            permissionAuthority: false,
            identityAuthority: false,
            memoryAuthority: false,
            adaptiveInfluenceEnabled: false
        )
        return Self(
            rules: rules,
            driftStatus: drift.status,
            configuration: configuration,
            artifact: artifact
        )
    }

    public func predict(
        condition: CausalOperationalCondition,
        chosenAlternative: String
    ) -> CausalOperationalPrediction {
        guard let rule = rules[condition] else {
            return abstention(condition, chosenAlternative, .unseenCondition)
        }
        let arm: Arm?
        if chosenAlternative == condition.treatment {
            arm = rule.treatment
        } else if chosenAlternative == condition.baseline {
            arm = rule.baseline
        } else {
            return abstention(condition, chosenAlternative, .unseenAlternative)
        }
        guard let arm, arm.sampleCount >= configuration.minimumArmSupport else {
            return abstention(condition, chosenAlternative, .insufficientSupport)
        }
        let capability = probability(
            positives: arm.capabilitySuccesses,
            total: arm.sampleCount,
            configuration: configuration
        )
        guard capability.intervalWidth <= configuration.maximumPosteriorIntervalWidth else {
            return abstention(
                condition,
                chosenAlternative,
                .lowConfidence,
                explanationIDs: arm.transitionIDs
            )
        }
        switch driftStatus {
        case .insufficientSamples:
            return abstention(
                condition,
                chosenAlternative,
                .driftEvidenceInsufficient,
                explanationIDs: arm.transitionIDs
            )
        case .shifted:
            return abstention(
                condition,
                chosenAlternative,
                .distributionShift,
                explanationIDs: arm.transitionIDs
            )
        case .withinLimit:
            break
        }

        let providerOrTool = isProviderOrToolDomain(condition.domain)
            ? probability(
                positives: arm.providerOrToolCompletionCount,
                total: arm.sampleCount,
                configuration: configuration
            ) : nil
        let output = CausalOperationalSelfOutput(
            capabilitySuccess: capability,
            correctionOrOverclaim: probability(
                positives: arm.correctionOrOverclaimCount,
                total: arm.sampleCount,
                configuration: configuration
            ),
            contextRequired: probability(
                positives: arm.contextRequiredCount,
                total: arm.sampleCount,
                configuration: configuration
            ),
            providerOrToolCompletion: providerOrTool,
            evidenceTransitionIDs: arm.transitionIDs
        )
        return CausalOperationalPrediction(
            condition: condition,
            chosenAlternative: chosenAlternative,
            output: output,
            abstentionReason: nil,
            explanationTransitionIDs: arm.transitionIDs,
            advisoryOnly: true,
            promptAuthority: false,
            actionAuthority: false,
            permissionAuthority: false,
            identityAuthority: false,
            memoryAuthority: false,
            adaptiveInfluenceAuthority: false
        )
    }

    public func effect(for condition: CausalOperationalCondition) -> CausalOperationalEffectEstimate? {
        artifact.effects.first { $0.condition == condition }
    }

    private func abstention(
        _ condition: CausalOperationalCondition,
        _ chosenAlternative: String,
        _ reason: CausalOperationalAbstentionReason,
        explanationIDs: [String] = []
    ) -> CausalOperationalPrediction {
        CausalOperationalPrediction(
            condition: condition,
            chosenAlternative: chosenAlternative,
            output: nil,
            abstentionReason: reason,
            explanationTransitionIDs: explanationIDs,
            advisoryOnly: true,
            promptAuthority: false,
            actionAuthority: false,
            permissionAuthority: false,
            identityAuthority: false,
            memoryAuthority: false,
            adaptiveInfluenceAuthority: false
        )
    }
}

// MARK: - Normalization

private struct CausalControlledRow: Sendable, Equatable {
    let evidence: CausalTransitionEvidence
    let transitionID: String
    let condition: CausalOperationalCondition
    let chosenAlternative: String
    let sourceClass: String
    let capabilitySuccess: Bool
    let correctionOrOverclaim: Bool
    let contextRequired: Bool
    let providerOrToolCompletion: Bool
}

private struct CausalControlledNormalization {
    let rows: [CausalControlledRow]
    let observationalCount: Int
    let invalidControlledCount: Int
    let duplicateCount: Int
    let conflictingDuplicateCount: Int
}

private func normalizeControlled(
    _ transitions: [CausalTransitionEvidence]
) -> CausalControlledNormalization {
    struct Key: Hashable {
        let domain: String
        let operationID: String
    }
    var rows: [Key: CausalControlledRow] = [:]
    var conflicted: Set<Key> = []
    var observational = 0
    var invalid = 0
    var duplicate = 0

    for evidence in transitions {
        guard evidence.evidenceClass != .observational else {
            observational += 1
            continue
        }
        guard evidence.evidenceClass == .controlledSynthetic,
              let row = controlledRow(evidence) else {
            invalid += 1
            continue
        }
        let key = Key(domain: evidence.domain, operationID: evidence.operationId)
        guard !conflicted.contains(key) else {
            invalid += 1
            continue
        }
        if let prior = rows[key] {
            if prior == row {
                duplicate += 1
            } else {
                rows.removeValue(forKey: key)
                conflicted.insert(key)
            }
        } else {
            rows[key] = row
        }
    }
    return CausalControlledNormalization(
        rows: Array(rows.values),
        observationalCount: observational,
        invalidControlledCount: invalid,
        duplicateCount: duplicate,
        conflictingDuplicateCount: conflicted.count
    )
}

private func controlledRow(_ evidence: CausalTransitionEvidence) -> CausalControlledRow? {
    guard causalToken(evidence.domain, maximum: 64),
          causalSHA(evidence.operationId),
          causalSHA(evidence.itemIdentity),
          causalDate(evidence.occurredAt) != nil,
          causalToken(evidence.kind, maximum: 96),
          causalOptionalToken(evidence.beforeState, maximum: 96),
          causalOptionalToken(evidence.afterState, maximum: 96),
          causalOptionalToken(evidence.expectedNextEvidence, maximum: 96),
          causalToken(evidence.outcome, maximum: 96),
          evidence.completenessClass == "complete",
          let assignment = evidence.interventionAssignment,
          causalToken(assignment.assignmentID, maximum: 128),
          causalToken(assignment.intervention, maximum: 96),
          let experimentID = assignment.experimentID,
          causalToken(experimentID, maximum: 128),
          let family = assignment.taskScenarioFamily,
          causalToken(family, maximum: 96),
          let treatment = assignment.treatment,
          causalToken(treatment, maximum: 96),
          let baseline = assignment.baseline,
          causalToken(baseline, maximum: 96),
          treatment != baseline,
          assignment.intervention == treatment,
          let alternatives = assignment.eligibleAlternatives,
          (2...16).contains(alternatives.count),
          Set(alternatives).count == alternatives.count,
          alternatives.allSatisfy({ causalToken($0, maximum: 96) }),
          alternatives.contains(treatment),
          alternatives.contains(baseline),
          let chosen = assignment.chosenAlternative,
          chosen == treatment || chosen == baseline,
          alternatives.contains(chosen),
          let confounders = assignment.confounderFlags,
          confounders.isEmpty,
          let coverage = assignment.coverageFlags,
          (1...16).contains(coverage.count),
          coverage.allSatisfy({ causalToken($0, maximum: 64) }),
          coverage.contains("complete"),
          Set(coverage).isDisjoint(with: ["censored", "incomplete", "ambiguous", "confounded"])
    else { return nil }

    let tokens = Set([
        evidence.kind,
        evidence.outcome,
        evidence.afterState ?? "none",
        evidence.terminalClass ?? "none",
        evidence.verificationClass ?? "none",
    ])
    let successTokens: Set<String> = [
        "verified_success", "succeeded", "success", "completed", "resolved", "delivered",
    ]
    let correctionTokens: Set<String> = [
        "correction", "corrected", "overclaim", "overclaimed", "negative_feedback",
    ]
    let contextTokens: Set<String> = [
        "context_required", "missing_context", "context_expansion_required",
    ]
    let success = !tokens.isDisjoint(with: successTokens)
    return CausalControlledRow(
        evidence: evidence,
        transitionID: evidence.operationId,
        condition: CausalOperationalCondition(
            domain: evidence.domain,
            taskScenarioFamily: family,
            beforeState: evidence.beforeState ?? "none",
            expectedNextEvidence: evidence.expectedNextEvidence ?? "none",
            treatment: treatment,
            baseline: baseline
        ),
        chosenAlternative: chosen,
        sourceClass: assignment.evidenceClass.rawValue,
        capabilitySuccess: success,
        correctionOrOverclaim: !tokens.isDisjoint(with: correctionTokens),
        contextRequired: !tokens.isDisjoint(with: contextTokens),
        providerOrToolCompletion: isProviderOrToolDomain(evidence.domain) && success
    )
}

private func makeArm(_ rows: [CausalControlledRow]) -> CausalOperationalSelfModel.Arm? {
    guard !rows.isEmpty else { return nil }
    return CausalOperationalSelfModel.Arm(
        sampleCount: rows.count,
        capabilitySuccesses: rows.count(where: \.capabilitySuccess),
        correctionOrOverclaimCount: rows.count(where: \.correctionOrOverclaim),
        contextRequiredCount: rows.count(where: \.contextRequired),
        providerOrToolCompletionCount: rows.count(where: \.providerOrToolCompletion),
        transitionIDs: rows.map(\.transitionID).sorted()
    )
}

private func probability(
    positives: Int,
    total: Int,
    configuration: CausalOperationalSelfModelConfiguration
) -> CausalBayesianProbability {
    let alpha = configuration.betaPriorAlpha + Double(positives)
    let beta = configuration.betaPriorBeta + Double(max(0, total - positives))
    let sum = alpha + beta
    let mean = alpha / sum
    let variance = alpha * beta / (sum * sum * (sum + 1))
    let radius = 1.959_963_984_540_054 * sqrt(max(0, variance))
    return CausalBayesianProbability(
        positiveCount: positives,
        sampleCount: total,
        posteriorMean: mean,
        lower95: max(0, mean - radius),
        upper95: min(1, mean + radius)
    )
}

private func effectEstimate(
    condition: CausalOperationalCondition,
    treatment: CausalOperationalSelfModel.Arm,
    baseline: CausalOperationalSelfModel.Arm,
    configuration: CausalOperationalSelfModelConfiguration,
    driftStatus: AdaptiveCausalDriftStatus
) -> CausalOperationalEffectEstimate {
    let treated = probability(
        positives: treatment.capabilitySuccesses,
        total: treatment.sampleCount,
        configuration: configuration
    )
    let control = probability(
        positives: baseline.capabilitySuccesses,
        total: baseline.sampleCount,
        configuration: configuration
    )
    let difference = treated.posteriorMean - control.posteriorMean
    let treatmentRadius = (treated.upper95 - treated.lower95) / 2
    let baselineRadius = (control.upper95 - control.lower95) / 2
    let differenceRadius = sqrt(treatmentRadius * treatmentRadius + baselineRadius * baselineRadius)
    let eligible = treatment.sampleCount >= configuration.minimumArmSupport
        && baseline.sampleCount >= configuration.minimumArmSupport
        && driftStatus == .withinLimit
    return CausalOperationalEffectEstimate(
        condition: condition,
        treatmentProbability: treated,
        baselineProbability: control,
        posteriorRiskDifference: difference,
        lower95: max(-1, difference - differenceRadius),
        upper95: min(1, difference + differenceRadius),
        treatmentTransitionIDs: treatment.transitionIDs,
        baselineTransitionIDs: baseline.transitionIDs,
        causalClaimEligible: eligible
    )
}

private func calibrationArtifact(
    validation: [CausalControlledRow],
    rules: [CausalOperationalCondition: CausalOperationalSelfModel.Rule],
    configuration: CausalOperationalSelfModelConfiguration,
    drift: AdaptiveCausalDriftEvaluation
) -> CausalOperationalCalibrationArtifact {
    struct Bin {
        var count = 0
        var probabilityTotal = 0.0
        var observedTotal = 0
    }
    var covered = 0
    var brier = 0.0
    var logLoss = 0.0
    var bins = Array(repeating: Bin(), count: 10)
    for row in validation {
        guard let rule = rules[row.condition] else { continue }
        let arm = row.chosenAlternative == row.condition.treatment ? rule.treatment : rule.baseline
        guard let arm, arm.sampleCount >= configuration.minimumArmSupport else { continue }
        let estimate = probability(
            positives: arm.capabilitySuccesses,
            total: arm.sampleCount,
            configuration: configuration
        )
        guard estimate.intervalWidth <= configuration.maximumPosteriorIntervalWidth else { continue }
        let observed = row.capabilitySuccess ? 1.0 : 0.0
        covered += 1
        brier += pow(estimate.posteriorMean - observed, 2)
        let observedProbability = row.capabilitySuccess
            ? estimate.posteriorMean
            : 1 - estimate.posteriorMean
        logLoss += -log(max(1e-12, observedProbability))
        let index = min(9, Int(estimate.posteriorMean * 10))
        bins[index].count += 1
        bins[index].probabilityTotal += estimate.posteriorMean
        bins[index].observedTotal += row.capabilitySuccess ? 1 : 0
    }
    let ece = covered > 0 ? bins.reduce(0.0) { partial, bin in
        guard bin.count > 0 else { return partial }
        let predicted = bin.probabilityTotal / Double(bin.count)
        let observed = Double(bin.observedTotal) / Double(bin.count)
        return partial + Double(bin.count) / Double(covered) * abs(predicted - observed)
    } : nil
    return CausalOperationalCalibrationArtifact(
        schema: "causal-operational-calibration.v1",
        evaluatedCount: validation.count,
        coveredCount: covered,
        abstainedCount: validation.count - covered,
        brierScore: covered > 0 ? brier / Double(covered) : nil,
        meanLogLoss: covered > 0 ? logLoss / Double(covered) : nil,
        expectedCalibrationError: ece,
        drift: CausalOperationalDriftArtifact(
            schema: drift.schema,
            trainingCount: drift.trainingCount,
            validationCount: drift.holdoutCount,
            jensenShannonDivergence: drift.jensenShannonDivergence,
            maximumAllowedDivergence: drift.maximumAllowedDivergence,
            status: drift.status.rawValue
        )
    )
}

private func modelFingerprint(
    rules: [CausalOperationalCondition: CausalOperationalSelfModel.Rule],
    configuration: CausalOperationalSelfModelConfiguration,
    drift: AdaptiveCausalDriftEvaluation,
    trainingIDs: [String],
    validationIDs: [String]
) -> String {
    var lines = [
        CausalOperationalSelfModel.modelVersion,
        CausalOperationalSelfModel.transitionSchemaVersion,
        "minimum_arm_support=\(configuration.minimumArmSupport)",
        "alpha=\(configuration.betaPriorAlpha)",
        "beta=\(configuration.betaPriorBeta)",
        "drift=\(drift.status.rawValue)",
    ]
    for condition in rules.keys.sorted(by: { conditionKey($0) < conditionKey($1) }) {
        guard let rule = rules[condition] else { continue }
        lines.append("condition=\(conditionKey(condition))")
        if let treatment = rule.treatment {
            lines.append("treatment=\(armKey(treatment))")
        }
        if let baseline = rule.baseline {
            lines.append("baseline=\(armKey(baseline))")
        }
    }
    lines.append("training=\(trainingIDs.joined(separator: ","))")
    lines.append("validation=\(validationIDs.joined(separator: ","))")
    return digest(lines.joined(separator: "\n"))
}

private func armKey(_ arm: CausalOperationalSelfModel.Arm) -> String {
    [
        String(arm.sampleCount),
        String(arm.capabilitySuccesses),
        String(arm.correctionOrOverclaimCount),
        String(arm.contextRequiredCount),
        String(arm.providerOrToolCompletionCount),
        arm.transitionIDs.joined(separator: ","),
    ].joined(separator: "|")
}

private func rowOrder(_ lhs: CausalControlledRow, _ rhs: CausalControlledRow) -> Bool {
    let left = causalDate(lhs.evidence.occurredAt) ?? .distantPast
    let right = causalDate(rhs.evidence.occurredAt) ?? .distantPast
    if left != right { return left < right }
    if lhs.condition != rhs.condition { return conditionKey(lhs.condition) < conditionKey(rhs.condition) }
    return lhs.transitionID < rhs.transitionID
}

private func conditionKey(_ condition: CausalOperationalCondition) -> String {
    [
        condition.domain,
        condition.taskScenarioFamily,
        condition.beforeState,
        condition.expectedNextEvidence,
        condition.treatment,
        condition.baseline,
    ].joined(separator: "|")
}

private func isProviderOrToolDomain(_ domain: String) -> Bool {
    let domains: Set<String> = [
        "provider", "provider_call", "tool", "tool_dispatch", "mac_control",
        "browser", "workflow", "workshop_execution", "github_command",
    ]
    return domains.contains(domain)
}

private func causalToken(_ value: String, maximum: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximum else { return false }
    return value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57)
            || ($0 >= 97 && $0 <= 122)
            || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 58
    }
}

private func causalOptionalToken(_ value: String?, maximum: Int) -> Bool {
    value.map { causalToken($0, maximum: maximum) } ?? true
}

private func causalSHA(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}

private func causalDate(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let ordinary = ISO8601DateFormatter()
    ordinary.formatOptions = [.withInternetDateTime]
    return ordinary.date(from: raw)
}

private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
