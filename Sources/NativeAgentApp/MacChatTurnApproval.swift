import Foundation
import NativeAgentShared

/// Desk 658.12 — the approval a turn is waiting on, projected into the card.
///
/// The canonical approval lives in the ApprovalInbox and nowhere else. This
/// file adds no store, no state machine, and no authority: it is a pure
/// function from the inbox rows the app already refreshes onto a display
/// value, plus the honesty rules for reading a row's outcome.
///
/// TrustCenter, the autonomy gates, and `NativeClient+ApprovalExecutors`
/// are untouched — the card renders a decision and dispatches it through the
/// same `resolveApproval` call every other surface uses.
struct MacChatTurnCardApproval: Sendable, Equatable {
    /// What we can PROVE about the request. `approved` is reserved for a row
    /// that says so in its own decision field; everything unreadable,
    /// half-written, or resolved-without-a-decision lands in `unresolved`.
    enum Outcome: Sendable, Equatable {
        /// Waiting for a person. The tool has not run.
        case pending
        /// A human decision is recorded: approved.
        case approved
        /// A human decision is recorded: denied.
        case denied
        /// Withdrawn or timed out before anyone decided.
        case expired
        /// Settled in some way we cannot read as a decision. Never rendered as
        /// success.
        case unresolved
    }

    let approvalId: String
    /// The action the inbox record names (its `action` field, e.g. the tool).
    let toolName: String
    let reason: String?
    let outcome: Outcome

    /// Only a pending request can be decided from here.
    var isActionable: Bool { outcome == .pending }

    /// Outcomes worth keeping chrome on screen after the turn itself settles.
    /// A proven decision is finished business and lives on in Activity →
    /// Approvals; an unproven one is exactly the thing that must be said out
    /// loud, the same rule `.outcomeUnknown` earns its card by.
    var keepsCardVisible: Bool {
        switch outcome {
        case .pending, .expired, .unresolved: return true
        case .approved, .denied: return false
        }
    }

    /// Short badge for a card whose title belongs to the turn.
    var badge: String {
        switch outcome {
        case .pending: return "Needs approval"
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .expired: return "Approval expired"
        case .unresolved: return "Approval unresolved"
        }
    }
}

enum MacChatTurnApprovalProjection {
    /// Selects the one approval this exact turn is responsible for.
    ///
    /// Two fences, both evidence-based:
    ///
    /// 1. **Session.** The row must carry this conversation's origin session.
    ///    An approval with no chat origin (a workshop step, a memory proposal)
    ///    is not a chat approval and never enters a chat card.
    /// 2. **Generation.** The row must have been created no earlier than this
    ///    turn opened. A previous turn's still-pending approval belongs to the
    ///    turn that asked for it, not to whatever replaced it; it stays in the
    ///    approvals surface rather than following the user into a new turn.
    ///    A row whose `createdAt` cannot be read fails this fence closed —
    ///    unprovable provenance is not provenance.
    ///
    /// Pending wins over settled (an undecided request is the live question),
    /// then newest, then id for a deterministic result.
    static func approval(
        sessionId: String,
        turnStartedAt: Date,
        approvals: [ApprovalRequest]
    ) -> MacChatTurnCardApproval? {
        guard !sessionId.isEmpty else { return nil }

        let candidates: [(row: ApprovalRequest, createdAt: Date)] = approvals.compactMap { row in
            guard row.chatOriginSessionId == sessionId,
                  let createdAt = parseTimestamp(row.createdAt),
                  createdAt >= turnStartedAt else { return nil }
            return (row, createdAt)
        }
        guard !candidates.isEmpty else { return nil }

        let chosen = candidates
            .map { (candidate: $0, outcome: outcome(for: $0.row)) }
            .sorted { lhs, rhs in
                let lhsPending = lhs.outcome == .pending
                let rhsPending = rhs.outcome == .pending
                if lhsPending != rhsPending { return lhsPending }
                if lhs.candidate.createdAt != rhs.candidate.createdAt {
                    return lhs.candidate.createdAt > rhs.candidate.createdAt
                }
                return lhs.candidate.row.id < rhs.candidate.row.id
            }
            .first

        guard let chosen else { return nil }
        return MacChatTurnCardApproval(
            approvalId: chosen.candidate.row.id,
            toolName: displayAction(chosen.candidate.row),
            reason: nonEmpty(chosen.candidate.row.reason),
            outcome: chosen.outcome
        )
    }

    /// Reads a row's outcome. The default arm is `.unresolved` on purpose: a
    /// status this projection does not understand must never be rendered as a
    /// decision that was never made.
    static func outcome(for row: ApprovalRequest) -> MacChatTurnCardApproval.Outcome {
        let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let decision = row.decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch decision {
        case "approved":
            return .approved
        case "denied", "rejected":
            return .denied
        case "canceled", "cancelled", "expired":
            return .expired
        default:
            break
        }
        switch status {
        case "pending":
            // Pending is only pending while nothing has been decided; a row
            // carrying an unreadable decision already left the waiting state.
            return decision == nil ? .pending : .unresolved
        case "canceled", "cancelled", "expired", "withdrawn":
            return .expired
        default:
            // "resolved" with no readable decision, "orphaned", or anything
            // this build has never seen.
            return .unresolved
        }
    }

    private static func displayAction(_ row: ApprovalRequest) -> String {
        nonEmpty(row.action) ?? nonEmpty(row.title) ?? "this action"
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Inbox timestamps are ISO-8601 with fractional seconds and a `+00:00`
    /// offset; older rows may carry neither.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw = nonEmpty(raw) else { return nil }
        // Built per call rather than cached: ISO8601DateFormatter is not
        // Sendable, and this runs over a short list at most once a second.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
