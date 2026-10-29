import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `WorkshopApprovalExecution.swift` | Browser and Workshop approval effects |
extension ApprovalExecution {
    /// A terminal run repairs its receipt without navigating again; execution errors propagate.
    func executeResolvedBrowserRun(from rec: ApprovalRecord) async throws {
        guard rec.action == "browser.open_url", rec.status == "resolved",
              let decision = rec.decision else { return }
        if decision == "approved" {
            let runsPath = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot).runsPath
            if case .object(let payload) = rec.payload,
               case .string(let runID)? = payload["runId"] ?? payload["run_id"],
               let run = try await Self.terminalBrowserRun(runID: runID, runsPath: runsPath) {
                let status = run.objectValue?["status"]?.stringValue ?? "succeeded"
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id, executedAction: run,
                    detail: "Browser navigation \(status) (annotation healed; URL not re-opened)")
                await effects.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
                return
            }
            try await effects.executeApprovedBrowserRun(from: rec)
        } else {
            try await effects.finishRejectedBrowserRun(
                from: rec, status: decision == "denied" ? "denied" : "canceled")
        }
    }
    /// The persisted run for `runID` iff its status is terminal. A
    /// `waiting_approval` row (persisted at approval-creation time) is NOT
    /// terminal — the navigation never ran and a reconcile may execute it.
    public static func terminalBrowserRun(runID: String, runsPath: URL) async throws -> JSONValue? {
        try await SwiftNativeBrowserClient.terminalRun(id: runID, at: runsPath)
    }
    /// Approved steps execute and continue; denied steps reject and fail the plan.
    /// Completed branches annotate; capacity deferral leaves the decision for the drain.
    /// Infrastructure failure clears the step's approval claim for re-staging.
    func applyResolvedWorkshopStep(from rec: ApprovalRecord) async {
        // Accept resolved step approvals in either action vocabulary.
        guard ExecutionEventVocabulary.matches(rec.action, WorkshopStepApprovalAction.canonical),
              rec.status == "resolved",
              let decision = rec.decision else { return }
        // Read execution_id first, then mission_id; persisted requests.json is not rewritten.
        guard case .object(let payload) = rec.payload,
              let executionId = WorkshopStepApprovalPayload.executionId({ key in
                  if case .string(let s)? = payload[key] { return s }
                  return nil
              }),
              case .string(let stepId)? = payload["step_id"], !stepId.isEmpty else {
            nativeLog("[workshopStep] missing execution_id/step_id on approval \(rec.id)")
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(["error": .string("missing execution_id/step_id")]),
                detail: "Desk step \(decision) FAILED: payload carries no execution_id/step_id")
            return
        }
        // The host supplies this data root's executor; startup reclaim is shared per data root.
        let executor = effects.workshopExecutor()
        // missionId, missionStatus and mission_step_* are permanent audit spellings
        // in executedAction within workflows/approvals/requests.json.
        do {
            switch decision {
            case "approved":
                _ = try await executor.resumeAfterApproval(
                    executionId: executionId, stepId: stepId, approved: true, approvalId: rec.id)
            case "denied":
                let record = try await executor.resumeAfterApproval(
                    executionId: executionId, stepId: stepId, approved: false, approvalId: rec.id)
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "op": .string("mission_step_reject"),
                        "missionId": .string(executionId),
                        "stepId": .string(stepId),
                        "missionStatus": .string(record.status),
                    ]),
                    detail: "Desk step denied — step rejected; Desk execution now \(record.status)")
            default: // canceled — leave the Workshop execution blocked; clear the claim
                // so a later executor pass can re-stage a fresh approval.
                await executor.clearStepApprovalClaim(executionId: executionId, stepId: stepId)
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "op": .string("mission_step_cancel"),
                        "missionId": .string(executionId),
                        "stepId": .string(stepId),
                    ]),
                    detail: "Desk step approval canceled — claim cleared; Desk execution stays blocked")
            }
        } catch WorkshopExecutionError.approvalDeferred {
            // Preserve the resolved decision and approval_id. Capacity-opening
            // execution events wake the drain, which retries this exact approval.
            return
        } catch WorkshopExecutionError.staleApproval(let detail) {
            // The executor's domain preflight refused a stale card; annotate without
            // clearing its claim or reporting a generic execution failure.
            nativeLog("[workshopStep] \(decision) skipped for \(executionId)/\(stepId): \(detail)")
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("mission_step_stale"),
                    "missionId": .string(executionId),
                    "stepId": .string(stepId),
                ]),
                detail: "Desk step \(decision) — \(detail)")
        } catch {
            nativeLog("[workshopStep] \(decision) failed for \(executionId)/\(stepId): \(error)")
            // Clear the failed step's approval claim so it can be re-staged.
            await executor.clearStepApprovalClaim(executionId: executionId, stepId: stepId)
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "missionId": .string(executionId),
                    "stepId": .string(stepId),
                    "error": .string("\(error)"),
                ]),
                detail: "Desk step \(decision) FAILED: \(error.localizedDescription) — "
                    + "claim cleared; a later executor pass can re-stage it")
        }
    }
}
