import Foundation
import PersistenceCore
import NativeAgentCore
import ApprovalInbox
import NativeAgentShared
// Blueprint: | `WorkshopExecution+Approvals.swift` | `WorkshopExecutorLoop` resolved-step approval evidence, resumption, rejection, annotation and blocked-step claim clearing through ExecutionRecordFile |

extension WorkshopExecutorLoop {
    func resolvedStepApproval(_ execution: WorkshopExecutionRecord) async throws -> (approval: ApprovalRecord, step: WorkshopExecutionStep)? {
        guard case .object(let step)? = Self.lastStepRecord(execution, stepId: execution.currentStepId),
              case .string(let id)? = step["approval_id"], !id.isEmpty else { return nil }
        let approval = try await SwiftNativeApprovalInbox(root: root).get(id)
        guard approval.status == "resolved", approval.decision == "approved",
              ExecutionEventVocabulary.matches(approval.action, WorkshopStepApprovalAction.canonical),
              case .object(let payload) = approval.payload,
              WorkshopStepApprovalPayload.executionId({ key in
                  if case .string(let value)? = payload[key] { return value }; return nil
              }) == execution.id,
              payload["step_id"] == .string(execution.currentStepId),
              let planStep = execution.plan.first(where: { $0.id == execution.currentStepId }),
              case .string(let tool)? = payload["tool"],
              case .object(let args)? = payload["args"] else { return nil }
        var approvedStep = planStep
        approvedStep.args = payload["source_args"] ?? .object(args)
        let call = Self.resolvedStepCall(approvedStep, execution: execution, resolveReferences: false)
        guard call.tool == tool, call.args == .object(args) else { return nil }
        return (approval, approvedStep)
    }

    // MARK: resume after approval

