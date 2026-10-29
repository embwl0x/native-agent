import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Darwin
// Blueprint: | `ProcedureArtifactValidity.swift` | ProcedureArtifactStore artifact, compiler identity and invocation receipt validity; shared token and timestamp predicates |

extension ProcedureArtifactStore {
    package static func valid(_ value: DeclarativeProcedureArtifact) -> Bool {
        guard let expectedDomain = ProcedureDomainContract.named(value.domain) else { return false }
        let allowedEffects = Set(value.inputContract.allowedExternalEffectClasses)
        let expectedPreconditions = Set([
            "authority_class_matches",
            "canonical_executor_available",
            "domain_state_matches",
            "input_schema_matches",
        ])
        let expectedRechecks: [ProcedureSafetyRecheckPoint] = [
            .beforeInvocation, .beforeEveryAction, .afterEveryCheckpoint,
        ]
        let validAuthority = value.authorityClass == "low_risk"
            || value.authorityClass == "confirm_required"
        let validApprovalOwner = value.authorityClass == "confirm_required"
            ? value.safety.canonicalApprovalOwner == "approval_inbox"
            : value.safety.canonicalApprovalOwner == nil
        let validRules = value.transitionTable.enumerated().allSatisfy { index, rule in
            index == rule.sequence
                && token(rule.onTransitionKind, maximum: 64)
                && token(rule.beforeState, maximum: 64, optional: true)
                && token(rule.afterState, maximum: 64, optional: true)
                && token(rule.actionKind, maximum: 64, optional: true)
                && token(rule.requiredEvidenceKind, maximum: 64, optional: true)
                && token(rule.expectedNextEvidence, maximum: 64, optional: true)
                && token(rule.checkpointClass, maximum: 64, optional: true)
                && token(rule.verificationClass, maximum: 64, optional: true)
                && allowedEffects.contains(rule.externalEffectClass)
                && token(rule.externalEffectClass, maximum: 64)
                && rule.externalEffectClass != "external_send"
                && rule.externalEffectClass != "unknown"
                && (rule.terminalClass == nil || index == value.transitionTable.count - 1)
        }
        let terminalCount = value.transitionTable.filter { $0.terminalClass != nil }.count
        let expectedAbandonConditions = Set(ProcedureCandidateCompiler.deterministicAbandonConditions)
        return (value.schema == DeclarativeProcedureArtifact.schema
                || value.schema == DeclarativeProcedureArtifact.legacySchema)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(value.id)
            && compilerIdentityMatches(value)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(value.procedureShapeIdentity)
            && !value.sourceTrajectoryIdentities.isEmpty
            && value.sourceTrajectoryIdentities.count <= 64
            && value.sourceTrajectoryIdentities.allSatisfy(ProcedureTrajectoryExtractor.isOpaqueIdentity)
            && Set(value.sourceTrajectoryIdentities).count == value.sourceTrajectoryIdentities.count
            && value.sourceTrajectoryIdentities == value.sourceTrajectoryIdentities.sorted()
            && value.interpretation == "trusted_declarative_transition_table_v1"
            && token(value.domain, maximum: 64)
            && token(value.inputContract.taskFamily, maximum: 128)
            && token(value.inputContract.inputClass, maximum: 128)
            && token(value.inputContract.parameterSchemaClass, maximum: 128)
            && !value.inputContract.acceptedParameterSchemaIdentities.isEmpty
            && value.inputContract.acceptedParameterSchemaIdentities.count <= 64
            && value.inputContract.acceptedParameterSchemaIdentities.allSatisfy(ProcedureTrajectoryExtractor.isOpaqueIdentity)
            && Set(value.inputContract.acceptedParameterSchemaIdentities).count
                == value.inputContract.acceptedParameterSchemaIdentities.count
            && value.inputContract.acceptedParameterSchemaIdentities
                == value.inputContract.acceptedParameterSchemaIdentities.sorted()
            && !allowedEffects.isEmpty
            && allowedEffects.count == value.inputContract.allowedExternalEffectClasses.count
            && allowedEffects.allSatisfy { token($0, maximum: 64) }
            && value.inputContract.allowedExternalEffectClasses
                == value.inputContract.allowedExternalEffectClasses.sorted()
            && !allowedEffects.contains("external_send")
            && !allowedEffects.contains("unknown")
            && validAuthority
            && validApprovalOwner
            && value.canonicalOracle == expectedDomain.oracle
            && value.deterministicFallback == expectedDomain.fallback
            && value.safety.trustCenterCapability == expectedDomain.capability
            && Set(value.safety.requiredPreconditions) == expectedPreconditions
            && value.safety.requiredPreconditions.count == expectedPreconditions.count
            && value.safety.recheckPoints == expectedRechecks
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(value.reviewerDecision.reviewerIdentity)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(value.reviewerDecision.approvalReceiptIdentity)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(value.reviewerDecision.candidateEvidenceDigest)
            && value.reviewerDecision.candidateShapeIdentity == value.procedureShapeIdentity
            && value.reviewerDecision.verdict == .approve
            && validTimestamp(value.reviewerDecision.decidedAt)
            && (!value.canaryEligible || value.reviewerDecision.scope == .manualAndCanary)
            && value.manualInvocationEligible
            && !value.automaticSelectionEligible
            && !value.generatedExecutableCode
            && !value.safety.externalSendsEligible
            && !value.safety.permissionAuthority
            && !value.safety.automaticActivationAllowed
            && Set(value.deterministicAbandonConditions) == expectedAbandonConditions
            && value.deterministicAbandonConditions.count == expectedAbandonConditions.count
            && (3...ProcedureTrajectoryExtractor.maximumSteps).contains(value.transitionTable.count)
            && validRules
            && terminalCount == 1
            && !value.inputContract.allowedExternalEffectClasses.contains("external_send")
            && value.rollbackDeclaration == "delete_artifact_restore_fallback_no_data_migration"
    }

