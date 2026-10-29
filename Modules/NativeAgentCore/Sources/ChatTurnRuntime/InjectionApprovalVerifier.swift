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
    /// The DURABLE spend marker could not be recorded (unreadable or corrupt
    /// marker store, failed write). Fail-closed: an injection whose spend
    /// cannot be persisted is an injection nothing would stop replaying after
    /// a restart, so it does not run.
    case spendUnavailable = "approval_spend_unrecordable"
}

/// Requires a resolved-approved canonical inbox record matching the tool,
/// body digest and any recorded surface, with no completed execution evidence.
/// The inbox's durable spend enforces single use across tasks, processes and restarts.
/// Spend precedes `.verified` and remains permanent even when execution fails.
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
        input: [String: JSONValue]
    ) async -> InjectionApprovalVerification {
        let id = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .recordNotFound }
        guard let record = try? await inbox.get(id) else { return .recordNotFound }

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

        // Surface is checked when the record carries one. A record that predates
        // the field (or a non-chat filer that omits it) is not silently trusted
        // for the tool/body checks below — those still run.
        if let recordSurface = Self.string(payload["surface"]),
           Self.normalized(recordSurface) != Self.normalized(surface) {
            return .surfaceMismatch
        }

        guard case .object(let recordInput)? = payload["input"] else { return .malformedRecord }
        guard let approvedDigest = MacInjectionApprovalDigest.digest(tool: tool, input: recordInput),
              let callDigest = MacInjectionApprovalDigest.digest(tool: tool, input: input) else {
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
