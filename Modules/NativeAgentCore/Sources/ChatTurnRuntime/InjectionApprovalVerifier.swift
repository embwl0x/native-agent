import Foundation
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import MacControl
// Blueprint: | `InjectionApprovalVerifier.swift` | `ApprovalInboxInjectionApprovalVerifier` struct; `verifyInjectionApproval` |

public enum InjectionApprovalVerification: String, Sendable, Equatable {
    case verified
    case recordNotFound = "approval_record_not_found"
    case notApproved = "approval_not_resolved_approved"
    case toolMismatch = "approval_is_for_a_different_tool"
    case surfaceMismatch = "approval_is_for_a_different_surface"
    case bodyMismatch = "approval_is_for_a_different_body"
    case alreadyConsumed = "approval_already_consumed"
    case malformedRecord = "approval_record_malformed"
    /// Refuse if single-use spend cannot persist, or restart could replay the same injection.
    case spendUnavailable = "approval_spend_unrecordable"
}

/// Verify exact canonical approval, tool, body and recorded surface before permanently spending it.
/// Spend precedes verification success and survives execution failure across tasks, processes and restarts.
public struct ApprovalInboxInjectionApprovalVerifier: Sendable {
    private let inbox: SwiftNativeApprovalInbox

    public init(dataRoot: URL) {
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
    }

    public init(inbox: SwiftNativeApprovalInbox) {
        self.inbox = inbox
    }

    public func verifyInjectionApproval(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue],
        turn: Turn
    ) async throws -> InjectionApprovalVerification {
        let id = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .recordNotFound }
        let record: ApprovalRecord
        do { record = try await inbox.get(id) }
        catch ApprovalInboxError.notFound { return .recordNotFound }

        guard record.status.lowercased() == "resolved",
              record.decision?.lowercased() == "approved" else {
            return .notApproved
        }
        // An executed record is already spent, independently of the spend marker.
        if let executed = record.executedAction, executed != .null {
            return .alreadyConsumed
        }
        guard case .object(let payload) = record.payload else { return .malformedRecord }

        let recordTool = Self.string(payload["toolName"])
            ?? Self.string(payload["tool"])
            ?? record.action
        guard Self.normalized(recordTool) == Self.normalized(tool) else { return .toolMismatch }

        // Check recorded surface when present; its absence never bypasses the exact tool and body checks.
        if let recordSurface = Self.string(payload["surface"]),
           Self.normalized(recordSurface) != Self.normalized(surface) {
            return .surfaceMismatch
        }

        guard case .object(let recordInput)? = payload["input"] else { return .malformedRecord }
        guard let approvedDigest = MacInjectionApprovalDigest.digest(tool: tool, input: recordInput, turn: turn),
              let callDigest = MacInjectionApprovalDigest.digest(tool: tool, input: input, turn: turn) else {
            return .malformedRecord
        }
        guard approvedDigest == callDigest else { return .bodyMismatch }

        switch await inbox.consumeInjectionApproval(
            id: id,
            digest: callDigest,
            tool: tool,
            surface: surface
        ) {
        case .spent:
            break
        case .alreadySpent:
            return .alreadyConsumed
        case .unavailable:
            return .spendUnavailable
        }

        return .verified
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