    /// Verify the versioned compiler identity. Original v1 fingerprints admit
    /// discovery only; execution also requires a full-digest revalidation receipt.
    private static func compilerIdentityMatches(_ value: DeclarativeProcedureArtifact) -> Bool {
        guard let identity = try? value.canonicalIdentity() else { return false }
        switch value.schema {
        case DeclarativeProcedureArtifact.schema:
            return value.id == identity
        case DeclarativeProcedureArtifact.legacySchema:
            // Full-digest and original v1 identities both remain discoverable.
            return value.id == identity || value.id == value.legacyIdentity()
        default:
            return false
        }
    }

    static func token(_ raw: String, maximum: Int) -> Bool {
        token(Optional(raw), maximum: maximum, optional: false)
    }

    private static func token(_ raw: String?, maximum: Int, optional: Bool) -> Bool {
        guard let raw else { return optional }
        guard !raw.isEmpty, raw.count <= maximum else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func validTimestamp(_ raw: String) -> Bool {
        parsedTimestamp(raw) != nil
    }

    internal static func parsedTimestamp(_ raw: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    internal static func invocationReceipt(_ row: JSONValue) -> ProcedureInvocationReceipt? {
        guard let data = try? row.serializedData(pretty: false),
              let receipt = try? JSONDecoder().decode(ProcedureInvocationReceipt.self, from: data),
              receipt.schema == ProcedureInvocationReceipt.schema,
              ProcedureTrajectoryExtractor.isOpaqueIdentity(receipt.invocationID),
              ProcedureTrajectoryExtractor.isOpaqueIdentity(receipt.artifactID),
              ProcedureTrajectoryExtractor.isOpaqueIdentity(receipt.opaqueInputReference),
              validTimestamp(receipt.requestedAt),
              receipt.payloadFree, !receipt.permissionAuthority,
              validSelectionReceipt(receipt), validExecutionReceipt(receipt) else { return nil }
        return receipt
    }

    private static func validExecutionReceipt(_ receipt: ProcedureInvocationReceipt) -> Bool {
        guard receipt.dispatched == (receipt.executorStatus != nil) else { return false }
        guard receipt.dispatched else {
            return !receipt.authorityRechecked
                && !receipt.canonicalEvidenceMatched
                && !receipt.verified
        }
        guard let status = receipt.executorStatus else { return false }
        return ProcedureCanonicalExecutionResult(
            status: status, authorityRechecked: receipt.authorityRechecked,
            canonicalEvidenceMatched: receipt.canonicalEvidenceMatched, verified: receipt.verified
        ).isValid
    }

    private static func validSelectionReceipt(_ receipt: ProcedureInvocationReceipt) -> Bool {
        if receipt.automaticSelection {
            guard let activationID = receipt.activationID,
                  let procedureID = receipt.procedureID,
                  receipt.selectionMode == "exact_typed",
                  ProcedureTrajectoryExtractor.isOpaqueIdentity(activationID),
                  token(procedureID, maximum: 80) else { return false }
            return true
        }
        return receipt.activationID == nil
            && receipt.procedureID == nil
            && receipt.selectionMode == nil
    }
}
