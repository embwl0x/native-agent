import Foundation
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
// Blueprint: | `ChatApprovalContracts.swift` | `AutonomyDecision` enum |

// MARK: - AutonomyDecision

public enum AutonomyDecision: Sendable, Equatable {
    case allow
    case requireApproval(reason: String)
    case deny(reason: String)
}

// MARK: - Errors

/// Reporting only: these outcomes never grant permission or change admission.
public enum ToolNotRunStatus: String, Sendable, Equatable {
    case approvalFiled = "approval_filed"
    case approvalUnavailable = "approval_unavailable"
    case personDenied = "person_denied"
    case blocked
    case approvalCanceled = "approval_canceled"
    case approvalTimedOut = "approval_timed_out"
    case approvalFilingFailed = "approval_filing_failed"
    case approvalResolutionFailed = "approval_resolution_failed"
    case approvalDeliveryFailed = "approval_delivery_failed"

    public func sentence(location: String = "Mac chat or on your phone") -> String {
        switch self {
        case .approvalFiled: return "I haven’t run this; I filed an approval card you can use now in \(location)."
        case .approvalUnavailable: return "I haven’t run this or filed an approval card because I can’t request approval here; ask me in Mac chat, on your phone, or in Telegram instead."
        case .personDenied: return "I didn’t run this because you declined the approval request."
        case .blocked: return "I can’t run this because an access rule blocks it, and an approval cannot override that rule."
        case .approvalCanceled: return "I didn’t run this because the approval request was canceled."
        case .approvalTimedOut: return "I didn’t run this because the wait for approval ended without a decision."
        case .approvalFilingFailed: return "I didn’t run this because I couldn’t save an approval request."
        case .approvalResolutionFailed: return "I didn’t run this because I couldn’t confirm the approval decision."
        case .approvalDeliveryFailed: return "I haven’t run this; I saved an approval card in Mac chat or on your phone, but couldn’t send it to Telegram."
        }
    }

    public func reporting(_ value: JSONValue, location: String = "Mac chat or on your phone", tool: String? = nil) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        fields["not_run_status"] = .string(rawValue)
        // Every result says where it stands; a held call is waiting, never blank.
        if fields["status"] == nil {
            fields["status"] = .string([.approvalFiled, .approvalDeliveryFailed].contains(self) ? "waiting_approval" : "not_run")
        }
        if self == .blocked {
            func text(_ key: String) -> String? {
                if case .string(let value)? = fields[key] { return value }
                return nil
            }
            var named = tool
            if named == nil { named = text("tool") }
            fields["detail"] = .string(Self.blockedSentence(
                reason: text("gate_reason") ?? text("detail") ?? text("message"), tool: named))
        } else {
            fields["detail"] = .string(sentence(location: location))
        }
        // Queue steps wait for the card's decision before the follow-up returns them to her.
        if self == .approvalFiled, case .string(let id)? = fields["approvalId"] {
            fields["then"] = .string("app {action:\"queue.add\", args:{text:\"…\", when:\"after_card \(id)\"}} "
                + "keeps the step you will take once it is decided")
        }
        return .object(fields)
    }

    /// Denials state their reason; policy blocks name the tool and its Settings rule.
    public static func blockedSentence(reason: String?, tool: String? = nil) -> String {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reason.isEmpty { return ToolNotRunStatus.blocked.sentence() }
        if reason.hasPrefix("autonomy=") || reason.hasPrefix("fileAccess=") {
            return "I can’t run \(tool ?? "this") — a rule in Settings blocks it."
        }
        return "Not run: \(reason)"
    }
}

public enum AutonomyGateError: Error, LocalizedError, Equatable {
    case toolDenied(reason: String, remedy: JSONValue? = nil)
    case notRun(ToolNotRunStatus)
    case noApprovalInboxWired
    case approvalFilingFailed(String)
    case invalidApprovalTimeout

    public var notRunStatus: ToolNotRunStatus {
        switch self {
        case .toolDenied: return .blocked
        case .notRun(let status): return status
        case .noApprovalInboxWired: return .approvalUnavailable
        case .approvalFilingFailed: return .approvalFilingFailed
        case .invalidApprovalTimeout: return .approvalUnavailable
        }
    }

    public var errorDescription: String? {
        if case .invalidApprovalTimeout = self { return "Approval timeout must be finite, nonnegative and representable in nanoseconds; no request was filed." }
        if case .toolDenied(let reason, _) = self { return ToolNotRunStatus.blockedSentence(reason: reason) }
        return notRunStatus.sentence()
    }
}

// MARK: - ApprovalFiler

/// Narrow protocol for staging an approval request and awaiting the user's
/// decision. The canonical approval actor owns durable records and decisions.
public protocol ApprovalFiler: Sendable {
    /// Stage an approval request. Returns the new record's id.
    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String

    /// Read resolution for the given approval id when the filer supports waiting.
    func awaitResolution(id: String) async throws -> ApprovalDecision
}

/// Optional extension point for surfaces that cannot safely block their
/// transport loop while waiting for a human decision. The filer still stages a
/// durable approval request, but the dispatcher returns this tool result
/// immediately instead of awaiting resolution in the current turn.
public protocol NonBlockingApprovalFiler: ApprovalFiler {
    func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async -> JSONValue
}

public extension NonBlockingApprovalFiler {
    func awaitResolution(id: String) async throws -> ApprovalDecision {
        throw NSError(domain: "NativeAgentChatApprovalFiler", code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "This approval filer is nonblocking; resolved approvals execute through the canonical inbox."])
    }
}
