import Foundation

// MARK: - Payload-free trajectory extraction

public enum ProcedureTerminalClass: String, Codable, Sendable, Equatable {
    case verifiedSuccess = "verified_success"
    case verifiedFailure = "verified_failure"
    case cancelled
}

public struct ProcedureTrajectoryStep: Codable, Sendable, Equatable {
    public let sequence: Int
    public let transitionKind: String
    public let beforeState: String?
    public let afterState: String?
    public let actionKind: String?
    public let evidenceKind: String?
    public let expectedNextEvidence: String?
    public let checkpointClass: String?
    public let retryClass: String?
    public let retryCount: Int?
    public let cancellationClass: String?
    public let motorPhase: String?
    public let verificationClass: String?
    public let terminalClass: ProcedureTerminalClass?
    public let externalEffectClass: String

    public init(
        sequence: Int,
        transitionKind: String,
        beforeState: String?,
        afterState: String?,
        actionKind: String?,
        evidenceKind: String?,
        expectedNextEvidence: String?,
        checkpointClass: String?,
        retryClass: String?,
        retryCount: Int?,
        cancellationClass: String?,
        motorPhase: String?,
        verificationClass: String?,
        terminalClass: ProcedureTerminalClass?,
        externalEffectClass: String
    ) {
        self.sequence = sequence
        self.transitionKind = transitionKind
        self.beforeState = beforeState
        self.afterState = afterState
        self.actionKind = actionKind
        self.evidenceKind = evidenceKind
        self.expectedNextEvidence = expectedNextEvidence
        self.checkpointClass = checkpointClass
        self.retryClass = retryClass
        self.retryCount = retryCount
        self.cancellationClass = cancellationClass
        self.motorPhase = motorPhase
        self.verificationClass = verificationClass
        self.terminalClass = terminalClass
        self.externalEffectClass = externalEffectClass
    }
}

/// A bounded, payload-free multi-step instance. Every identity is opaque and
/// every input field describes a type/schema, never a parameter value.
public struct ProcedureTrajectory: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let domain: String
    public let taskFamily: String
    public let inputClass: String
    public let inputInstanceIdentity: String
    public let parameterSchemaClass: String
    public let parameterSchemaIdentity: String
    public let procedureShapeIdentity: String
    public let authorityClass: String
    public let steps: [ProcedureTrajectoryStep]
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int
    public let terminalClass: ProcedureTerminalClass
    public let externalEffectClasses: [String]
    public let providerCallCount: Int?
    public let toolCallCount: Int?
    public let providerCostMicros: Int?
    public let toolCostMicros: Int?
    public let removableOrchestrationProviderCallCount: Int?
    public let retryCount: Int
    public let cancellationObserved: Bool
}

public enum ProcedureTrajectoryRejectionReason: String, Codable, Sendable, Equatable, Hashable {
    case missingMetadata = "missing_metadata"
    case invalidIdentity = "invalid_identity"
    case unorderedSequence = "unordered_sequence"
    case tooFewTransitions = "too_few_transitions"
    case tooManyTransitions = "too_many_transitions"
    case tooFewStateChanges = "too_few_state_changes"
    case tooFewActionEvidenceSteps = "too_few_action_evidence_steps"
    case inconsistentContract = "inconsistent_contract"
    case invalidChronology = "invalid_chronology"
    case durationExceeded = "duration_exceeded"
    case invalidTerminal = "invalid_terminal"
    case invalidCost = "invalid_cost"
    /// Generated/frozen laboratories can prove mechanics, but they cannot
    /// become evidence that Agent personally performed a production routine.
    case nonProductionEvidence = "non_production_evidence"
}

public struct ProcedureTrajectoryRejection: Sendable, Equatable {
    public let trajectoryIdentity: String?
    public let reasons: [ProcedureTrajectoryRejectionReason]
}

public struct ProcedureTrajectoryExtractionReport: Sendable, Equatable {
    public let trajectories: [ProcedureTrajectory]
    public let rejections: [ProcedureTrajectoryRejection]
    public let rowsWithoutTrajectoryIdentity: Int
}

public enum ProcedureTrajectoryExtractor {
    public static let maximumSteps = 16
    public static let defaultMaximumDuration: TimeInterval = 14 * 24 * 60 * 60

