import Foundation

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
