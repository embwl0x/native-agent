import Foundation
import NativeAgentCore
import PersistenceCore

/// Provider-free invocation adapter for a compiled Workshop plan that has not
/// yet been admitted to the canonical queue. Queue admission happens *inside*
/// `ProcedureArtifactStore.invokeManual`. This closes the crash/race gap where
/// the resident Workshop drain could execute a newly queued record before the
/// procedure ledger had dispatched it.
///
/// The resident executor may still win the canonical queue claim after this
/// adapter submits; that is safe because the procedure invocation caused the
/// submission, the immutable plan already proves zero provider calls, and this
/// adapter accepts the result only after exact timeline replay and domain
/// verification match the approved artifact.
public struct WorkshopCompiledProcedureInvocationExecutor: ProcedureCanonicalExecuting, Sendable {
    public typealias SubmitAndExecute = @Sendable (
        _ invocationID: String
    ) async throws -> WorkshopExecutionRecord

    private let runner: SwiftNativeWorkshopRunner
    private let expectedExecutionID: String
    private let expectedContract: WorkshopProcedureContractProjection
    private let submitAndExecute: SubmitAndExecute

    public init(
        runner: SwiftNativeWorkshopRunner,
        expectedExecutionID: String,
        expectedContract: WorkshopProcedureContractProjection,
        submitAndExecute: @escaping SubmitAndExecute
    ) {
        self.runner = runner
        self.expectedExecutionID = expectedExecutionID
        self.expectedContract = expectedContract
        self.submitAndExecute = submitAndExecute
    }

    public func executeProcedureRule(
        artifact: DeclarativeProcedureArtifact,
        rule: ProcedureTransitionRule,
        opaqueInputReference: String,
        invocationID: String
    ) async throws -> ProcedureCanonicalExecutionResult {
        guard artifact.domain == "workshop_execution",
              artifact.canonicalOracle == .workshopRecordAndTimeline,
              artifact.authorityClass == "low_risk",
              artifact.reviewerDecision.verdict == .approve,
              artifact.manualInvocationEligible,
              !artifact.automaticSelectionEligible,
              !artifact.safety.externalSendsEligible,
              !artifact.safety.permissionAuthority,
              artifact.safety.trustCenterCapability == "workshop_execution",
              rule.sequence == 0,
              rule.actionKind == "queue_admission",
              rule.beforeState == nil,
              rule.afterState == "queued",
              opaqueInputReference == CausalTransitionEvidence.opaqueIdentity(expectedExecutionID),
              expectedContract.taskFamily == artifact.inputContract.taskFamily,
              expectedContract.inputClass == artifact.inputContract.inputClass,
              expectedContract.procedureShapeIdentity == artifact.procedureShapeIdentity,
              artifact.inputContract.acceptedParameterSchemaIdentities.contains(
                expectedContract.parameterSchemaIdentity
              ),
              expectedContract.authorityClass == artifact.authorityClass,
              Set(expectedContract.externalEffectClasses).isSubset(
                of: Set(artifact.inputContract.allowedExternalEffectClasses)
              ),
              !expectedContract.externalEffectClasses.contains("external_send"),
              !expectedContract.externalEffectClasses.contains("unknown") else {
            return Self.abstained(authorityRechecked: false)
        }

        let finalRecord = try await submitAndExecute(invocationID)
        guard finalRecord.id == expectedExecutionID,
              CausalTransitionEvidence.opaqueIdentity(finalRecord.id) == opaqueInputReference,
              ["none", "draft_auto"].contains(finalRecord.trustRequired),
              finalRecord.planningProviderCallCount == 0,
              finalRecord.planningRemovableOrchestrationProviderCallCount == 0,
              Self.hasExactZeroProviderStepAccounting(finalRecord),
              let finalContract = Self.contract(for: finalRecord),
              finalContract == expectedContract else {
            return Self.unverified(canonicalEvidenceMatched: false)
        }

        let timeline = try await runner.readTimeline(finalRecord.id)
        let evidence = SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: finalRecord.id,
            timeline: timeline,
            record: finalRecord
        )
        let extraction = ProcedureTrajectoryExtractor.extract(evidence)
        guard extraction.rejections.isEmpty,
              extraction.trajectories.count == 1,
              let trajectory = extraction.trajectories.first else {
            return Self.unverified(canonicalEvidenceMatched: false)
        }
        let replay = ProcedureReplayEngine.replay(
            artifact,
            against: trajectory,
            mode: .historicalExact
        )
        guard replay.status == .matched,
              replay.matchedStepCount == artifact.transitionTable.count,
              let action = try await runner.motorActionReadModel(actionId: finalRecord.id) else {
            return Self.unverified(canonicalEvidenceMatched: false)
        }
        switch (action.phase, action.verification) {
        case (.succeeded, .satisfied):
            return Self.verified(.verifiedSuccess)
        case (.failed, .failed):
            return Self.verified(.verifiedFailure)
        case (.cancelled, .notRequired):
            return Self.verified(.cancelled)
        default:
            return Self.unverified(canonicalEvidenceMatched: true)
        }
    }

    private static func hasExactZeroProviderStepAccounting(
        _ record: WorkshopExecutionRecord
    ) -> Bool {
        guard record.stepsCompleted.count == record.plan.count else { return false }
        return record.stepsCompleted.allSatisfy { row in
            guard case .object(let object) = row,
                  case .int(0)? = object["provider_call_count"],
                  case .int(0)? = object["removable_orchestration_provider_call_count"] else {
                return false
            }
            return true
        }
    }

    private static func contract(
        for record: WorkshopExecutionRecord
    ) -> WorkshopProcedureContractProjection? {
        let projection = SwiftNativeWorkshopRunner.procedureContractProjection(record: record)
        guard !projection.taskFamily.isEmpty,
              !projection.inputClass.isEmpty,
              !projection.parameterSchemaIdentity.isEmpty,
              !projection.procedureShapeIdentity.isEmpty else { return nil }
        return projection
    }

    private static func abstained(
        authorityRechecked: Bool
    ) -> ProcedureCanonicalExecutionResult {
        ProcedureCanonicalExecutionResult(
            status: .abstained,
            authorityRechecked: authorityRechecked,
            canonicalEvidenceMatched: false,
            verified: false
        )
    }

    private static func unverified(
        canonicalEvidenceMatched: Bool
    ) -> ProcedureCanonicalExecutionResult {
        ProcedureCanonicalExecutionResult(
            status: .unverified,
            authorityRechecked: true,
            canonicalEvidenceMatched: canonicalEvidenceMatched,
            verified: false
        )
    }

    private static func verified(
        _ status: ProcedureCanonicalExecutionStatus
    ) -> ProcedureCanonicalExecutionResult {
        ProcedureCanonicalExecutionResult(
            status: status,
            authorityRechecked: true,
            canonicalEvidenceMatched: true,
            verified: true
        )
    }
}
