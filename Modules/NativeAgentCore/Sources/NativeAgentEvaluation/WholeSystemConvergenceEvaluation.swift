import CryptoKit
import Foundation
import PersistenceCore

/// Wave 12's evaluator is a pure, payload-free read model. It accepts exact
/// numbers from generated, frozen, or explicitly authorized live harnesses and
/// never opens a data root, calls a provider, mutates Agent, or grants control.
public enum WholeSystemAblation: String, Codable, CaseIterable, Sendable {
    case organismBodyProjectionRemoved = "organism_body_projection_removed"
    case usedMemoryReturnEdgeRemoved = "used_memory_return_edge_removed"
    case contextUtilityShuffled = "context_utility_shuffled"
    case causalModelRemoved = "causal_model_removed"
    case residualRepairDisabled = "residual_repair_disabled"
    case compiledProcedureDisabled = "compiled_procedure_disabled"
    case providerSwapped = "provider_swapped"
    case deviceBeliefStaleUnknown = "device_belief_stale_unknown"
    case dreamProviderLaneDisabledLocalRepairRemains = "dream_provider_lane_disabled_local_repair_remains"
}

public enum WholeSystemMetric: String, Codable, CaseIterable, Sendable {
    case taskSuccess = "task_success"
    case falseCompletion = "false_completion"
    case correctionRate = "correction_rate"
    case latencyMilliseconds = "latency_milliseconds"
    case providerCalls = "provider_calls"
    case contextRelevance = "context_relevance"
    case actionVerification = "action_verification"
    case identityContractAdherence = "identity_contract_adherence"
    case userTrustSignal = "user_trust_signal"

    fileprivate var higherIsBetter: Bool {
        switch self {
        case .falseCompletion, .correctionRate, .latencyMilliseconds, .providerCalls:
            false
        default:
            true
        }
    }

