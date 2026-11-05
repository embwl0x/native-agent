import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import Browser
// Blueprint: | `BrowserApprovalExecution.swift` | Retain returned browser outcomes until receipted. |

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
                NSLocalizedDescriptionKey: """
                    \(settlement.detail). Approval annotation unavailable: \(error.localizedDescription). The execution outcome is retained for \
                    receipt-only repair.
                    """
            ])
        }
        if let executionFailure { throw executionFailure }
    }
    /// Waiting approval does not prove navigation ran; only terminal runs can repair a receipt without execution.
    public static func terminalBrowserRun(runID: String, runsPath: URL) async throws -> JSONValue? {
        try await SwiftNativeBrowserClient.terminalRun(id: runID, at: runsPath)
    }
}