    public static func extract(
        _ evidence: [CausalTransitionEvidence],
        maximumDuration: TimeInterval = defaultMaximumDuration
    ) -> ProcedureTrajectoryExtractionReport {
        let boundedDuration = max(1, min(maximumDuration, defaultMaximumDuration))
        var rowsWithoutIdentity = 0
        var grouped: [String: [CausalTransitionEvidence]] = [:]
        for row in evidence {
            guard let trajectoryID = row.trajectoryID else {
                rowsWithoutIdentity += 1
                continue
            }
            grouped[trajectoryID, default: []].append(row)
        }

        var trajectories: [ProcedureTrajectory] = []
        var rejections: [ProcedureTrajectoryRejection] = []
        for identity in grouped.keys.sorted() {
            guard let rows = grouped[identity] else { continue }
            let result = extractOne(identity: identity, rows: rows, maximumDuration: boundedDuration)
            switch result {
            case .success(let trajectory): trajectories.append(trajectory)
            case .failure(let reasons):
                rejections.append(ProcedureTrajectoryRejection(
                    trajectoryIdentity: identity,
                    reasons: reasons
                ))
            }
        }
        return ProcedureTrajectoryExtractionReport(
            trajectories: trajectories,
            rejections: rejections,
            rowsWithoutTrajectoryIdentity: rowsWithoutIdentity
        )
    }

    private enum OneResult {
        case success(ProcedureTrajectory)
        case failure([ProcedureTrajectoryRejectionReason])
    }