    fileprivate func accepts(_ value: Double) -> Bool {
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

public enum WholeSystemEvidenceClass: String, Codable, Sendable {
    case generatedDeterministic = "generated_deterministic"
    case frozenControlled = "frozen_controlled"
    case installedMatchedAggregate = "installed_matched_aggregate"
    case authorizedPersonalOutcome = "authorized_personal_outcome"
}

/// Payload-free accounting of what one executable ablation arm actually did.
/// These values are supplied by the domain adapter, bound into the harness run
/// digest, and aggregated by the evaluator. They replace the previous
/// hard-coded claim that every evaluation used zero providers and had no
/// authority regardless of how its measurements were produced.
public struct WholeSystemExecutionEffects: Codable, Sendable, Equatable {
    public static let maximumCount = 1_000_000

    public let providerCallCount: Int
    public let canonicalStateMutationCount: Int
    public let promptAuthority: Bool
    public let actionAuthority: Bool
    public let permissionAuthority: Bool
    public let identityAuthority: Bool
    public let memoryAuthority: Bool
    public let adaptiveInfluenceAuthority: Bool

    public init(
        providerCallCount: Int = 0,
        canonicalStateMutationCount: Int = 0,
        promptAuthority: Bool = false,
        actionAuthority: Bool = false,
        permissionAuthority: Bool = false,
        identityAuthority: Bool = false,
        memoryAuthority: Bool = false,
        adaptiveInfluenceAuthority: Bool = false
    ) {
        self.providerCallCount = providerCallCount
        self.canonicalStateMutationCount = canonicalStateMutationCount
        self.promptAuthority = promptAuthority
        self.actionAuthority = actionAuthority
        self.permissionAuthority = permissionAuthority
        self.identityAuthority = identityAuthority
        self.memoryAuthority = memoryAuthority
        self.adaptiveInfluenceAuthority = adaptiveInfluenceAuthority
    }

    public static let noControl = WholeSystemExecutionEffects()

    public var hasControlAuthority: Bool {
        promptAuthority || actionAuthority || permissionAuthority
            || identityAuthority || memoryAuthority || adaptiveInfluenceAuthority
    }

    package var isStructurallyValid: Bool {
        (0...Self.maximumCount).contains(providerCallCount)
            && (0...Self.maximumCount).contains(canonicalStateMutationCount)
    }

    package func adding(_ other: Self) -> Self? {
        guard isStructurallyValid, other.isStructurallyValid else { return nil }
        let (providerCalls, providerOverflow) = providerCallCount.addingReportingOverflow(
            other.providerCallCount
        )
        let (mutations, mutationOverflow) = canonicalStateMutationCount.addingReportingOverflow(
            other.canonicalStateMutationCount
        )
        guard !providerOverflow, !mutationOverflow,
              providerCalls <= Self.maximumCount,
              mutations <= Self.maximumCount else { return nil }
        return Self(
            providerCallCount: providerCalls,
            canonicalStateMutationCount: mutations,
            promptAuthority: promptAuthority || other.promptAuthority,
            actionAuthority: actionAuthority || other.actionAuthority,
            permissionAuthority: permissionAuthority || other.permissionAuthority,
            identityAuthority: identityAuthority || other.identityAuthority,
            memoryAuthority: memoryAuthority || other.memoryAuthority,
            adaptiveInfluenceAuthority: adaptiveInfluenceAuthority || other.adaptiveInfluenceAuthority
        )
    }
}

public enum WholeSystemObservationStatus: String, Codable, Sendable {
    case measured
    case missing
    case censored
}

public enum WholeSystemEvidenceGap: String, Codable, Sendable {
    case notSupplied = "not_supplied"
    case unavailable
    case privacyExcluded = "privacy_excluded"
    case authorityExcluded = "authority_excluded"
    case belowDisclosureThreshold = "below_disclosure_threshold"
    case transportFailed = "transport_failed"
}

/// Values are paired trials in deterministic order, not a prose-derived score.
/// Missing and censored observations carry no number and are never imputed.
public struct WholeSystemMetricObservation: Codable, Sendable, Equatable {
    public static let maximumTrialValues = 256

    public let metric: WholeSystemMetric
    public let status: WholeSystemObservationStatus
    public let values: [Double]
    public let gap: WholeSystemEvidenceGap?

    public init(
        metric: WholeSystemMetric,
        status: WholeSystemObservationStatus,
        values: [Double] = [],
        gap: WholeSystemEvidenceGap? = nil
    ) {
        self.metric = metric
        self.status = status
        self.values = values
        self.gap = gap
    }

    public static func measured(_ metric: WholeSystemMetric, _ values: [Double]) -> Self {
        Self(metric: metric, status: .measured, values: values)
    }

    public static func missing(_ metric: WholeSystemMetric, reason: WholeSystemEvidenceGap) -> Self {
        Self(metric: metric, status: .missing, gap: reason)
    }

    public static func censored(_ metric: WholeSystemMetric, reason: WholeSystemEvidenceGap) -> Self {
        Self(metric: metric, status: .censored, gap: reason)
    }
}

public struct WholeSystemMetricSet: Codable, Sendable, Equatable {
    public let observations: [WholeSystemMetricObservation]

    public init(observations: [WholeSystemMetricObservation]) {
        self.observations = observations.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }
}

public enum WholeSystemClaimMode: String, Codable, Sendable {
    /// Removing the faculty must repeatedly worsen its declared primary metric.
    case repeatableLoss = "repeatable_loss"
    /// The intervention is a boundary control and must remain within tolerance.
    case parity
    /// A provider swap must retain the provider-independent contract.
    case continuity
}

public struct WholeSystemAblationDeclaration: Codable, Sendable, Equatable {
    public let ablation: WholeSystemAblation
    public let claimMode: WholeSystemClaimMode
    public let primaryMetrics: [WholeSystemMetric]

    public init(
        ablation: WholeSystemAblation,
        claimMode: WholeSystemClaimMode,
        primaryMetrics: [WholeSystemMetric]
    ) {
        self.ablation = ablation
        self.claimMode = claimMode
        self.primaryMetrics = Array(Set(primaryMetrics)).sorted { $0.rawValue < $1.rawValue }
    }
}

public struct WholeSystemMetricThreshold: Codable, Sendable, Equatable {
    public let metric: WholeSystemMetric
    public let minimumMeaningfulLoss: Double
    public let parityTolerance: Double

    public init(
        metric: WholeSystemMetric,
        minimumMeaningfulLoss: Double,
        parityTolerance: Double
    ) {
        self.metric = metric
        self.minimumMeaningfulLoss = minimumMeaningfulLoss
        self.parityTolerance = parityTolerance
    }
}

public enum WholeSystemGate: String, Codable, CaseIterable, Sendable {
    case featureOffByteParity = "feature_off_byte_parity"
    case featureOffBehaviorParity = "feature_off_behavior_parity"
    case publicSafePreOnboardingNeutral = "public_safe_pre_onboarding_neutral"
    case publicSafeNoPrivateFixture = "public_safe_no_private_fixture"
    case publicSafeNoReleaseArtifact = "public_safe_no_release_artifact"
    case publicSafeNoCredentialMigration = "public_safe_no_credential_migration"
    case privacyPayloadFree = "privacy_payload_free"
    case privacyNoRawPath = "privacy_no_raw_path"
    case privacyNoProviderPayload = "privacy_no_provider_payload"
    case privacyNoUnapprovedPersonalEvidence = "privacy_no_unapproved_personal_evidence"
    case authorityTrustDenial = "authority_trust_denial"
    case authorityApprovalNotBypassed = "authority_approval_not_bypassed"
    case authorityNoPermissionControl = "authority_no_permission_control"
    case authorityNoActionControl = "authority_no_action_control"
    case releaseVerifier = "release_verifier"
    case gitleaks
}

public enum WholeSystemGateObservationStatus: String, Codable, Sendable {
    case passed
    case failed
    case missing
}

public struct WholeSystemGateObservation: Codable, Sendable, Equatable {
    public let gate: WholeSystemGate
    public let status: WholeSystemGateObservationStatus
    /// SHA-256 of the external test/report/receipt, never its payload.
    public let evidenceDigestSHA256: String?

    public init(
        gate: WholeSystemGate,
        status: WholeSystemGateObservationStatus,
        evidenceDigestSHA256: String? = nil
    ) {
        self.gate = gate
        self.status = status
        self.evidenceDigestSHA256 = evidenceDigestSHA256
    }
}

public enum WholeSystemPerformanceMetric: String, Codable, CaseIterable, Sendable {
    case outcomeMetadataP95Milliseconds = "outcome_metadata_p95_milliseconds"
    case contextWarmP95Milliseconds = "context_warm_p95_milliseconds"
    case addedRoutingProviderCalls = "added_routing_provider_calls"
    case addedPromptBytes = "added_prompt_bytes"
    case addedPeriodicWakes = "added_periodic_wakes"
    case evaluationReportBytes = "evaluation_report_bytes"
    case idleCPUPercent = "idle_cpu_percent"
    case wakeCount = "wake_count"
    case warmTurnP50Milliseconds = "warm_turn_p50_milliseconds"
    case warmTurnP95Milliseconds = "warm_turn_p95_milliseconds"
    case firstTokenP95Milliseconds = "first_token_p95_milliseconds"
    case residentBytes = "resident_bytes"
    case persistenceWrites = "persistence_writes"
    case actionSettlementP95Milliseconds = "action_settlement_p95_milliseconds"
    case toolCalls = "tool_calls"
    case memoryRecords = "memory_records"
    case fieldNodes = "field_nodes"
    case modelRules = "model_rules"
}

public struct WholeSystemPerformanceLimit: Codable, Sendable, Equatable {
    public let metric: WholeSystemPerformanceMetric
    public let maximum: Double

    public init(metric: WholeSystemPerformanceMetric, maximum: Double) {
        self.metric = metric
        self.maximum = maximum
    }
}

public struct WholeSystemPerformanceObservation: Codable, Sendable, Equatable {
    public let metric: WholeSystemPerformanceMetric
    public let status: WholeSystemObservationStatus
    public let value: Double?
    public let gap: WholeSystemEvidenceGap?

    public init(
        metric: WholeSystemPerformanceMetric,
        status: WholeSystemObservationStatus,
        value: Double? = nil,
        gap: WholeSystemEvidenceGap? = nil
    ) {
        self.metric = metric
        self.status = status
        self.value = value
        self.gap = gap
    }

    public static func measured(_ metric: WholeSystemPerformanceMetric, _ value: Double) -> Self {
        Self(metric: metric, status: .measured, value: value)
    }
}

/// Closed vocabulary for the final fossil comparison. Evidence proves a row;
/// the evaluator does not derive architecture claims from marketing language.
public enum WholeSystemFossilDimension: String, Codable, CaseIterable, Sendable {
    case residentState = "resident_state"
    case exactDeltaUpdates = "exact_delta_updates"
    case eventDrivenNoArtificialHeartbeat = "event_driven_no_artificial_heartbeat"
    case zeroRoutingProviderCalls = "zero_routing_provider_calls"
    case boundedEligibleAffordances = "bounded_eligible_affordances"
    case compiledVerifiedProcedures = "compiled_verified_procedures"
    case canonicalVerifiedCompletion = "canonical_verified_completion"
    case providerIndependentIdentityContract = "provider_independent_identity_contract"

    public var graphEraPattern: String {
        switch self {
        case .residentState: "state_rebuilt_each_turn"
        case .exactDeltaUpdates: "whole_state_reconstruction"
        case .eventDrivenNoArtificialHeartbeat: "cron_style_cognition"
        case .zeroRoutingProviderCalls: "model_routes_every_choice"
        case .boundedEligibleAffordances: "broad_tool_catalog"
        case .compiledVerifiedProcedures: "every_routine_uses_frontier_reasoning"
        case .canonicalVerifiedCompletion: "model_says_done"
        case .providerIndependentIdentityContract: "model_defines_agent"
        }
    }

    public var nativeTarget: String { rawValue }
}

public struct WholeSystemFossilObservation: Codable, Sendable, Equatable {
    public let dimension: WholeSystemFossilDimension
    public let status: WholeSystemGateObservationStatus
    public let evidenceDigestSHA256: String?

    public init(
        dimension: WholeSystemFossilDimension,
        status: WholeSystemGateObservationStatus,
        evidenceDigestSHA256: String? = nil
    ) {
        self.dimension = dimension
        self.status = status
        self.evidenceDigestSHA256 = evidenceDigestSHA256
    }
}

public struct WholeSystemConvergenceManifest: Codable, Sendable, Equatable {
    public static let schema = "whole-system-convergence-manifest.v1"

    public let schema: String
    public let manifestVersion: String
    public let declarations: [WholeSystemAblationDeclaration]
    public let thresholds: [WholeSystemMetricThreshold]
    public let requiredGates: [WholeSystemGate]
    public let performanceLimits: [WholeSystemPerformanceLimit]
    public let requiredFossilDimensions: [WholeSystemFossilDimension]
    public let minimumPairedTrials: Int
    public let minimumRepeatabilityFraction: Double
    public let maximumComparisons: Int

    public init(
        manifestVersion: String,
        declarations: [WholeSystemAblationDeclaration],
        thresholds: [WholeSystemMetricThreshold],
        requiredGates: [WholeSystemGate],
        performanceLimits: [WholeSystemPerformanceLimit],
        requiredFossilDimensions: [WholeSystemFossilDimension],
        minimumPairedTrials: Int = 3,
        minimumRepeatabilityFraction: Double = 2.0 / 3.0,
        maximumComparisons: Int = 32
    ) {
        self.schema = Self.schema
        self.manifestVersion = String(manifestVersion.prefix(120))
        self.declarations = declarations.sorted { $0.ablation.rawValue < $1.ablation.rawValue }
        self.thresholds = thresholds.sorted { $0.metric.rawValue < $1.metric.rawValue }
        self.requiredGates = Array(Set(requiredGates)).sorted { $0.rawValue < $1.rawValue }
        self.performanceLimits = performanceLimits.sorted { $0.metric.rawValue < $1.metric.rawValue }
        self.requiredFossilDimensions = Array(Set(requiredFossilDimensions)).sorted { $0.rawValue < $1.rawValue }
        self.minimumPairedTrials = minimumPairedTrials
        self.minimumRepeatabilityFraction = minimumRepeatabilityFraction
        self.maximumComparisons = maximumComparisons
    }

    public static let wave12 = WholeSystemConvergenceManifest(
        manifestVersion: "living-fabric-v2.wave12.v1",
        declarations: [
            .init(ablation: .organismBodyProjectionRemoved, claimMode: .repeatableLoss, primaryMetrics: [.falseCompletion]),
            .init(ablation: .usedMemoryReturnEdgeRemoved, claimMode: .repeatableLoss, primaryMetrics: [.contextRelevance]),
            .init(ablation: .contextUtilityShuffled, claimMode: .repeatableLoss, primaryMetrics: [.contextRelevance]),
            .init(ablation: .causalModelRemoved, claimMode: .repeatableLoss, primaryMetrics: [.correctionRate]),
            .init(ablation: .residualRepairDisabled, claimMode: .repeatableLoss, primaryMetrics: [.taskSuccess]),
            .init(ablation: .compiledProcedureDisabled, claimMode: .repeatableLoss, primaryMetrics: [.providerCalls]),
            .init(ablation: .providerSwapped, claimMode: .continuity, primaryMetrics: [.identityContractAdherence]),
            .init(ablation: .deviceBeliefStaleUnknown, claimMode: .repeatableLoss, primaryMetrics: [.actionVerification]),
            .init(ablation: .dreamProviderLaneDisabledLocalRepairRemains, claimMode: .parity, primaryMetrics: [.taskSuccess]),
        ],
        thresholds: WholeSystemMetric.allCases.map {
            switch $0 {
            case .latencyMilliseconds:
                .init(metric: $0, minimumMeaningfulLoss: 10, parityTolerance: 25)
            case .providerCalls:
                .init(metric: $0, minimumMeaningfulLoss: 0.25, parityTolerance: 0.25)
            default:
                .init(metric: $0, minimumMeaningfulLoss: 0.02, parityTolerance: 0.02)
            }
        },
        requiredGates: WholeSystemGate.allCases,
        performanceLimits: [
            .init(metric: .outcomeMetadataP95Milliseconds, maximum: 1),
            .init(metric: .contextWarmP95Milliseconds, maximum: 50),
            .init(metric: .addedRoutingProviderCalls, maximum: 0),
            .init(metric: .addedPromptBytes, maximum: 0),
            .init(metric: .addedPeriodicWakes, maximum: 0),
            .init(metric: .evaluationReportBytes, maximum: 1_048_576),
        ],
        requiredFossilDimensions: WholeSystemFossilDimension.allCases
    )
}

public struct WholeSystemAblationTrial: Codable, Sendable, Equatable {
    public let ablation: WholeSystemAblation
    public let evidenceClass: WholeSystemEvidenceClass
    /// Digest of the exact shared scenario order, clock, fixture, and budgets.
    public let matchedConditionDigestSHA256: String
    public let baseline: WholeSystemMetricSet
    public let ablated: WholeSystemMetricSet
    /// Aggregate of the exact matched executions that produced this trial.
    /// It is part of both the harness run digest and evaluator artifact digest.
    public let executionEffects: WholeSystemExecutionEffects
    /// Required only for authorized personal evidence. This evaluator verifies
    /// shape, not ApprovalInbox truth; the supplying harness owns that gate.
    public let personalAuthorizationDigestSHA256: String?

    public init(
        ablation: WholeSystemAblation,
        evidenceClass: WholeSystemEvidenceClass,
        matchedConditionDigestSHA256: String,
        baseline: WholeSystemMetricSet,
        ablated: WholeSystemMetricSet,
        executionEffects: WholeSystemExecutionEffects,
        personalAuthorizationDigestSHA256: String? = nil
    ) {
        self.ablation = ablation
        self.evidenceClass = evidenceClass
        self.matchedConditionDigestSHA256 = matchedConditionDigestSHA256
        self.baseline = baseline
        self.ablated = ablated
        self.executionEffects = executionEffects
        self.personalAuthorizationDigestSHA256 = personalAuthorizationDigestSHA256
    }
}

public enum WholeSystemComparisonStatus: String, Codable, Sendable {
    case repeatableLossDetected = "repeatable_loss_detected"
    case noMeaningfulLoss = "no_meaningful_loss"
    case parity
    case parityViolated = "parity_violated"
    case improved
    case inconclusiveMissing = "inconclusive_missing"
    case inconclusiveCensored = "inconclusive_censored"
    case inconclusiveUnmatched = "inconclusive_unmatched"
    case insufficientRepetitions = "insufficient_repetitions"
}

public enum WholeSystemVerdict: String, Codable, Sendable {
    case passed
    case failed
    case inconclusive
}

public struct WholeSystemMetricComparison: Codable, Sendable, Equatable {
    public let metric: WholeSystemMetric
    public let status: WholeSystemComparisonStatus
    public let baselineMean: Double?
    public let ablatedMean: Double?
    /// Positive means the ablation worsened the metric, regardless of its unit.
    public let signedLoss: Double?
    public let pairedTrialCount: Int
    public let lossDirectionFraction: Double?
    public let gap: WholeSystemEvidenceGap?
}

public struct WholeSystemAblationReport: Codable, Sendable, Equatable {
    public let ablation: WholeSystemAblation
    public let evidenceClass: WholeSystemEvidenceClass
    public let claimMode: WholeSystemClaimMode
    public let primaryMetrics: [WholeSystemMetric]
    public let verdict: WholeSystemVerdict
    public let comparisons: [WholeSystemMetricComparison]
}

public struct WholeSystemGateResult: Codable, Sendable, Equatable {
    public let gate: WholeSystemGate
    public let verdict: WholeSystemVerdict
    public let evidenceDigestSHA256: String?
}

public struct WholeSystemPerformanceResult: Codable, Sendable, Equatable {
    public let metric: WholeSystemPerformanceMetric
    public let verdict: WholeSystemVerdict
    public let measuredValue: Double?
    public let maximum: Double
    public let gap: WholeSystemEvidenceGap?
}

public struct WholeSystemFossilResult: Codable, Sendable, Equatable {
    public let dimension: WholeSystemFossilDimension
    public let verdict: WholeSystemVerdict
    public let evidenceDigestSHA256: String?
}

public struct WholeSystemConvergenceReport: Codable, Sendable, Equatable {
    public static let schema = "whole-system-convergence-report.v2"

    public let schema: String
    public let evaluatorVersion: String
    public let manifestVersion: String
    public let artifactDigestSHA256: String
    public let evidenceClasses: [WholeSystemEvidenceClass]
    public let generatedFixtureOnly: Bool
    public let ablations: [WholeSystemAblationReport]
    public let gates: [WholeSystemGateResult]
    public let performance: [WholeSystemPerformanceResult]
    public let fossilProof: [WholeSystemFossilResult]
    public let overallVerdict: WholeSystemVerdict
    /// Hard invariant over the measured adapter effects, independent of
    /// declarative gate observations.
    public let executionBoundaryVerdict: WholeSystemVerdict
    public let providerCallCount: Int
    public let canonicalStateMutationCount: Int
    public let promptAuthority: Bool
    public let actionAuthority: Bool
    public let permissionAuthority: Bool
    public let identityAuthority: Bool
    public let memoryAuthority: Bool
    public let adaptiveInfluenceAuthority: Bool
}

public enum WholeSystemConvergenceEvaluationError: String, Error, Sendable, Equatable {
    case invalidManifest = "invalid_manifest"
    case duplicateAblation = "duplicate_ablation"
    case missingAblation = "missing_ablation"
    case unexpectedAblation = "unexpected_ablation"
    case tooManyComparisons = "too_many_comparisons"
    case invalidDigest = "invalid_digest"
    case invalidObservation = "invalid_observation"
    case duplicateMetric = "duplicate_metric"
    case duplicateGate = "duplicate_gate"
    case duplicatePerformanceMetric = "duplicate_performance_metric"
    case duplicateFossilDimension = "duplicate_fossil_dimension"
    case unexpectedGate = "unexpected_gate"
    case unexpectedPerformanceMetric = "unexpected_performance_metric"
    case unexpectedFossilDimension = "unexpected_fossil_dimension"
    case personalAuthorizationRequired = "personal_authorization_required"
}

public enum WholeSystemConvergenceEvaluator {
    public static let evaluatorVersion = "whole-system-convergence-evaluator.v2"

    public static func evaluate(
        manifest: WholeSystemConvergenceManifest,
        trials: [WholeSystemAblationTrial],
        gates: [WholeSystemGateObservation],
        performance: [WholeSystemPerformanceObservation],
        fossilEvidence: [WholeSystemFossilObservation]
    ) throws -> WholeSystemConvergenceReport {
        try validate(manifest)
        guard trials.count <= manifest.maximumComparisons else {
            throw WholeSystemConvergenceEvaluationError.tooManyComparisons
        }

        let trialMap = try uniqueMap(trials, key: \WholeSystemAblationTrial.ablation, duplicate: .duplicateAblation)
        let declarationMap = Dictionary(uniqueKeysWithValues: manifest.declarations.map { ($0.ablation, $0) })
        guard Set(trialMap.keys) == Set(declarationMap.keys) else {
            if !Set(trialMap.keys).isSubset(of: Set(declarationMap.keys)) {
                throw WholeSystemConvergenceEvaluationError.unexpectedAblation
            }
            throw WholeSystemConvergenceEvaluationError.missingAblation
        }
        let thresholdMap = Dictionary(uniqueKeysWithValues: manifest.thresholds.map { ($0.metric, $0) })

        var ablationReports: [WholeSystemAblationReport] = []
        for declaration in manifest.declarations {
            let trial = trialMap[declaration.ablation]!
            try validate(trial)
            let baseline = try metricMap(trial.baseline)
            let ablated = try metricMap(trial.ablated)
            let comparisons = WholeSystemMetric.allCases.map { metric in
                compare(
                    metric: metric,
                    baseline: baseline[metric],
                    ablated: ablated[metric],
                    threshold: thresholdMap[metric]!,
                    manifest: manifest
                )
            }.sorted { $0.metric.rawValue < $1.metric.rawValue }
            let comparisonMap = Dictionary(uniqueKeysWithValues: comparisons.map { ($0.metric, $0) })
            let verdicts = declaration.primaryMetrics.map { metric -> WholeSystemVerdict in
                guard let result = comparisonMap[metric] else { return .inconclusive }
                return claimVerdict(for: result.status, claimMode: declaration.claimMode)
            }
            let ablationVerdict: WholeSystemVerdict = verdicts.contains(.inconclusive)
                ? .inconclusive
                : (verdicts.allSatisfy { $0 == .passed } ? .passed : .failed)
            ablationReports.append(WholeSystemAblationReport(
                ablation: declaration.ablation,
                evidenceClass: trial.evidenceClass,
                claimMode: declaration.claimMode,
                primaryMetrics: declaration.primaryMetrics,
                verdict: ablationVerdict,
                comparisons: comparisons
            ))
        }

        let gateMap = try uniqueMap(gates, key: \WholeSystemGateObservation.gate, duplicate: .duplicateGate)
        guard Set(gateMap.keys).isSubset(of: Set(manifest.requiredGates)) else {
            throw WholeSystemConvergenceEvaluationError.unexpectedGate
        }
        let gateResults = try manifest.requiredGates.map { gate -> WholeSystemGateResult in
            guard let observation = gateMap[gate] else {
                return WholeSystemGateResult(gate: gate, verdict: .inconclusive, evidenceDigestSHA256: nil)
            }
            if observation.status != .missing {
                guard isSHA256(observation.evidenceDigestSHA256) else {
                    throw WholeSystemConvergenceEvaluationError.invalidDigest
                }
            } else if observation.evidenceDigestSHA256 != nil {
                throw WholeSystemConvergenceEvaluationError.invalidObservation
            }
            let result: WholeSystemVerdict = switch observation.status {
            case .passed: .passed
            case .failed: .failed
            case .missing: .inconclusive
            }
            return WholeSystemGateResult(
                gate: gate,
                verdict: result,
                evidenceDigestSHA256: observation.evidenceDigestSHA256
            )
        }

        let performanceMap = try uniqueMap(
            performance,
            key: \WholeSystemPerformanceObservation.metric,
            duplicate: .duplicatePerformanceMetric
        )
        guard Set(performanceMap.keys).isSubset(of: Set(manifest.performanceLimits.map(\.metric))) else {
            throw WholeSystemConvergenceEvaluationError.unexpectedPerformanceMetric
        }
        let performanceResults = try manifest.performanceLimits.map { limit -> WholeSystemPerformanceResult in
            guard let observation = performanceMap[limit.metric] else {
                return WholeSystemPerformanceResult(
                    metric: limit.metric,
                    verdict: .inconclusive,
                    measuredValue: nil,
                    maximum: limit.maximum,
                    gap: .notSupplied
                )
            }
            try validate(observation)
            guard observation.status == .measured, let value = observation.value else {
                return WholeSystemPerformanceResult(
                    metric: limit.metric,
                    verdict: .inconclusive,
                    measuredValue: nil,
                    maximum: limit.maximum,
                    gap: observation.gap
                )
            }
            return WholeSystemPerformanceResult(
                metric: limit.metric,
                verdict: value <= limit.maximum ? .passed : .failed,
                measuredValue: value,
                maximum: limit.maximum,
                gap: nil
            )
        }

        let fossilMap = try uniqueMap(
            fossilEvidence,
            key: \WholeSystemFossilObservation.dimension,
            duplicate: .duplicateFossilDimension
        )
        guard Set(fossilMap.keys).isSubset(of: Set(manifest.requiredFossilDimensions)) else {
            throw WholeSystemConvergenceEvaluationError.unexpectedFossilDimension
        }
        let fossilResults = try manifest.requiredFossilDimensions.map { dimension -> WholeSystemFossilResult in
            guard let observation = fossilMap[dimension] else {
                return WholeSystemFossilResult(dimension: dimension, verdict: .inconclusive, evidenceDigestSHA256: nil)
            }
            if observation.status != .missing {
                guard isSHA256(observation.evidenceDigestSHA256) else {
                    throw WholeSystemConvergenceEvaluationError.invalidDigest
                }
            } else if observation.evidenceDigestSHA256 != nil {
                throw WholeSystemConvergenceEvaluationError.invalidObservation
            }
            let result: WholeSystemVerdict = switch observation.status {
            case .passed: .passed
            case .failed: .failed
            case .missing: .inconclusive
            }
            return WholeSystemFossilResult(
                dimension: dimension,
                verdict: result,
                evidenceDigestSHA256: observation.evidenceDigestSHA256
            )
        }

        let allVerdicts = ablationReports.map(\.verdict)
            + gateResults.map(\.verdict)
            + performanceResults.map(\.verdict)
            + fossilResults.map(\.verdict)
        let aggregateEffects = try trials.reduce(WholeSystemExecutionEffects.noControl) {
            guard let combined = $0.adding($1.executionEffects) else {
                throw WholeSystemConvergenceEvaluationError.invalidObservation
            }
            return combined
        }
        let executionBoundary: WholeSystemVerdict = aggregateEffects.hasControlAuthority
            || aggregateEffects.canonicalStateMutationCount > 0 ? .failed : .passed
        let boundedVerdicts = allVerdicts + [executionBoundary]
        let overall: WholeSystemVerdict = boundedVerdicts.contains(.failed)
            ? .failed
            : (boundedVerdicts.contains(.inconclusive) ? .inconclusive : .passed)
        let evidenceClasses = Array(Set(trials.map(\.evidenceClass))).sorted { $0.rawValue < $1.rawValue }

        let digestPayload = DigestPayload(
            evaluatorVersion: evaluatorVersion,
            manifest: manifest,
            trials: trials.sorted { $0.ablation.rawValue < $1.ablation.rawValue },
            gates: gates.sorted { $0.gate.rawValue < $1.gate.rawValue },
            performance: performance.sorted { $0.metric.rawValue < $1.metric.rawValue },
            fossilEvidence: fossilEvidence.sorted { $0.dimension.rawValue < $1.dimension.rawValue }
        )
        let digest = try digestOf(digestPayload)

        return WholeSystemConvergenceReport(
            schema: WholeSystemConvergenceReport.schema,
            evaluatorVersion: evaluatorVersion,
            manifestVersion: manifest.manifestVersion,
            artifactDigestSHA256: digest,
            evidenceClasses: evidenceClasses,
            generatedFixtureOnly: evidenceClasses == [.generatedDeterministic],
            ablations: ablationReports,
            gates: gateResults,
            performance: performanceResults,
            fossilProof: fossilResults,
            overallVerdict: overall,
            executionBoundaryVerdict: executionBoundary,
            providerCallCount: aggregateEffects.providerCallCount,
            canonicalStateMutationCount: aggregateEffects.canonicalStateMutationCount,
            promptAuthority: aggregateEffects.promptAuthority,
            actionAuthority: aggregateEffects.actionAuthority,
            permissionAuthority: aggregateEffects.permissionAuthority,
            identityAuthority: aggregateEffects.identityAuthority,
            memoryAuthority: aggregateEffects.memoryAuthority,
            adaptiveInfluenceAuthority: aggregateEffects.adaptiveInfluenceAuthority
        )
    }

    private static func compare(
        metric: WholeSystemMetric,
        baseline: WholeSystemMetricObservation?,
        ablated: WholeSystemMetricObservation?,
        threshold: WholeSystemMetricThreshold,
        manifest: WholeSystemConvergenceManifest
    ) -> WholeSystemMetricComparison {
        guard let baseline else { return gapComparison(metric, status: .inconclusiveMissing, gap: .notSupplied) }
        guard let ablated else { return gapComparison(metric, status: .inconclusiveMissing, gap: .notSupplied) }
        if baseline.status == .censored || ablated.status == .censored {
            return gapComparison(metric, status: .inconclusiveCensored, gap: baseline.gap ?? ablated.gap)
        }
        guard baseline.status == .measured, ablated.status == .measured else {
            return gapComparison(metric, status: .inconclusiveMissing, gap: baseline.gap ?? ablated.gap)
        }
        guard baseline.values.count == ablated.values.count else {
            return gapComparison(metric, status: .inconclusiveUnmatched, gap: nil)
        }
        let count = baseline.values.count
        let baselineMean = baseline.values.reduce(0, +) / Double(count)
        let ablatedMean = ablated.values.reduce(0, +) / Double(count)
        let losses = zip(baseline.values, ablated.values).map { before, after in
            metric.higherIsBetter ? before - after : after - before
        }
        let signedLoss = losses.reduce(0, +) / Double(count)
        let lossFraction = Double(losses.filter { $0 > 0 }.count) / Double(count)
        let parityFraction = Double(losses.filter { abs($0) <= threshold.parityTolerance }.count) / Double(count)

        let status: WholeSystemComparisonStatus
        if count < manifest.minimumPairedTrials {
            status = .insufficientRepetitions
        } else if abs(signedLoss) <= threshold.parityTolerance,
                  parityFraction >= manifest.minimumRepeatabilityFraction {
            status = .parity
        } else if signedLoss >= threshold.minimumMeaningfulLoss,
                  lossFraction >= manifest.minimumRepeatabilityFraction {
            status = .repeatableLossDetected
        } else if signedLoss < -threshold.minimumMeaningfulLoss {
            status = .improved
        } else if abs(signedLoss) > threshold.parityTolerance {
            status = .parityViolated
        } else {
            status = .noMeaningfulLoss
        }
        return WholeSystemMetricComparison(
            metric: metric,
            status: status,
            baselineMean: baselineMean,
            ablatedMean: ablatedMean,
            signedLoss: signedLoss,
            pairedTrialCount: count,
            lossDirectionFraction: lossFraction,
            gap: nil
        )
    }

    private static func claimVerdict(
        for status: WholeSystemComparisonStatus,
        claimMode: WholeSystemClaimMode
    ) -> WholeSystemVerdict {
        switch claimMode {
        case .repeatableLoss:
            switch status {
            case .repeatableLossDetected: .passed
            case .inconclusiveMissing, .inconclusiveCensored, .inconclusiveUnmatched, .insufficientRepetitions: .inconclusive
            default: .failed
            }
        case .parity, .continuity:
            switch status {
            case .parity: .passed
            case .inconclusiveMissing, .inconclusiveCensored, .inconclusiveUnmatched, .insufficientRepetitions: .inconclusive
            default: .failed
            }
        }
    }

    private static func gapComparison(
        _ metric: WholeSystemMetric,
        status: WholeSystemComparisonStatus,
        gap: WholeSystemEvidenceGap?
    ) -> WholeSystemMetricComparison {
        WholeSystemMetricComparison(
            metric: metric,
            status: status,
            baselineMean: nil,
            ablatedMean: nil,
            signedLoss: nil,
            pairedTrialCount: 0,
            lossDirectionFraction: nil,
            gap: gap
        )
    }

    private static func validate(_ manifest: WholeSystemConvergenceManifest) throws {
        guard manifest.schema == WholeSystemConvergenceManifest.schema,
              !manifest.manifestVersion.isEmpty,
              manifest.manifestVersion.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
              }),
              manifest.declarations.count <= manifest.maximumComparisons,
              (1...64).contains(manifest.maximumComparisons),
              (2...256).contains(manifest.minimumPairedTrials),
              (0.5...1).contains(manifest.minimumRepeatabilityFraction),
              Set(manifest.declarations.map(\.ablation)).count == manifest.declarations.count,
              Set(manifest.thresholds.map(\.metric)) == Set(WholeSystemMetric.allCases),
              Set(manifest.thresholds.map(\.metric)).count == manifest.thresholds.count,
              Set(manifest.performanceLimits.map(\.metric)).count == manifest.performanceLimits.count,
              Set(manifest.requiredGates).count == manifest.requiredGates.count,
              Set(manifest.requiredFossilDimensions).count == manifest.requiredFossilDimensions.count,
              manifest.declarations.allSatisfy({ !$0.primaryMetrics.isEmpty }),
              manifest.thresholds.allSatisfy({
                  $0.minimumMeaningfulLoss.isFinite && $0.minimumMeaningfulLoss >= 0
                      && $0.parityTolerance.isFinite && $0.parityTolerance >= 0
              }),
              manifest.performanceLimits.allSatisfy({ $0.maximum.isFinite && $0.maximum >= 0 })
        else { throw WholeSystemConvergenceEvaluationError.invalidManifest }
    }

