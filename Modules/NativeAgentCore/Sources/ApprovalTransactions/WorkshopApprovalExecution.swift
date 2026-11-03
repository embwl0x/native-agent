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
// Blueprint: | `WorkshopApprovalExecution.swift` | Browser effects return their actual run to the checked approval settlement owner; malformed execution/refusal throws after failure annotation, failed saves retain the outcome for receipt-only repair; Workshop approval effects |
extension ApprovalExecution {
    /// A terminal run repairs its receipt without navigating again; execution errors propagate.
    func executeResolvedBrowserRun(from rec: ApprovalRecord) async throws {
        guard rec.action == "browser.open_url", rec.status == "resolved",
              let decision = rec.decision else { return }
        let owners = ApprovalExecutionOwners.shared
        guard owners.acquire(root: dataRoot, approvalID: rec.id) else {
            throw BrowserError.busy
        }
        var settlementOwnsRelease = false
        defer { if !settlementOwnsRelease { owners.release(root: dataRoot, approvalID: rec.id) } }
        if let retained = owners.settlement(root: dataRoot, approvalID: rec.id) {
            settlementOwnsRelease = true
            _ = try await settleApprovalExecution(rec.id, dataRoot: dataRoot, settlement: retained).get()
            if retained.action.objectValue?["error"] != nil { throw BrowserError.badRequest(retained.detail) }
            return
        }
        let settlement: ApprovalExecutionOwners.Settlement
        var executionFailure: (any Error)?
        do {
            let run: JSONValue
            let request = try BrowserActionRoutes.browserApprovalPayload(rec)
            let runsPath = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot).runsPath
            if let terminal = try await Self.terminalBrowserRun(runID: request.runID, runsPath: runsPath) {
                run = terminal
                await effects.observeBrowserMotorAction(runID: request.runID, dataRoot: dataRoot)
            } else if decision == "approved" {
                run = try await effects.executeApprovedBrowserRun(from: rec)
            } else {
                run = try await effects.finishRejectedBrowserRun(
                    from: rec, status: decision == "denied" ? "denied" : "canceled")
            }
            let status = try JSONRow(run).string("status")
            settlement = .init(action: run, detail: "Browser navigation \(status)")
        } catch let error as BrowserCompletionProjectionError {
            executionFailure = error
            let status = try JSONRow(error.run).string("status")
            settlement = .init(action: error.run,
                detail: "Browser navigation \(status); receipt projection unavailable: \(error.underlyingError.localizedDescription)")
        } catch {
            executionFailure = error
            settlement = .init(action: .object([
                "action": .string(rec.action), "status": .string("failed"),
                "error": .string(error.localizedDescription),
            ]), detail: "Browser navigation FAILED: \(error.localizedDescription)")
        }
        settlementOwnsRelease = true
        let saved = await settleApprovalExecution(rec.id, dataRoot: dataRoot, settlement: settlement)
        do { _ = try saved.get() }
        catch {
            throw NSError(domain: "NativeAgentBrowserApproval", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "\(settlement.detail). Approval annotation unavailable: \(error.localizedDescription). The execution outcome is retained for receipt-only repair."
            ])
        }
        if let executionFailure { throw executionFailure }
    }
    /// The persisted run for `runID` iff its status is terminal. A
    /// `waiting_approval` row (persisted at approval-creation time) is NOT
    /// terminal — the navigation never ran and a reconcile may execute it.
    public static func terminalBrowserRun(runID: String, runsPath: URL) async throws -> JSONValue? {
        try await SwiftNativeBrowserClient.terminalRun(id: runID, at: runsPath)
    }
    /// The resident drain and card resolution share approval ownership and settlement.
    func applyResolvedWorkshopStep(from rec: ApprovalRecord) async {
        guard ExecutionEventVocabulary.matches(rec.action, WorkshopStepApprovalAction.canonical),
              rec.status == "resolved", let decision = rec.decision else { return }
        await Self.performDomainApprovalExecution(rec, dataRoot: dataRoot) {
            guard case .object(let payload) = rec.payload,
                  case .string(let executionID)? = payload["execution_id"], !executionID.isEmpty,
                  case .string(let stepID)? = payload["step_id"], !stepID.isEmpty else {
                throw ApprovalInboxError.malformedResponse("Desk approval carries no execution_id/step_id")
            }
            let executor = try effects.workshopExecutor()
            switch decision {
            case "approved", "denied":
                do {
                    let record = try await executor.resumeAfterApproval(
                        executionId: executionID, stepId: stepID, approved: decision == "approved", approvalId: rec.id)
                    return WorkshopExecutorLoop.approvalOutcome(record, stepId: stepID, approved: decision == "approved")
                } catch WorkshopExecutionError.approvalDeferred { return nil }
                catch WorkshopExecutionError.staleApproval(let detail) {
                    return .init(action: .object(["op": .string("mission_step_stale"), "executionId": .string(executionID),
                        "stepId": .string(stepID)]), detail: "Desk step \(decision) — \(detail)")
                }
            case "canceled":
                await executor.clearStepApprovalClaim(executionId: executionID, stepId: stepID)
                return .init(action: .object(["op": .string("mission_step_cancel"), "executionId": .string(executionID),
                    "stepId": .string(stepID)]), detail: "Desk approval canceled — claim cleared; execution stays blocked")
            default: throw ApprovalInboxError.malformedResponse("invalid Desk approval decision: \(decision)")
            }
        }
    }
}
