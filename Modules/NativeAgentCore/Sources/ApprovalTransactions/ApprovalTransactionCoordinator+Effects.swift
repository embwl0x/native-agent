import Foundation
import PersonaEngine
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnRuntime
import ChatTurnContracts
import MemoryV2
import TrustCenter
import WorkshopExecution
// Blueprint: | `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects` port; `ApprovalExecution.decideBlockedWorkshopStep`; workshop-step decision/approval transaction |

/// Effect adapters supplied by the host; transaction ordering and replay fences
/// remain in ApprovalExecution.
public protocol ApprovalTransactionEffects: Sendable {
    func disableSkill(name: String) async throws
    /// `reviewedDigest` nil restores only Markdown guidance; a digest
    /// admits exactly that script as User's, as the Skills page's Install does.
    func enableSkill(name: String, reviewedDigest: String?) async throws
    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue], approvedReplayApprovalID: String, dataRoot: URL) async throws -> ConnectorActionReceipt
    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient
    func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String, fileAccess: String) async throws
    func chatTurnCompleted(sessionID: String?) async
    func observeBrowserMotorAction(runID: String, dataRoot: URL) async
    func executeApprovedBrowserRun(from record: ApprovalRecord) async throws
    func finishRejectedBrowserRun(from record: ApprovalRecord, status: String) async throws
    func workshopExecutor() -> WorkshopExecutorLoop
    func workshopStepNotFound(_ description: String) -> any Error
}

public extension ApprovalExecution {
    /// Deny or Approve on the Desk's waiting step (MacWorkOverviewDetail), for
    /// the agent: the same `rejectStep` / `approveStep`, decided in her name.
    /// Only the step the task is blocked on; approving is User's below Full
    /// Mac, and the door refuses it there.
    func decideBlockedWorkshopStep(id: String, approve: Bool, runner: @Sendable () -> SwiftNativeWorkshopRunner) async throws -> JSONValue {
        guard let execution = try await runner().getWorkshopExecution(id) else {
            return .object(["status": .string("not_found"), "id": .string(id),
                "detail": .string("No Desk task has this execution id. app workshop.status lists them.")])
        }
        // "manual" is the person's own: the Desk, the iPhone, Siri. His work is
        // not hers to stop. Hers is "agent" (workshop_submit) or background.
        guard approve || execution.triggerSource != "manual" else {
            return .object(["status": .string("not_yours"), "id": .string(id),
                "detail": .string("The person started this task, so denying its step is his call; nothing was denied. Tell him what is wrong with the step, or ask him to deny it on the Desk.")])
        }
        guard execution.status == "blocked_on_approval", !execution.currentStepId.isEmpty else {
            return .object(["status": .string("not_blocked"), "id": .string(id), "execution_status": .string(execution.status),
                "detail": .string("This task is \(execution.status), not waiting on a step approval, so there is nothing to \(approve ? "approve" : "deny").")])
        }
        let provenance = ApprovalResolutionProvenance.local(
            decidedBy: PersonaCompiler.agentDisplayName(dataRoot: dataRoot))
        if approve {
            // A step that cannot be undone on his side waits for his tap even
            // under Full Mac (User, 10-17); her approve never stands in for his.
            let staged = try await stagedWorkshopStep(executionId: id, stepId: execution.currentStepId)
            if PermissionLaw.humanDecides(action: staged.action, payload: staged.payload) {
                return .object(["status": .string("owners_call"), "id": .string(id), "step_id": .string(execution.currentStepId),
                    "detail": .string("That step would run something that cannot be undone on the person's side, so its card waits for their tap even under Full Mac. Nothing was approved; leave it for them, or deny it.")])
            }
            let record = try await resolveWorkshopStep(
                executionId: id, stepId: execution.currentStepId, decision: "approve", provenance: provenance, runner: runner())
            return .object(["status": .string("approved"), "id": .string(id), "step_id": .string(execution.currentStepId),
                "execution_status": .string(record.status),
                "detail": .string("Approved the waiting step; the task runs on from it.")])
        }
        let record = try await resolveWorkshopStep(
            executionId: id, stepId: execution.currentStepId, decision: "reject", provenance: provenance, runner: runner())
        return .object(["status": .string("rejected"), "id": .string(id), "step_id": .string(execution.currentStepId),
            "execution_status": .string(record.status),
            "detail": .string("Denied the waiting step; the task stops without running it.")])
    }

    /// Select the exact staged step before any decision or execution write.
    func resolveWorkshopStep(
        executionId: String,
        stepId: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui"),
        runner: SwiftNativeWorkshopRunner
    ) async throws -> WorkshopExecution.WorkshopExecutionRecord {
        guard try await runner.getWorkshopExecution(executionId) != nil else {
            throw effects.workshopStepNotFound("workshop execution \(executionId)")
        }
        let staged = try await stagedWorkshopStep(executionId: executionId, stepId: stepId)
        _ = try await resolveApproval(
            id: staged.id,
            decision: decision,
            provenance: provenance
        )
        guard let record = try await runner.getWorkshopExecution(executionId) else {
            throw effects.workshopStepNotFound("workshop execution \(executionId)")
        }
        return record
    }

    /// The pending card staged for exactly this step.
    func stagedWorkshopStep(executionId: String, stepId: String) async throws -> ApprovalRecord {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        try await inbox.mergeLegacyApprovalRows()
        let pending = try await inbox.list(filter: ApprovalFilter(status: "pending"))
        guard let staged = pending.first(where: { record in
            guard ExecutionEventVocabulary.matches(
                      record.action, WorkshopStepApprovalAction.canonical),
                  case .object(let payload) = record.payload,
                  let rowExecutionId = WorkshopStepApprovalPayload.executionId({ key in
                      if case .string(let value)? = payload[key] { return value }
                      return nil
                  }),
                  case .string(let rowStepId)? = payload["step_id"] else { return false }
            return rowExecutionId == executionId && rowStepId == stepId
        }) else {
            throw effects.workshopStepNotFound(
                "pending \(WorkshopStepApprovalAction.canonical) approval for "
                    + "\(executionId)/\(stepId)"
            )
        }
        return staged
    }
}