    private static func validate(_ trial: WholeSystemAblationTrial) throws {
        guard isSHA256(trial.matchedConditionDigestSHA256) else {
            throw WholeSystemConvergenceEvaluationError.invalidDigest
        }
        if trial.evidenceClass == .authorizedPersonalOutcome {
            guard isSHA256(trial.personalAuthorizationDigestSHA256) else {
                throw WholeSystemConvergenceEvaluationError.personalAuthorizationRequired
            }
        } else if trial.personalAuthorizationDigestSHA256 != nil {
            throw WholeSystemConvergenceEvaluationError.invalidObservation
        }
        guard trial.executionEffects.isStructurallyValid else {
            throw WholeSystemConvergenceEvaluationError.invalidObservation
        }
        _ = try metricMap(trial.baseline)
        _ = try metricMap(trial.ablated)
    }

    private static func metricMap(
        _ set: WholeSystemMetricSet
    ) throws -> [WholeSystemMetric: WholeSystemMetricObservation] {
        var result: [WholeSystemMetric: WholeSystemMetricObservation] = [:]
        for observation in set.observations {
            guard result[observation.metric] == nil else {
                throw WholeSystemConvergenceEvaluationError.duplicateMetric
            }
            switch observation.status {
            case .measured:
                guard observation.gap == nil,
                      (1...WholeSystemMetricObservation.maximumTrialValues).contains(observation.values.count),
                      observation.values.allSatisfy(observation.metric.accepts)
                else { throw WholeSystemConvergenceEvaluationError.invalidObservation }
            case .missing, .censored:
                guard observation.values.isEmpty, observation.gap != nil else {
                    throw WholeSystemConvergenceEvaluationError.invalidObservation
                }
            }
            result[observation.metric] = observation
        }
        return result
    }

    private static func validate(_ observation: WholeSystemPerformanceObservation) throws {
        switch observation.status {
        case .measured:
            guard let value = observation.value, value.isFinite, value >= 0, observation.gap == nil else {
                throw WholeSystemConvergenceEvaluationError.invalidObservation
            }
        case .missing, .censored:
            guard observation.value == nil, observation.gap != nil else {
                throw WholeSystemConvergenceEvaluationError.invalidObservation
            }
        }
    }

    private static func uniqueMap<Element, Key: Hashable>(
        _ elements: [Element],
        key: KeyPath<Element, Key>,
        duplicate: WholeSystemConvergenceEvaluationError
    ) throws -> [Key: Element] {
        var result: [Key: Element] = [:]
        for element in elements {
            let value = element[keyPath: key]
            guard result[value] == nil else { throw duplicate }
            result[value] = element
        }
        return result
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private struct DigestPayload: Codable {
        let evaluatorVersion: String
        let manifest: WholeSystemConvergenceManifest
        let trials: [WholeSystemAblationTrial]
        let gates: [WholeSystemGateObservation]
        let performance: [WholeSystemPerformanceObservation]
        let fossilEvidence: [WholeSystemFossilObservation]
    }

    private static func digestOf(_ value: DigestPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
