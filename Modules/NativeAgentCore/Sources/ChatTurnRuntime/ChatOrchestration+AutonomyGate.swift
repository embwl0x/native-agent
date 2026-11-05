import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApprovalInbox
import MacControl

// Blueprint: | `ChatOrchestration+AutonomyGate.swift` | `AutonomyGate`: TrustCenter autonomy resolution and approval filing before concrete tool dispatch |

// MARK: - Autonomy auto-gating for tool dispatch
// Depend on the approval protocol so dispatch need not know which component owns durable requests and their resolution.
// MARK: - AutonomyGate

public actor AutonomyGate {
    private let filer: (any ApprovalFiler)?

    public init(approvalFiler: (any ApprovalFiler)? = nil) {
        self.filer = approvalFiler
    }

    /// Timeout denies without throwing; return the approval ID so injection capabilities name their authorizing decision.
    public func resolveWithApprovalDetailed(
        toolName: String,
        surface: String,
        requestPayload: JSONValue,
        timeoutSeconds: Double = 300,
        reason: String? = nil
    ,turn: Turn) async throws -> (decision: AutonomyDecision, approvalID: String?, notRunStatus: ToolNotRunStatus?) {
        guard timeoutSeconds.isFinite, timeoutSeconds >= 0,
              let nanos = UInt64(exactly: (timeoutSeconds * 1_000_000_000).rounded(.towardZero)) else {
            throw AutonomyGateError.invalidApprovalTimeout
        }
        guard let filer else {
            throw AutonomyGateError.noApprovalInboxWired
        }
        // Preserve the caller's safety reason; describe the action only when no specific reason is supplied.
        let resolvedReason = ApprovalActionText.reason(reason, tool: toolName)
        let id: String
        do {
            id = try await filer.fileApprovalRequest(
                toolName: toolName,
                surface: surface,
                payload: requestPayload,
                reason: resolvedReason
            ,turn: turn)
        } catch {
            if let gateError = error as? AutonomyGateError { throw gateError }
            throw AutonomyGateError.approvalFilingFailed(String(describing: error))
        }

        let outcome = await withTaskGroup(of: (AutonomyDecision, ToolNotRunStatus?)?.self) { group in
            group.addTask {
                do {
                    let decision = try await filer.awaitResolution(id: id)
                    switch decision {
                    case .approved: return (.allow, nil)
                    case .denied:   return (.deny(reason: "approval denied"), .personDenied)
                    case .canceled: return (.deny(reason: "approval canceled"), .approvalCanceled)
                    }
                } catch {
                    return (.deny(reason: "approval await failed: \(error)"), .approvalResolutionFailed)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            var result: (AutonomyDecision, ToolNotRunStatus?) = (.deny(reason: "approval timeout"), .approvalTimedOut)
            if let first = await group.next(), let decided = first {
                result = decided
            }
            group.cancelAll()
            return result
        }
        return (outcome.0, id, outcome.1)
    }

    // MARK: - level mapping

    package nonisolated static func map(level: String, toolName: String = "this action") -> AutonomyDecision {
        let allowed: Set<String> = ["auto", "app_data_autonomous", "workspace_autonomous"]
        let approval: Set<String> = ["supervised", "confirm", "send_approval", "destructive_strong"]
        let denied: Set<String> = ["deny", "blocked"]
        if allowed.contains(level) { return .allow }
        if approval.contains(level) { return .requireApproval(reason: ApprovalActionText.sentence(tool: toolName)) }
        if denied.contains(level) { return .deny(reason: "autonomy=\(level)") }
        return .requireApproval(reason: ApprovalActionText.sentence(tool: toolName))
    }
}
