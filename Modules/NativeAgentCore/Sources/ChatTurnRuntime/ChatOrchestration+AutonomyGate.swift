import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApprovalInbox
import MacControl

// MARK: - Autonomy auto-gating for tool dispatch
//
// AutonomyGate sits between SwiftNativeTurnEngine's tool dispatch path and
// the concrete ToolDispatchClient. For each tool call:
//   1. Resolve the autonomy level via TrustCenter.
//   2. Map level → allow / requireApproval / deny.
//   3. If requireApproval and an ApprovalFiler is wired, file a request
//      and await the user's decision (with timeout).
//
// CARVES:
//   * This gate depends on a narrow ApprovalFiler protocol so dispatch code
//     does not need to know which app/core component staged the durable
//     approval record. NativeAgent.app wires the real Swift approval queue and
//     follow-up executor; tests use mocks.
//   * AutonomyResolver protocol lets tests substitute a mock for
//     SwiftNativeTrustCenter; the concrete actor conforms via an extension.

// MARK: - AutonomyResolver

public typealias AutonomyResolver = ChatTurnContracts.AutonomyResolver

/// The law's answer by name; the input-aware answer is SecurityCenter's.
extension SwiftNativeTrustCenter: AutonomyResolver {}

// MARK: - AutonomyGate

public actor AutonomyGate {
    private let filer: (any ApprovalFiler)?

    public init(approvalFiler: (any ApprovalFiler)? = nil) {
        self.filer = approvalFiler
    }

    /// File an approval request and await its resolution. Returns the final
    /// decision (allow on approved, deny on denied/canceled). On timeout,
    /// returns .deny (NOT throws). Also returns the approval record ID.
    ///
    /// W2/W3-FIX 1/2 need it: a `MacInjectionCapability` is minted from a
    /// specific resolved approval, and "which approval authorized this
    /// keystroke" has to be answerable from the capability itself, not inferred.
    public func resolveWithApprovalDetailed(
        toolName: String,
        surface: String,
        requestPayload: JSONValue,
        timeoutSeconds: Double = 300,
        reason: String? = nil
    ) async throws -> (decision: AutonomyDecision, approvalID: String?, notRunStatus: ToolNotRunStatus?) {
        guard let filer else {
            throw AutonomyGateError.noApprovalInboxWired
        }
        // Carry the caller's specific safety reason; only the permission-level
        // fallback needs a plain description of the action.
        // 2026-07-21 gpt-5.5 review: carry the CALLER's reason (a security
        // .ask's injection-shield reason, a PersonaWriteGuard reason) into
        // the filed record — composing "autonomy=\(level)" here erased it.
        let resolvedReason = ApprovalActionText.reason(reason, tool: toolName)
        let id: String
        do {
            id = try await filer.fileApprovalRequest(
                toolName: toolName,
                surface: surface,
                payload: requestPayload,
                reason: resolvedReason
            )
        } catch {
            if let gateError = error as? AutonomyGateError { throw gateError }
            throw AutonomyGateError.approvalFilingFailed(String(describing: error))
        }

        let nanos = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
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
                return nil  // timeout sentinel
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