    private static func extractOne(
        identity: String,
        rows: [CausalTransitionEvidence],
        maximumDuration: TimeInterval
    ) -> OneResult {
        var reasons: [ProcedureTrajectoryRejectionReason] = []
        if rows.contains(where: { $0.evidenceClass == .controlledSynthetic }) {
            reasons.append(.nonProductionEvidence)
        }
        if !isOpaqueIdentity(identity) { reasons.append(.invalidIdentity) }
        if rows.count < 3 { reasons.append(.tooFewTransitions) }
        if rows.count > maximumSteps { reasons.append(.tooManyTransitions) }

        let sorted = rows.sorted {
            let lhs = $0.sequenceNumber ?? Int.max
            let rhs = $1.sequenceNumber ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.operationId < $1.operationId
        }
        let sequences = sorted.compactMap(\.sequenceNumber)
        if sequences.count != sorted.count
            || Set(sequences).count != sequences.count
            || zip(sequences, sequences.dropFirst()).contains(where: { lhs, rhs in lhs >= rhs }) {
            reasons.append(.unorderedSequence)
        }

        guard let first = sorted.first, let last = sorted.last else {
            return .failure(unique(reasons + [.tooFewTransitions]))
        }
        let contracts: [[String?]] = sorted.map {
            [
                $0.domain, $0.taskFamily, $0.inputClass, $0.inputInstanceIdentity,
                $0.parameterSchemaClass, $0.parameterSchemaIdentity,
                $0.procedureShapeIdentity, $0.authorityClass,
            ]
        }
        guard let contract = contracts.first,
              contract.allSatisfy({ token($0, maximum: 128) != nil }),
              contracts.allSatisfy({ $0 == contract }),
              let domain = first.domain.nonEmptyToken,
              let taskFamily = first.taskFamily?.nonEmptyToken,
              let inputClass = first.inputClass?.nonEmptyToken,
              let inputIdentity = first.inputInstanceIdentity,
              let schemaClass = first.parameterSchemaClass?.nonEmptyToken,
              let schemaIdentity = first.parameterSchemaIdentity,
              let shapeIdentity = first.procedureShapeIdentity,
              let authorityClass = first.authorityClass?.nonEmptyToken
        else {
            reasons.append(.missingMetadata)
            return .failure(unique(reasons))
        }
        if !isOpaqueIdentity(inputIdentity)
            || !isOpaqueIdentity(schemaIdentity)
            || !isOpaqueIdentity(shapeIdentity) {
            reasons.append(.invalidIdentity)
        }
        if sorted.contains(where: { row in
            token(row.kind, maximum: 128) == nil
                || token(row.beforeState, maximum: 128) == nil && row.beforeState != nil
                || token(row.afterState, maximum: 128) == nil && row.afterState != nil
                || token(row.actionKind, maximum: 128) == nil && row.actionKind != nil
                || token(row.evidenceKind, maximum: 128) == nil && row.evidenceKind != nil
                || token(row.expectedNextEvidence, maximum: 128) == nil && row.expectedNextEvidence != nil
                || token(row.checkpointClass, maximum: 128) == nil && row.checkpointClass != nil
                || token(row.retryClass, maximum: 128) == nil && row.retryClass != nil
                || token(row.cancellationClass, maximum: 128) == nil && row.cancellationClass != nil
        }) {
            reasons.append(.missingMetadata)
        }

        let stateChanges = sorted.filter { $0.beforeState != $0.afterState }.count
        if stateChanges < 3 { reasons.append(.tooFewStateChanges) }
        let actionEvidenceCount = sorted.filter { $0.actionKind != nil || $0.evidenceKind != nil }.count
        if actionEvidenceCount < 2 { reasons.append(.tooFewActionEvidenceSteps) }

        let dates = sorted.compactMap { parseDate($0.occurredAt) }
        if dates.count != sorted.count,
           !reasons.contains(.invalidChronology) { reasons.append(.invalidChronology) }
        let startDate = dates.first ?? .distantPast
        let endDate = dates.last ?? .distantFuture
        let duration = endDate.timeIntervalSince(startDate)
        if duration < 0 || zip(dates, dates.dropFirst()).contains(where: { lhs, rhs in lhs > rhs }) {
            reasons.append(.invalidChronology)
        }
        if duration > maximumDuration { reasons.append(.durationExceeded) }

        let terminal = last.terminalClass.flatMap(ProcedureTerminalClass.init(rawValue:))
        if terminal == nil
            || sorted.dropLast().contains(where: { $0.terminalClass != nil })
            || (terminal != .cancelled && last.verificationClass != "verified")
            || (terminal == .cancelled && last.cancellationClass == nil) {
            reasons.append(.invalidTerminal)
        }

        let integerFacts = sorted.flatMap {
            [
                $0.retryCount, $0.latencyMilliseconds, $0.providerCallCount,
                $0.toolCallCount, $0.providerCostMicros, $0.toolCostMicros,
                $0.removableOrchestrationProviderCallCount,
            ]
        }.compactMap { $0 }
        if integerFacts.contains(where: { $0 < 0 || $0 > 1_000_000_000_000 }) {
            reasons.append(.invalidCost)
        }
        if sorted.contains(where: { token($0.externalEffectClass, maximum: 64) == nil }) {
            reasons.append(.missingMetadata)
        }
        guard reasons.isEmpty, let terminal else { return .failure(unique(reasons)) }

        let steps = sorted.map { row in
            ProcedureTrajectoryStep(
                sequence: row.sequenceNumber ?? 0,
                transitionKind: row.kind,
                beforeState: row.beforeState,
                afterState: row.afterState,
                actionKind: row.actionKind,
                evidenceKind: row.evidenceKind,
                expectedNextEvidence: row.expectedNextEvidence,
                checkpointClass: row.checkpointClass,
                retryClass: row.retryClass,
                retryCount: row.retryCount,
                cancellationClass: row.cancellationClass,
                motorPhase: row.motorPhase,
                verificationClass: row.verificationClass,
                terminalClass: row.terminalClass.flatMap(ProcedureTerminalClass.init(rawValue:)),
                externalEffectClass: row.externalEffectClass ?? "unknown"
            )
        }
        let durationMilliseconds = Int(min(Double(Int.max), max(0, duration * 1_000)))
        return .success(ProcedureTrajectory(
            id: identity,
            domain: domain,
            taskFamily: taskFamily,
            inputClass: inputClass,
            inputInstanceIdentity: inputIdentity,
            parameterSchemaClass: schemaClass,
            parameterSchemaIdentity: schemaIdentity,
            procedureShapeIdentity: shapeIdentity,
            authorityClass: authorityClass,
            steps: steps,
            startedAt: first.occurredAt,
            endedAt: last.occurredAt,
            durationMilliseconds: durationMilliseconds,
            terminalClass: terminal,
            externalEffectClasses: Array(Set(steps.map(\.externalEffectClass))).sorted(),
            providerCallCount: sumIfObserved(sorted.map(\.providerCallCount)),
            toolCallCount: sumIfObserved(sorted.map(\.toolCallCount)),
            providerCostMicros: sumIfObserved(sorted.map(\.providerCostMicros)),
            toolCostMicros: sumIfObserved(sorted.map(\.toolCostMicros)),
            removableOrchestrationProviderCallCount:
                sumIfObserved(sorted.map(\.removableOrchestrationProviderCallCount)),
            retryCount: sorted.compactMap(\.retryCount).max() ?? sorted.filter { $0.retryClass != nil }.count,
            cancellationObserved: terminal == .cancelled || sorted.contains { $0.cancellationClass != nil }
        ))
    }

