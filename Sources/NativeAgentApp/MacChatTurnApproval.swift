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
    /// 2026-09-06: what the tool would actually DO — one short line drawn from
    /// the inbox row's own payload preview (a path, a recipient, the head of a
    /// command). Without it the card asked for a decision while showing only
    /// the tool's name and a reason that is often just "autonomy=<level>", so
    /// there was nothing on screen to decide FROM. Nil when the row carries no
    /// readable preview.
    /// Defaulted so the memberwise init stays source-compatible with callers
    /// that only ever named the four canonical fields.
    var inputSummary: String? = nil
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
    /// 2. **Generation.** The row must have been ASKED FOR no earlier than this
    ///    turn opened. A previous turn's still-pending approval belongs to the
    ///    turn that asked for it, not to whatever replaced it; it stays in the
    ///    approvals surface rather than following the user into a new turn.
    ///    A row whose stamp cannot be read fails this fence closed —
    ///    unprovable provenance is not provenance.
    ///
    ///    User, 2026-09-06: "asked for" is `lastRequestedAt` when the row has
    ///    one, and `createdAt` otherwise. An identical request re-raised in a
    ///    later turn REUSES the pending row (the filer's dedup), so its
    ///    `createdAt` belongs to the first turn — fencing on that alone hid the
    ///    very question this turn was waiting on.
    ///
    /// Pending wins over settled (an undecided request is the live question),
    /// then newest, then id for a deterministic result.
    static func approval(
        sessionId: String,
        turnStartedAt: Date,
        approvals: [ApprovalRequest]
    ) -> MacChatTurnCardApproval? {
        guard !sessionId.isEmpty else { return nil }

        let candidates: [(row: ApprovalRequest, requestedAt: Date)] = approvals.compactMap { row in
            guard row.chatOriginSessionId == sessionId,
                  let requestedAt = parseTimestamp(row.lastRequestedAt ?? row.createdAt),
                  requestedAt >= turnStartedAt else { return nil }
            return (row, requestedAt)
        }
        guard !candidates.isEmpty else { return nil }

        let chosen = candidates
            .map { (candidate: $0, outcome: outcome(for: $0.row)) }
            .sorted { lhs, rhs in
                let lhsPending = lhs.outcome == .pending
                let rhsPending = rhs.outcome == .pending
                if lhsPending != rhsPending { return lhsPending }
                if lhs.candidate.requestedAt != rhs.candidate.requestedAt {
                    return lhs.candidate.requestedAt > rhs.candidate.requestedAt
                }
                return lhs.candidate.row.id < rhs.candidate.row.id
            }
            .first

        guard let chosen else { return nil }
        return MacChatTurnCardApproval(
            approvalId: chosen.candidate.row.id,
            toolName: displayAction(chosen.candidate.row),
            reason: nonEmpty(chosen.candidate.row.reason),
            inputSummary: inputSummary(chosen.candidate.row),
            outcome: chosen.outcome
        )
    }

    /// Longest input line the card will show before eliding.
    static let inputSummaryLimit = 120

    /// Fields worth naming first: they are the ones that decide whether a
    /// person says yes. Order is the display preference, not an allowlist.
    private static let preferredInputKeys = [
        "path", "file_path", "filepath", "paths", "directory", "dir",
        "to", "recipient", "recipients", "chat_id", "channel",
        "command", "cmd", "script", "url", "endpoint",
        "query", "pattern", "name", "title", "text", "message", "body",
    ]

    /// Keys whose VALUE is never shown. A preview is for deciding, not for
    /// spilling a credential onto a card that sits in scrollback.
    private static let secretKeyMarkers = [
        "token", "secret", "password", "passwd", "api_key", "apikey",
        "authorization", "auth", "credential", "private_key", "cookie",
    ]

    /// One short line describing the input, from the inbox row's own preview.
    ///
    /// The inbox stores a caller-written preview when there is one and the
    /// serialized payload otherwise (`ApprovalInbox.stageApproval`), so this
    /// reads an object when it can and falls back to the raw string.
    static func inputSummary(_ row: ApprovalRequest) -> String? {
        guard let raw = nonEmpty(row.payloadPreview) else { return nil }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let parsed = object as? [String: Any]
        else {
            return redactedLine(raw)
        }
        // 2026-09-06: a chat approval's preview is the filer's ENVELOPE
        // ({kind, toolName, surface, input, origin}), not the tool's
        // arguments. Every key below then missed, the alphabetical fallback
        // picked `input`, and a nested object shows key NAMES only — so the
        // card said "input: {command, cwd}" where the person needed to see
        // the command. Unwrap the one envelope this app writes; its `input`
        // was already redacted by the filer and still goes through the value
        // redaction below.
        let fields = chatApprovalInput(parsed) ?? parsed
        let ordered = preferredInputKeys.compactMap { key -> (String, Any)? in
            guard let match = fields.first(where: {
                $0.key.lowercased() == key && !isSecretKey($0.key)
            }) else { return nil }
            return (match.key, match.value)
        }
        let fallback = fields
            .filter { !isSecretKey($0.key) }
            .sorted { $0.key < $1.key }
        for (key, value) in ordered + fallback {
            guard let scalar = scalarText(value) else { continue }
            return redactedLine("\(key): \(scalar)")
        }
        return nil
    }

    /// The tool arguments inside `NativeAgentChatApprovalFiler`'s payload, or
    /// nil when this preview is not one of those payloads.
    private static func chatApprovalInput(_ fields: [String: Any]) -> [String: Any]? {
        guard fields["kind"] as? String == "chat_tool_approval",
              let input = fields["input"] as? [String: Any],
              !input.isEmpty
        else { return nil }
        return input
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return secretKeyMarkers.contains { lowered.contains($0) }
    }

    private static func scalarText(_ value: Any) -> String? {
        switch value {
        case let text as String: return nonEmpty(text)
        case let number as NSNumber: return number.stringValue
        case let nested as [String: Any]:
            // 2026-09-06: a nested object's VALUES never reach the card. A
            // credential one level down (`value`, `header`, `body`) was shown
            // verbatim because only TOP-LEVEL keys were screened; naming the
            // keys says as much as a person needs to decide.
            return nonEmpty(nested.keys.sorted().joined(separator: ", "))
                .map { "{\($0)}" }
        default: return nil
        }
    }

    /// One line, no control characters (bidi overrides included), bounded.
    ///
    /// 2026-09-06: redaction is by VALUE as well as by key. A key filter
    /// cannot see a token inside an ordinary field, and the raw fallback
    /// (a root array, or a preview that is not JSON at all) never passed a
    /// key filter in the first place. Everything on its way to the card goes
    /// through the app's redactor first — before the bound, so a truncated
    /// secret cannot survive the cut.
    private static func redactedLine(_ line: String) -> String? {
        let raw = NativeAppSecretRedactor.redactText(line)
        var flattened = ""
        flattened.reserveCapacity(min(raw.utf8.count, inputSummaryLimit * 4))
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            let isSpace = scalar == " " || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSpace {
                if !lastWasSpace, !flattened.isEmpty { flattened.append(" ") }
                lastWasSpace = true
                continue
            }
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            lastWasSpace = false
            flattened.unicodeScalars.append(scalar)
            if flattened.count > inputSummaryLimit { break }
        }
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > inputSummaryLimit else { return trimmed }
        return String(trimmed.prefix(inputSummaryLimit)) + "\u{2026}"
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
        return UserDisplayFormatters.parseFoundationISOTimestamp(raw)
    }
}
