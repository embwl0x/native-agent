import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProcedureCandidateAdmission.swift` | Procedure candidate evidence binding, review contracts and strict manual/canary admission |

// MARK: - Strict candidate admission

public enum ProcedureReviewVerdict: String, Codable, Sendable, Equatable {
    case approve
    case hold
    case reject
}

public enum ProcedureReviewScope: String, Codable, Sendable, Equatable {
    case manualOnly = "manual_only"
    case manualAndCanary = "manual_and_canary"
}

public struct ProcedureReviewProposal: Codable, Sendable, Equatable {
    public let candidateShapeIdentity: String
    public let candidateEvidenceDigest: String
    public let productRole: ProcedureCandidateProductRole
    public let trajectoryCount: Int
    public let scope: ProcedureReviewScope

    public init(candidate: ProcedureCandidate, scope: ProcedureReviewScope) {
        self.candidateShapeIdentity = candidate.id
        self.candidateEvidenceDigest = candidate.reviewBindingDigest
        self.productRole = candidate.productRole
        self.trajectoryCount = candidate.trajectoryCount
        self.scope = scope
    }

    package init(
        candidateShapeIdentity: String,
        candidateEvidenceDigest: String,
        productRole: ProcedureCandidateProductRole,
        trajectoryCount: Int,
        scope: ProcedureReviewScope
    ) {
        self.candidateShapeIdentity = candidateShapeIdentity
        self.candidateEvidenceDigest = candidateEvidenceDigest
        self.productRole = productRole
        self.trajectoryCount = trajectoryCount
        self.scope = scope
    }

    public var validates: Bool {
        ProcedureTrajectoryExtractor.isOpaqueIdentity(candidateShapeIdentity)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(candidateEvidenceDigest)
            && trajectoryCount >= 2 && trajectoryCount <= 100_000
            && productRole != .ineligible
    }
}

public struct ProcedureReviewerDecision: Codable, Sendable, Equatable {
    public let candidateShapeIdentity: String
    public let verdict: ProcedureReviewVerdict
    public let scope: ProcedureReviewScope
    public let reviewerIdentity: String
    public let approvalReceiptIdentity: String
    public let candidateEvidenceDigest: String
    public let decidedAt: String

    /// Package-only: ApprovalInbox mints production review authority.
    package init(
        candidateShapeIdentity: String,
        verdict: ProcedureReviewVerdict,
        scope: ProcedureReviewScope,
        reviewerIdentity: String,
        approvalReceiptIdentity: String,
        candidateEvidenceDigest: String,
        decidedAt: String
    ) {
        self.candidateShapeIdentity = candidateShapeIdentity
        self.verdict = verdict
        self.scope = scope
        self.reviewerIdentity = reviewerIdentity
        self.approvalReceiptIdentity = approvalReceiptIdentity
        self.candidateEvidenceDigest = candidateEvidenceDigest
        self.decidedAt = decidedAt
    }
}

public enum ProcedureCandidateProductRole: String, Codable, Sendable, Equatable {
    case githubReducerOracle = "github_reducer_oracle"
    case workshopFirstProduct = "workshop_first_product"
    case ineligible
}

public enum ProcedureCandidateBlockReason: String, Codable, Sendable, Equatable, Hashable {
    case repeatedShapeInsufficient = "repeated_shape_insufficient"
    case distinctInputsInsufficient = "distinct_inputs_insufficient"
    case verifiedSuccessInsufficient = "verified_success_insufficient"
    case trustDivergence = "trust_divergence"
    case approvalCheckpointDivergence = "approval_checkpoint_divergence"
    case trustClassIneligible = "trust_class_ineligible"
    case externalSendIneligible = "external_send_ineligible"
    case unknownExternalEffect = "unknown_external_effect"
    case providerSavingsUnproven = "provider_savings_unproven"
    case reviewerDecisionMissing = "reviewer_decision_missing"
    case reviewerDidNotApprove = "reviewer_did_not_approve"
    case reviewerCanaryScopeMissing = "reviewer_canary_scope_missing"
    case productionTrajectoryCount = "production_trajectory_count"
    case productionDistinctDays = "production_distinct_days"
    case timeSeparatedHoldoutMissing = "time_separated_holdout_missing"
    case notLowRiskWorkshopTarget = "not_low_risk_workshop_target"
}

public struct ProcedureCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let productRole: ProcedureCandidateProductRole
    public let sourceTrajectories: [ProcedureTrajectory]
    public let canonicalTrajectory: ProcedureTrajectory
    public let trajectoryCount: Int
    public let repeatedCanonicalShapeCount: Int
    public let distinctInputInstanceCount: Int
    public let parameterSchemaVariationCount: Int
    public let distinctDayCount: Int
    public let verifiedSuccessCount: Int
    public let verifiedFailureCount: Int
    public let cancellationCount: Int
    public let verifiedSuccessRate: Double
    public let trustDivergenceCount: Int
    public let approvalCheckpointDivergenceCount: Int
    public let measurableRemovableProviderCalls: Int?
    public let timeSeparatedHoldoutPassed: Bool
    public let deterministicAbandonConditions: [String]
    public let reviewerDecision: ProcedureReviewerDecision?
    public let manualInvocationEligible: Bool
    public let canaryEligible: Bool
    public let automaticSelectionEligible: Bool
    public let manualBlockingReasons: [ProcedureCandidateBlockReason]
    public let canaryBlockingReasons: [ProcedureCandidateBlockReason]

    /// Payload-free binding used by ApprovalInbox. Any change in source
    /// evidence, eligibility, product role, or safety-relevant aggregate
    /// requires a new local approval.
    public var reviewBindingDigest: String {
        Self.makeReviewBindingDigest(
            id: id,
            productRole: productRole,
            trajectoryCount: trajectoryCount,
            distinctInputInstanceCount: distinctInputInstanceCount,
            distinctDayCount: distinctDayCount,
            verifiedSuccessCount: verifiedSuccessCount,
            verifiedFailureCount: verifiedFailureCount,
            cancellationCount: cancellationCount,
            trustDivergenceCount: trustDivergenceCount,
            approvalCheckpointDivergenceCount: approvalCheckpointDivergenceCount,
            sourceTrajectoryDigests: sourceTrajectories.map(Self.trajectoryBindingDigest)
        )
    }

    package static func makeReviewBindingDigest(
        id: String,
        productRole: ProcedureCandidateProductRole,
        trajectoryCount: Int,
        distinctInputInstanceCount: Int,
        distinctDayCount: Int,
        verifiedSuccessCount: Int,
        verifiedFailureCount: Int,
        cancellationCount: Int,
        trustDivergenceCount: Int,
        approvalCheckpointDivergenceCount: Int,
        sourceTrajectoryDigests: [String]
    ) -> String {
        CausalTransitionEvidence.opaqueIdentity([
            id, productRole.rawValue, String(trajectoryCount),
            String(distinctInputInstanceCount), String(distinctDayCount),
            String(verifiedSuccessCount), String(verifiedFailureCount),
            String(cancellationCount), String(trustDivergenceCount),
            String(approvalCheckpointDivergenceCount),
            sourceTrajectoryDigests.sorted().joined(separator: ","),
        ].joined(separator: "|"))
    }

    /// Complete payload-free evidence binding for local review. Trajectory IDs
    /// alone are not sufficient: an owner could correct verification, effects,
    /// costs, or provider-savings facts while retaining the same opaque run ID.
    package static func trajectoryBindingDigest(_ value: ProcedureTrajectory) -> String {
        let stepMaterial = value.steps.map { step in
            [
                String(step.sequence), step.transitionKind,
                step.beforeState ?? "nil", step.afterState ?? "nil",
                step.actionKind ?? "nil", step.evidenceKind ?? "nil",
                step.expectedNextEvidence ?? "nil", step.checkpointClass ?? "nil",
                step.retryClass ?? "nil", step.retryCount.map(String.init) ?? "nil",
                step.cancellationClass ?? "nil", step.motorPhase ?? "nil",
                step.verificationClass ?? "nil", step.terminalClass?.rawValue ?? "nil",
                step.externalEffectClass,
            ].joined(separator: "|")
        }.joined(separator: ">")
        var trajectoryMaterial: [String] = [
            value.id, value.domain, value.taskFamily, value.inputClass,
            value.inputInstanceIdentity, value.parameterSchemaClass,
            value.parameterSchemaIdentity, value.procedureShapeIdentity,
            value.authorityClass, value.startedAt, value.endedAt,
            String(value.durationMilliseconds), value.terminalClass.rawValue,
            value.externalEffectClasses.sorted().joined(separator: ","),
        ]
        trajectoryMaterial.append(value.providerCallCount.map(String.init) ?? "nil")
        trajectoryMaterial.append(value.toolCallCount.map(String.init) ?? "nil")
        trajectoryMaterial.append(value.providerCostMicros.map(String.init) ?? "nil")
        trajectoryMaterial.append(value.toolCostMicros.map(String.init) ?? "nil")
        trajectoryMaterial.append(
            value.removableOrchestrationProviderCallCount.map(String.init) ?? "nil"
        )
        trajectoryMaterial.append(String(value.retryCount))
        trajectoryMaterial.append(String(value.cancellationObserved))
        trajectoryMaterial.append(stepMaterial)
        return CausalTransitionEvidence.opaqueIdentity(
            trajectoryMaterial.joined(separator: "||")
        )
    }
}

public enum ProcedureCandidateCompiler {
    public static let deterministicAbandonConditions = [
        "authority_diverged",
        "canonical_evidence_mismatch",
        "cancellation_requested",
        "input_schema_novel",
        "precondition_failed",
        "trust_center_denied",
    ]

    public static func evaluate(
        trajectories: [ProcedureTrajectory],
        reviewerDecisions: [ProcedureReviewerDecision] = []
    ) -> [ProcedureCandidate] {
        // Compiled zero-provider trajectories prove effectiveness, never removable provider savings.
        let discoveryTrajectories = trajectories.filter {
            !isPostCompilationExecutionEvidence($0)
        }
        let decisionGroups = Dictionary(grouping: reviewerDecisions, by: \.candidateShapeIdentity)
        let decisions = decisionGroups.compactMapValues { rows in
            rows.count == 1 && validReview(rows[0]) ? rows[0] : nil
        }
        let grouped = Dictionary(grouping: discoveryTrajectories, by: \.procedureShapeIdentity)
        return grouped.keys.sorted().compactMap { shapeIdentity in
            guard let group = grouped[shapeIdentity], !group.isEmpty else { return nil }
            return evaluateOne(
                shapeIdentity: shapeIdentity,
                trajectories: group.sorted { $0.id < $1.id },
                review: decisions[shapeIdentity]
            )
        }
    }

    /// Exact cost-accounting boundary between ordinary candidate discovery
    /// and already-compiled execution evidence. Nil accounting remains in the
    /// discovery set and therefore fails provider-savings admission closed.
    public static func isPostCompilationExecutionEvidence(
        _ trajectory: ProcedureTrajectory
    ) -> Bool {
        trajectory.providerCallCount == 0
            && trajectory.removableOrchestrationProviderCallCount == 0
    }

    private static func evaluateOne(
        shapeIdentity: String,
        trajectories: [ProcedureTrajectory],
        review: ProcedureReviewerDecision?
    ) -> ProcedureCandidate {
        let successful = trajectories.filter { $0.terminalClass == .verifiedSuccess }
        let signatureGroups = Dictionary(grouping: successful, by: transitionSignature)
        let canonicalGroup = signatureGroups.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return transitionSignature($0[0]) < transitionSignature($1[0])
        }.first ?? [trajectories[0]]
        let canonical = canonicalGroup.sorted { $0.id < $1.id }[0]
        let successes = successful.count
        let failures = trajectories.filter { $0.terminalClass == .verifiedFailure }.count
        let cancellations = trajectories.filter { $0.terminalClass == .cancelled }.count
        let successRate = Double(successes) / Double(max(1, trajectories.count))
        let authorities = Set(trajectories.map(\.authorityClass))
        let checkpointGroups = Dictionary(grouping: trajectories, by: checkpointSignature)
        let dominantCheckpointCount = checkpointGroups.values.map(\.count).max() ?? 0
        let approvalCheckpointDivergenceCount = trajectories.count - dominantCheckpointCount
        let effects = Set(trajectories.flatMap(\.externalEffectClasses))
        let days = Set(trajectories.map { String($0.endedAt.prefix(10)) })
        let latestDay = days.sorted().last
        let holdout = trajectories.filter { String($0.endedAt.prefix(10)) == latestDay }
        let prior = trajectories.filter { String($0.endedAt.prefix(10)) != latestDay }
        let holdoutRate = Double(holdout.filter { $0.terminalClass == .verifiedSuccess }.count)
            / Double(max(1, holdout.count))
        let holdoutPassed = !prior.isEmpty && !holdout.isEmpty
            && holdoutRate >= 0.95
        let removableValues = trajectories.map(\.removableOrchestrationProviderCallCount)
        let removableCalls: Int? = removableValues.allSatisfy { $0 != nil }
            ? removableValues.compactMap { $0 }.reduce(0, +)
            : nil
        let savingsPassed = removableCalls.map {
            $0 >= trajectories.count
        } ?? false
        let productRole: ProcedureCandidateProductRole = {
            if canonical.domain == "github_command" { return .githubReducerOracle }
            if canonical.domain == "workshop_execution",
               authorities == Set(["low_risk"]),
               !effects.contains("external_send") {
                return .workshopFirstProduct
            }
            return .ineligible
        }()
        let expectedReviewDigest = ProcedureCandidate.makeReviewBindingDigest(
            id: shapeIdentity,
            productRole: productRole,
            trajectoryCount: trajectories.count,
            distinctInputInstanceCount: Set(trajectories.map(\.inputInstanceIdentity)).count,
            distinctDayCount: days.count,
            verifiedSuccessCount: successes,
            verifiedFailureCount: failures,
            cancellationCount: cancellations,
            trustDivergenceCount: max(0, authorities.count - 1),
            approvalCheckpointDivergenceCount: approvalCheckpointDivergenceCount,
            sourceTrajectoryDigests: trajectories.map(ProcedureCandidate.trajectoryBindingDigest)
        )

        var manualReasons: [ProcedureCandidateBlockReason] = []
        if canonicalGroup.count < 2 {
            manualReasons.append(.repeatedShapeInsufficient)
        }
        if Set(trajectories.map(\.inputInstanceIdentity)).count < 2 {
            manualReasons.append(.distinctInputsInsufficient)
        }
        if successRate < 0.90 {
            manualReasons.append(.verifiedSuccessInsufficient)
        }
        if authorities.count != 1 { manualReasons.append(.trustDivergence) }
        if approvalCheckpointDivergenceCount != 0 {
            manualReasons.append(.approvalCheckpointDivergence)
        }
        if !authorities.isSubset(of: Set(["low_risk", "confirm_required"])) {
            manualReasons.append(.trustClassIneligible)
        }
        if effects.contains("external_send") { manualReasons.append(.externalSendIneligible) }
        if effects.contains("unknown") { manualReasons.append(.unknownExternalEffect) }
        if !savingsPassed { manualReasons.append(.providerSavingsUnproven) }
        if review == nil || review?.candidateShapeIdentity != shapeIdentity
            || review.map({
                !ProcedureTrajectoryExtractor.isOpaqueIdentity($0.reviewerIdentity)
                    || !ProcedureTrajectoryExtractor.isOpaqueIdentity($0.approvalReceiptIdentity)
                    || !ProcedureTrajectoryExtractor.isOpaqueIdentity($0.candidateEvidenceDigest)
                    || $0.candidateEvidenceDigest != expectedReviewDigest
            }) == true {
            manualReasons.append(.reviewerDecisionMissing)
        } else if review?.verdict != .approve {
            manualReasons.append(.reviewerDidNotApprove)
        }

        var canaryReasons = manualReasons
        if trajectories.count < 12 {
            canaryReasons.append(.productionTrajectoryCount)
        }
        if days.count < 3 {
            canaryReasons.append(.productionDistinctDays)
        }
        if successRate < 0.95 {
            canaryReasons.append(.verifiedSuccessInsufficient)
        }
        if !holdoutPassed { canaryReasons.append(.timeSeparatedHoldoutMissing) }
        if productRole != .workshopFirstProduct { canaryReasons.append(.notLowRiskWorkshopTarget) }
        if review?.scope != .manualAndCanary { canaryReasons.append(.reviewerCanaryScopeMissing) }

        return ProcedureCandidate(
            id: shapeIdentity,
            productRole: productRole,
            sourceTrajectories: trajectories,
            canonicalTrajectory: canonical,
            trajectoryCount: trajectories.count,
            repeatedCanonicalShapeCount: canonicalGroup.count,
            distinctInputInstanceCount: Set(trajectories.map(\.inputInstanceIdentity)).count,
            parameterSchemaVariationCount: Set(trajectories.map(\.parameterSchemaIdentity)).count,
            distinctDayCount: days.count,
            verifiedSuccessCount: successes,
            verifiedFailureCount: failures,
            cancellationCount: cancellations,
            verifiedSuccessRate: successRate,
            trustDivergenceCount: max(0, authorities.count - 1),
            approvalCheckpointDivergenceCount: approvalCheckpointDivergenceCount,
            measurableRemovableProviderCalls: removableCalls,
            timeSeparatedHoldoutPassed: holdoutPassed,
            deterministicAbandonConditions: deterministicAbandonConditions,
            reviewerDecision: review,
            manualInvocationEligible: manualReasons.isEmpty,
            canaryEligible: canaryReasons.isEmpty,
            automaticSelectionEligible: false,
            manualBlockingReasons: unique(manualReasons),
            canaryBlockingReasons: unique(canaryReasons)
        )
    }

    private static func transitionSignature(_ trajectory: ProcedureTrajectory) -> String {
        trajectory.steps.map {
            [
                $0.transitionKind, $0.beforeState ?? "nil", $0.afterState ?? "nil",
                $0.actionKind ?? "nil", $0.evidenceKind ?? "nil",
                $0.checkpointClass ?? "nil", $0.terminalClass?.rawValue ?? "nil",
            ].joined(separator: "|")
        }.joined(separator: ">")
    }

    private static func checkpointSignature(_ trajectory: ProcedureTrajectory) -> String {
        trajectory.steps.map {
            [
                $0.checkpointClass ?? "none",
                $0.verificationClass ?? "none",
                $0.cancellationClass ?? "none",
            ].joined(separator: "|")
        }.joined(separator: ">")
    }

    private static func unique(_ values: [ProcedureCandidateBlockReason]) -> [ProcedureCandidateBlockReason] {
        var seen = Set<ProcedureCandidateBlockReason>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func validReview(_ review: ProcedureReviewerDecision) -> Bool {
        guard ProcedureTrajectoryExtractor.isOpaqueIdentity(review.candidateShapeIdentity),
              ProcedureTrajectoryExtractor.isOpaqueIdentity(review.reviewerIdentity),
              ProcedureTrajectoryExtractor.isOpaqueIdentity(review.approvalReceiptIdentity),
              ProcedureTrajectoryExtractor.isOpaqueIdentity(review.candidateEvidenceDigest) else { return false }
        return NativeTimestampFormat.parseISO8601FractionalFirst(review.decidedAt) != nil
    }
}