    private static func sumIfObserved(_ values: [Int?]) -> Int? {
        let observed = values.compactMap { $0 }
        return observed.isEmpty ? nil : observed.reduce(0, +)
    }

    private static func unique(
        _ values: [ProcedureTrajectoryRejectionReason]
    ) -> [ProcedureTrajectoryRejectionReason] {
        var seen = Set<ProcedureTrajectoryRejectionReason>()
        return values.filter { seen.insert($0).inserted }
    }

    fileprivate static func isOpaqueIdentity(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    fileprivate static func token(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:/"))
        guard !value.isEmpty, value.count <= maximum,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension String {
    var nonEmptyToken: String? {
        ProcedureTrajectoryExtractor.token(self, maximum: 128)
    }
}

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

    /// Package-only: production review authority is minted by ApprovalInbox.
    /// External callers cannot manufacture an approved decision from a hash-
    /// shaped reviewer string.
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

public struct ProcedureCandidateConfiguration: Sendable, Equatable {
    public let minimumRepeatedTrajectories: Int
    public let minimumDistinctInputs: Int
    public let minimumVerifiedSuccessRate: Double
    public let minimumProductionTrajectories: Int
    public let minimumProductionDays: Int
    public let minimumProductionVerifiedSuccessRate: Double
    public let minimumRemovableProviderCallsPerTrajectory: Int

    public init(
        minimumRepeatedTrajectories: Int = 2,
        minimumDistinctInputs: Int = 2,
        minimumVerifiedSuccessRate: Double = 0.90,
        minimumProductionTrajectories: Int = 12,
        minimumProductionDays: Int = 3,
        minimumProductionVerifiedSuccessRate: Double = 0.95,
        minimumRemovableProviderCallsPerTrajectory: Int = 1
    ) {
        self.minimumRepeatedTrajectories = max(2, minimumRepeatedTrajectories)
        self.minimumDistinctInputs = max(2, minimumDistinctInputs)
        self.minimumVerifiedSuccessRate = min(1, max(0, minimumVerifiedSuccessRate))
        self.minimumProductionTrajectories = max(12, minimumProductionTrajectories)
        self.minimumProductionDays = max(3, minimumProductionDays)
        self.minimumProductionVerifiedSuccessRate = min(1, max(0.95, minimumProductionVerifiedSuccessRate))
        self.minimumRemovableProviderCallsPerTrajectory = max(1, minimumRemovableProviderCallsPerTrajectory)
    }
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
        reviewerDecisions: [ProcedureReviewerDecision] = [],
        configuration: ProcedureCandidateConfiguration = .init()
    ) -> [ProcedureCandidate] {
        // Once a compiled procedure is running, its canonical zero-provider
        // trajectories are effectiveness evidence for that implementation;
        // they are not counterfactual evidence that a provider call remains
        // removable. Mixing them back into discovery made a successful
        // compilation poison its own candidate on the next evaluation.
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
                review: decisions[shapeIdentity],
                configuration: configuration
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
        review: ProcedureReviewerDecision?,
        configuration: ProcedureCandidateConfiguration
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
            && holdoutRate >= configuration.minimumProductionVerifiedSuccessRate
        let removableValues = trajectories.map(\.removableOrchestrationProviderCallCount)
        let removableCalls: Int? = removableValues.allSatisfy { $0 != nil }
            ? removableValues.compactMap { $0 }.reduce(0, +)
            : nil
        let savingsPassed = removableCalls.map {
            $0 >= trajectories.count * configuration.minimumRemovableProviderCallsPerTrajectory
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
        if canonicalGroup.count < configuration.minimumRepeatedTrajectories {
            manualReasons.append(.repeatedShapeInsufficient)
        }
        if Set(trajectories.map(\.inputInstanceIdentity)).count < configuration.minimumDistinctInputs {
            manualReasons.append(.distinctInputsInsufficient)
        }
        if successRate < configuration.minimumVerifiedSuccessRate {
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
        if trajectories.count < configuration.minimumProductionTrajectories {
            canaryReasons.append(.productionTrajectoryCount)
        }
        if days.count < configuration.minimumProductionDays {
            canaryReasons.append(.productionDistinctDays)
        }
        if successRate < configuration.minimumProductionVerifiedSuccessRate {
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
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: review.decidedAt) != nil
            || ISO8601DateFormatter().date(from: review.decidedAt) != nil
    }
}

// MARK: - Immutable declarative artifact and replay

public enum ProcedureCanonicalOracle: String, Codable, Sendable, Equatable {
    case githubCommandReducer = "github_command_reducer"
    case workshopRecordAndTimeline = "workshop_record_and_timeline"
}

public enum ProcedureFallbackRoute: String, Codable, Sendable, Equatable {
    case githubCanonicalReducer = "github_canonical_reducer"
    case ordinaryWorkshopPlannerExecutor = "ordinary_workshop_planner_executor"
}

public enum ProcedureSafetyRecheckPoint: String, Codable, Sendable, Equatable {
    case beforeInvocation = "before_invocation"
    case beforeEveryAction = "before_every_action"
    case afterEveryCheckpoint = "after_every_checkpoint"
}

public struct ProcedureSafetyDeclaration: Codable, Sendable, Equatable {
    public let trustCenterCapability: String
    public let requiredPreconditions: [String]
    public let recheckPoints: [ProcedureSafetyRecheckPoint]
    public let canonicalApprovalOwner: String?
    public let externalSendsEligible: Bool
    public let permissionAuthority: Bool
    public let automaticActivationAllowed: Bool
}

public struct ProcedureInputContract: Codable, Sendable, Equatable {
    public let taskFamily: String
    public let inputClass: String
    public let parameterSchemaClass: String
    public let acceptedParameterSchemaIdentities: [String]
    public let allowedExternalEffectClasses: [String]
}

public struct ProcedureTransitionRule: Codable, Sendable, Equatable {
    public let sequence: Int
    public let beforeState: String?
    public let onTransitionKind: String
    public let actionKind: String?
    public let requiredEvidenceKind: String?
    public let expectedNextEvidence: String?
    public let checkpointClass: String?
    public let externalEffectClass: String
    public let afterState: String?
    public let verificationClass: String?
    public let terminalClass: ProcedureTerminalClass?
}

public struct DeclarativeProcedureArtifact: Codable, Sendable, Equatable, Identifiable {
    public static let schema = "declarative-procedure-transition-table.v1"

    public let schema: String
    public let id: String
    public let interpretation: String
    public let sourceTrajectoryIdentities: [String]
    public let domain: String
    public let procedureShapeIdentity: String
    public let inputContract: ProcedureInputContract
    public let authorityClass: String
    public let canonicalOracle: ProcedureCanonicalOracle
    public let transitionTable: [ProcedureTransitionRule]
    public let safety: ProcedureSafetyDeclaration
    public let deterministicAbandonConditions: [String]
    public let deterministicFallback: ProcedureFallbackRoute
    public let rollbackDeclaration: String
    public let reviewerDecision: ProcedureReviewerDecision
    public let manualInvocationEligible: Bool
    public let canaryEligible: Bool
    public let automaticSelectionEligible: Bool
    public let generatedExecutableCode: Bool
}

public enum ProcedureCompilationError: Error, Equatable {
    case candidateNotEligible
    case missingReviewerApproval
    case unsupportedDomain
}

public enum DeclarativeProcedureCompiler {
    public static func compile(_ candidate: ProcedureCandidate) throws -> DeclarativeProcedureArtifact {
        guard candidate.manualInvocationEligible else { throw ProcedureCompilationError.candidateNotEligible }
        guard let review = candidate.reviewerDecision, review.verdict == .approve,
              review.candidateEvidenceDigest == candidate.reviewBindingDigest else {
            throw ProcedureCompilationError.missingReviewerApproval
        }
        let oracle: ProcedureCanonicalOracle
        let fallback: ProcedureFallbackRoute
        let trustCapability: String
        switch candidate.canonicalTrajectory.domain {
        case "github_command":
            oracle = .githubCommandReducer
            fallback = .githubCanonicalReducer
            trustCapability = "github_connector"
        case "workshop_execution":
            oracle = .workshopRecordAndTimeline
            fallback = .ordinaryWorkshopPlannerExecutor
            trustCapability = "workshop_execution"
        default:
            throw ProcedureCompilationError.unsupportedDomain
        }
        let trajectory = candidate.canonicalTrajectory
        let table = trajectory.steps.enumerated().map { index, step in
            ProcedureTransitionRule(
                sequence: index,
                beforeState: step.beforeState,
                onTransitionKind: step.transitionKind,
                actionKind: step.actionKind,
                requiredEvidenceKind: step.evidenceKind,
                expectedNextEvidence: step.expectedNextEvidence,
                checkpointClass: step.checkpointClass,
                externalEffectClass: step.externalEffectClass,
                afterState: step.afterState,
                verificationClass: step.verificationClass,
                terminalClass: step.terminalClass
            )
        }
        let schemas = Array(Set(candidate.sourceTrajectories.map(\.parameterSchemaIdentity))).sorted()
        let effects = Array(Set(candidate.sourceTrajectories.flatMap(\.externalEffectClasses))).sorted()
        let approvalOwner = trajectory.authorityClass == "confirm_required" ? "approval_inbox" : nil
        let safety = ProcedureSafetyDeclaration(
            trustCenterCapability: trustCapability,
            requiredPreconditions: [
                "authority_class_matches",
                "canonical_executor_available",
                "domain_state_matches",
                "input_schema_matches",
            ],
            recheckPoints: [.beforeInvocation, .beforeEveryAction, .afterEveryCheckpoint],
            canonicalApprovalOwner: approvalOwner,
            externalSendsEligible: false,
            permissionAuthority: false,
            automaticActivationAllowed: false
        )
        let fingerprint = [
            trajectory.procedureShapeIdentity,
            trajectory.domain,
            trajectory.taskFamily,
            trajectory.inputClass,
            trajectory.authorityClass,
            schemas.joined(separator: ","),
            table.map {
                "\($0.sequence)|\($0.beforeState ?? "nil")|\($0.onTransitionKind)|\($0.actionKind ?? "nil")|\($0.requiredEvidenceKind ?? "nil")|\($0.externalEffectClass)|\($0.afterState ?? "nil")|\($0.terminalClass?.rawValue ?? "nil")"
            }.joined(separator: ">"),
            review.reviewerIdentity,
            review.decidedAt,
        ].joined(separator: "||")
        return DeclarativeProcedureArtifact(
            schema: DeclarativeProcedureArtifact.schema,
            id: CausalTransitionEvidence.opaqueIdentity(fingerprint),
            interpretation: "trusted_declarative_transition_table_v1",
            sourceTrajectoryIdentities: Array(candidate.sourceTrajectories.map(\.id).sorted().prefix(64)),
            domain: trajectory.domain,
            procedureShapeIdentity: trajectory.procedureShapeIdentity,
            inputContract: ProcedureInputContract(
                taskFamily: trajectory.taskFamily,
                inputClass: trajectory.inputClass,
                parameterSchemaClass: trajectory.parameterSchemaClass,
                acceptedParameterSchemaIdentities: schemas,
                allowedExternalEffectClasses: effects
            ),
            authorityClass: trajectory.authorityClass,
            canonicalOracle: oracle,
            transitionTable: table,
            safety: safety,
            deterministicAbandonConditions: candidate.deterministicAbandonConditions,
            deterministicFallback: fallback,
            rollbackDeclaration: "delete_artifact_restore_fallback_no_data_migration",
            reviewerDecision: review,
            manualInvocationEligible: true,
            canaryEligible: candidate.canaryEligible,
            automaticSelectionEligible: false,
            generatedExecutableCode: false
        )
    }
}

public enum ProcedureReplayMode: String, Codable, Sendable, Equatable {
    case historicalExact = "historical_exact"
    case generatedFault = "generated_fault"
}

public enum ProcedureReplayStatus: String, Codable, Sendable, Equatable {
    case matched
    case fallback
    case abstained
}

public enum ProcedureReplayReason: String, Codable, Sendable, Equatable {
    case exactMatch = "exact_match"
    case novelInput = "novel_input"
    case authorityDiverged = "authority_diverged"
    case canonicalEvidenceMismatch = "canonical_evidence_mismatch"
    case externalSendIneligible = "external_send_ineligible"
}

public struct ProcedureReplayResult: Sendable, Equatable {
    public let mode: ProcedureReplayMode
    public let status: ProcedureReplayStatus
    public let reason: ProcedureReplayReason
    public let matchedStepCount: Int
    public let canonicalOracle: ProcedureCanonicalOracle
    public let fallback: ProcedureFallbackRoute
}

public enum ProcedureInvocationMode: String, Codable, Sendable, Equatable {
    case manual
    case canary
}

public struct ProcedureDryRunContext: Sendable, Equatable {
    public let invocationMode: ProcedureInvocationMode
    public let taskFamily: String
    public let inputClass: String
    public let parameterSchemaIdentity: String
    public let authorityClass: String
    public let requestedExternalEffectClass: String
    public let currentState: String?
    public let nextRuleIndex: Int
    public let trustCenterAllowed: Bool
    public let preconditionResults: [String: Bool]
    public let canonicalApprovalOwnerRechecked: Bool
    public let cancellationRequested: Bool

    public init(
        invocationMode: ProcedureInvocationMode,
        taskFamily: String,
        inputClass: String,
        parameterSchemaIdentity: String,
        authorityClass: String,
        requestedExternalEffectClass: String,
        currentState: String?,
        nextRuleIndex: Int,
        trustCenterAllowed: Bool,
        preconditionResults: [String: Bool],
        canonicalApprovalOwnerRechecked: Bool,
        cancellationRequested: Bool
    ) {
        self.invocationMode = invocationMode
        self.taskFamily = taskFamily
        self.inputClass = inputClass
        self.parameterSchemaIdentity = parameterSchemaIdentity
        self.authorityClass = authorityClass
        self.requestedExternalEffectClass = requestedExternalEffectClass
        self.currentState = currentState
        self.nextRuleIndex = nextRuleIndex
        self.trustCenterAllowed = trustCenterAllowed
        self.preconditionResults = preconditionResults
        self.canonicalApprovalOwnerRechecked = canonicalApprovalOwnerRechecked
        self.cancellationRequested = cancellationRequested
    }
}

public enum ProcedureDryRunStatus: String, Codable, Sendable, Equatable {
    case wouldAdvance = "would_advance"
    case wouldComplete = "would_complete"
    case abstained
    case fallback
    case cancelled
}

public enum ProcedureDryRunReason: String, Codable, Sendable, Equatable {
    case exactDryRun = "exact_dry_run"
    case invocationNotEligible = "invocation_not_eligible"
    case novelInput = "novel_input"
    case authorityDiverged = "authority_diverged"
    case externalSendIneligible = "external_send_ineligible"
    case trustCenterDenied = "trust_center_denied"
    case preconditionFailed = "precondition_failed"
    case approvalOwnerNotRechecked = "approval_owner_not_rechecked"
    case stateDiverged = "state_diverged"
    case cancellationRequested = "cancellation_requested"
}

public struct ProcedureDryRunResult: Sendable, Equatable {
    public let status: ProcedureDryRunStatus
    public let reason: ProcedureDryRunReason
    public let proposedRule: ProcedureTransitionRule?
    public let fallback: ProcedureFallbackRoute
    public let dispatchedAction: Bool
}

public enum ProcedureReplayEngine {
    public static func replay(
        _ artifact: DeclarativeProcedureArtifact,
        against trajectory: ProcedureTrajectory,
        mode: ProcedureReplayMode
    ) -> ProcedureReplayResult {
        func result(
            _ status: ProcedureReplayStatus,
            _ reason: ProcedureReplayReason,
            matched: Int
        ) -> ProcedureReplayResult {
            ProcedureReplayResult(
                mode: mode,
                status: status,
                reason: reason,
                matchedStepCount: matched,
                canonicalOracle: artifact.canonicalOracle,
                fallback: artifact.deterministicFallback
            )
        }
        guard artifact.inputContract.taskFamily == trajectory.taskFamily,
              artifact.inputContract.inputClass == trajectory.inputClass,
              artifact.inputContract.acceptedParameterSchemaIdentities.contains(
                trajectory.parameterSchemaIdentity
              ) else { return result(.abstained, .novelInput, matched: 0) }
        guard artifact.authorityClass == trajectory.authorityClass else {
            return result(.fallback, .authorityDiverged, matched: 0)
        }
        guard !trajectory.externalEffectClasses.contains("external_send") else {
            return result(.abstained, .externalSendIneligible, matched: 0)
        }
        guard artifact.transitionTable.count == trajectory.steps.count else {
            return result(.fallback, .canonicalEvidenceMismatch, matched: 0)
        }
        var matched = 0
        for (index, pair) in zip(artifact.transitionTable, trajectory.steps).enumerated() {
            let rule = pair.0
            let step = pair.1
            guard rule.sequence == index,
                  rule.beforeState == step.beforeState,
                  rule.onTransitionKind == step.transitionKind,
                  rule.actionKind == step.actionKind,
                  rule.requiredEvidenceKind == step.evidenceKind,
                  rule.expectedNextEvidence == step.expectedNextEvidence,
                  rule.checkpointClass == step.checkpointClass,
                  rule.externalEffectClass == step.externalEffectClass,
                  rule.afterState == step.afterState,
                  rule.verificationClass == step.verificationClass,
                  rule.terminalClass == step.terminalClass else {
                return result(.fallback, .canonicalEvidenceMismatch, matched: matched)
            }
            matched += 1
        }
        return result(.matched, .exactMatch, matched: matched)
    }

    /// Pure current-state eligibility check. It returns a declarative rule and
    /// never dispatches it; the canonical executor remains the only action owner.
    public static func dryRun(
        _ artifact: DeclarativeProcedureArtifact,
        context: ProcedureDryRunContext
    ) -> ProcedureDryRunResult {
        func result(
            _ status: ProcedureDryRunStatus,
            _ reason: ProcedureDryRunReason,
            rule: ProcedureTransitionRule? = nil
        ) -> ProcedureDryRunResult {
            ProcedureDryRunResult(
                status: status,
                reason: reason,
                proposedRule: rule,
                fallback: artifact.deterministicFallback,
                dispatchedAction: false
            )
        }
        if context.cancellationRequested {
            return result(.cancelled, .cancellationRequested)
        }
        if context.invocationMode == .manual, !artifact.manualInvocationEligible {
            return result(.abstained, .invocationNotEligible)
        }
        if context.invocationMode == .canary, !artifact.canaryEligible {
            return result(.abstained, .invocationNotEligible)
        }
        guard context.taskFamily == artifact.inputContract.taskFamily,
              context.inputClass == artifact.inputContract.inputClass,
              artifact.inputContract.acceptedParameterSchemaIdentities.contains(
                context.parameterSchemaIdentity
              ) else { return result(.abstained, .novelInput) }
        guard context.authorityClass == artifact.authorityClass else {
            return result(.fallback, .authorityDiverged)
        }
        guard context.requestedExternalEffectClass != "external_send",
              artifact.inputContract.allowedExternalEffectClasses.contains(
                context.requestedExternalEffectClass
              ) else { return result(.abstained, .externalSendIneligible) }
        guard context.trustCenterAllowed else { return result(.fallback, .trustCenterDenied) }
        guard artifact.safety.requiredPreconditions.allSatisfy({
            context.preconditionResults[$0] == true
        }) else { return result(.fallback, .preconditionFailed) }
        if artifact.safety.canonicalApprovalOwner != nil,
           !context.canonicalApprovalOwnerRechecked {
            return result(.fallback, .approvalOwnerNotRechecked)
        }
        guard artifact.transitionTable.indices.contains(context.nextRuleIndex) else {
            return result(.fallback, .stateDiverged)
        }
        let rule = artifact.transitionTable[context.nextRuleIndex]
        guard rule.beforeState == context.currentState else {
            return result(.fallback, .stateDiverged)
        }
        guard rule.externalEffectClass == context.requestedExternalEffectClass else {
            return result(.fallback, .stateDiverged)
        }
        return result(
            rule.terminalClass == nil ? .wouldAdvance : .wouldComplete,
            .exactDryRun,
            rule: rule
        )
    }
}