    /// Approval executes the admitted step before continuing; rejection fails it.
    @discardableResult
    public func resumeAfterApproval(
        executionId: String,
        stepId: String,
        approved: Bool,
        approvalId: String? = nil
    ) async throws -> WorkshopExecutionRecord {
        guard SwiftNativeWorkshopRunner.isSafeExecutionID(executionId) else {
            throw WorkshopExecutionError.invalidRequest(
                "executionId must be a single path component"
            )
        }
        // Reconcile before a blocked step can become this process’s running work.
        try await ensureOrphansReconciled()
        guard let execution = try await getRecord(executionId) else {
            throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(executionId)")
        }
        try SwiftNativeWorkshopRunner.validateStepIDs(execution.plan)
        let existing = Self.lastStepRecord(execution, stepId: stepId)
        let existingStatus: String = {
            if case .object(let o)? = existing, case .string(let s)? = o["status"] { return s }
            return ""
        }()
        let existingApprovalId: String = {
            if case .object(let o)? = existing, case .string(let s)? = o["approval_id"] { return s }
            return ""
        }()
        if let approvalId, !approvalId.isEmpty, !existingApprovalId.isEmpty, approvalId != existingApprovalId {
            throw WorkshopExecutionError.invalidRequest("approval_id_does_not_match_blocked_step")
        }
        if existing == nil && execution.status != "blocked_on_approval" {
            throw WorkshopExecutionError.invalidRequest("mission_step_not_waiting_on_approval")
        }
        if existingStatus == WorkshopStepOutcome.successStatus || existingStatus == "stubbed" {
            if approved {
                await annotateApprovedStep(execution, stepId: stepId, approvalId: approvalId)
            }
            try await appendTimelineLocked(
                .object([
                    "event": .string("approval_decision_ignored"),
                    "step_id": .string(stepId),
                    "reason": .string("step_already_completed"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            return execution
        }
        if existingStatus == "rejected" && !approved {
            return execution
        }
        if approved && !existingStatus.isEmpty && existingStatus != "blocked_on_approval" {
            throw WorkshopExecutionError.invalidRequest("mission_step_not_waiting_on_approval:\(existingStatus)")
        }

        // A stale card cannot revive terminal work; check under the record lock
        // and claim before dispatch without holding that lock across the effect.
        let lockedStatus = try await readRecordLocked(executionId)?.status ?? ""
        guard lockedStatus == "blocked_on_approval" else {
            throw WorkshopExecutionError.staleApproval(
                "Workshop execution no longer blocked (status=\(lockedStatus.isEmpty ? "missing" : lockedStatus)) — not executed")
        }

        if !approved {
            try await appendTimelineLocked(
                .object([
                    "event": .string("approval_decision"),
                    "step_id": .string(stepId),
                    "approved": .bool(false),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            // A concurrent cancel wins the CAS and suppresses the failed event.
            let denyWrite = try await casMutateWorkshopExecution(executionId, require: ["blocked_on_approval"]) { rec in
                rec.stepsCompleted = rec.stepsCompleted.map { sr in
                    guard case .object(var o) = sr, case .string(let sid)? = o["step_id"], sid == stepId else { return sr }
                    o["status"] = .string("rejected")
                    return .object(o)
                }
                rec.status = "failed"
                rec.terminalReason = "Step rejected by user"
                rec.currentStepId = ""   // terminal — clear the step pointer
            }
            guard denyWrite.applied, let updated = denyWrite.record else {
                return denyWrite.record ?? execution
            }
            try await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "step_id": .string(stepId),
                    "error": .string("Step rejected by user"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            await emitTerminalEvent(updated, reason: "Step rejected by user")
            return updated
        }

        // Resumption claims running before dispatch, excluding approval expiry.
        // A crash after the claim leaves running work for honest orphan recovery.
        guard let approvalId, !approvalId.isEmpty,
              execution.currentStepId == stepId,
              let resolved = try? await resolvedStepApproval(execution),
              resolved.approval.id == approvalId else {
            throw WorkshopExecutionError.forbidden("Workshop step approval evidence does not match")
        }
        let approvedStep = resolved.step
        guard await executionAllowed() else {
            throw WorkshopExecutionError.forbidden("Workshop execution is disabled by trust policy")
        }
        guard let resumed = try await claim(executionId, from: "blocked_on_approval", stepId: stepId) else {
            let current = try await getRecord(executionId)
            guard current?.status == "blocked_on_approval", current?.currentStepId == stepId else {
                throw WorkshopExecutionError.staleApproval("Workshop execution no longer blocked on this step — not executed")
            }
            throw WorkshopExecutionError.approvalDeferred
        }
        // Every exceptional exit after the claim must release capacity. Keep
        // a returned step outcome even if its execution.json write was interrupted.
        var approvedOutcome: WorkshopStepOutcome?
        do {
            // A capacity deferral must not write timeline events and wake its own drain.
            try await appendTimelineLocked(
                .object([
                    "event": .string("approval_decision"),
                    "step_id": .string(stepId),
                    "approved": .bool(true),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            let result = await dispatchStep(execution: resumed, step: approvedStep, approvalId: approvalId)
            approvedOutcome = result
            if Task.isCancelled && result.status == "cancelled" {
                await releaseClaimAfterInterruption(executionId, outcome: result)
                return try await getRecord(executionId) ?? execution
            }
            guard let saved = try await commitStepOutcome(executionId, outcome: result, approvedStep: approvedStep) else {
                return try await getRecord(executionId) ?? execution
            }
            guard saved.status == "running" else {
                await annotateApprovedStep(saved, stepId: stepId, approvalId: approvalId)
                return saved
            }
            try await runSteps(executionId: executionId)
            let final = try await getRecord(executionId) ?? execution
            await annotateApprovedStep(final, stepId: stepId, approvalId: approvalId)
            return final
        } catch {
            let reason = Task.isCancelled || error is CancellationError
                ? "parent_task_cancelled" : "approval_resume_failed"
            await releaseClaimAfterInterruption(executionId, reason: reason, outcome: approvedOutcome)
            if approvedOutcome != nil {
                await annotateApprovedStep((try? await getRecord(executionId)) ?? execution,
                    stepId: stepId, approvalId: approvalId)
            }
            throw error
        }
    }

    /// The execution owner clears a blocked step's claim under its record lock.
    /// Retain every other JSON field and timestamp; this is not a state transition.
    package func clearStepApprovalClaim(executionId: String, stepId: String) async {
        do {
            try await ExecutionRecordFile.clearStepApprovalClaim(
                executionId: executionId, stepId: stepId, dataRoot: root)
        } catch {
            nativeLog("[workshopStep] claim clear failed for \(executionId)/\(stepId): \(error)")
        }
    }

    private func annotateApprovedStep(_ record: WorkshopExecutionRecord, stepId: String, approvalId: String?) async {
        guard let approvalId, !approvalId.isEmpty else { return }
        try? await SwiftNativeApprovalInbox(root: root).annotateExecution(
            approvalId,
            executedAction: .object([
                "op": .string("mission_step_resume"),
                "missionId": .string(record.id),
                "stepId": .string(stepId),
                "missionStatus": .string(record.status),
            ]),
            detail: "Desk step approved — executed; Desk execution now \(record.status)")
    }

    /// Read approval preconditions under the execution record’s cross-process lock.
    private func readRecordLocked(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        guard SwiftNativeWorkshopRunner.isSafeExecutionID(executionId) else { return nil }
        let executionRecordJSON = executionRecordPath(executionId)
        return try await ExecutionRecordFile.readLocked(at: executionRecordJSON, id: executionId)
    }
}
