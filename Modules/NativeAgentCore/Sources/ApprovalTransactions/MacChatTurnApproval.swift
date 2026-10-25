import Privacy
import Foundation
import ApprovalInbox
import ChatTurnRuntime
import NativeAgentShared
// Blueprint: | `MacChatTurnApproval.swift` | canonical turn approval projection, card visibility and inline authority state |

/// A turn's approval projected from the canonical inbox, with only proven
/// decisions represented as approved or denied.
public struct MacChatTurnCardApproval: Sendable, Equatable {
    /// What we can PROVE about the request. `approved` is reserved for a row
    /// that says so in its own decision field; everything unreadable,
    /// half-written, or resolved-without-a-decision lands in `unresolved`.
    public enum Outcome: Sendable, Equatable {
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

    public let approvalId: String
    /// The action the inbox record names (its `action` field, e.g. the tool).
    public let toolName: String
    public let reason: String?
    /// The row's redacted payload preview, bounded to one line.
    public var inputSummary: String? = nil
    /// WHO asked, when the asker was not the person — a peer on the agent
    /// bridge, named as the person named it in Trust → Connected agents.
    /// Nil for the person's own approvals, which is every ordinary turn.
    public var requester: String? = nil
    public let outcome: Outcome

    /// Only a pending request can be decided from here.
    public var isActionable: Bool { outcome == .pending }
}

public enum MacChatTurnApprovalProjection {
    /// An exact-turn approval carries this session and was requested no earlier
    /// than the turn opened. Deduplicated rows use lastRequestedAt, since their
    /// creation can belong to an earlier turn. Unreadable provenance fails closed.
    /// Pending wins, then newest request, then id for deterministic selection.
    public static func approval(
        sessionId: String,
        turnStartedAt: Date,
        approvals: [ApprovalRecord],
        requester: (String) -> String?,
        parseTimestamp: (String) -> Date?
    ) -> MacChatTurnCardApproval? {
        guard !sessionId.isEmpty else { return nil }

        let candidates: [(row: ApprovalRecord, requestedAt: Date)] = approvals.compactMap { row in
            guard row.chatOriginSessionId == sessionId,
                  let timestamp = nonEmpty(row.lastRequestedAt ?? row.createdAt),
                  let requestedAt = parseTimestamp(timestamp),
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
            reason: nonEmpty(chosen.candidate.row.reason).map {
                ToolActivityPresentation.approvalText(
                    ApprovalActionText.reason($0, tool: chosen.candidate.row.action),
                    tool: chosen.candidate.row.action
                )
            },
            inputSummary: inputSummary(chosen.candidate.row),
            requester: requester(chosen.candidate.row.title),
            outcome: chosen.outcome
        )
    }

    /// Longest input line the card will show before eliding.
    private static let inputSummaryLimit = 120

    /// Fields worth naming first: they are the ones that decide whether a
    /// person says yes. Order is the display preference, not an allowlist.
    private static let preferredInputKeys = [
        "path", "file_path", "filepath", "paths", "directory", "dir",
        "to", "recipient", "recipients", "chat_id", "channel",
        "command", "cmd", "script", "url", "endpoint",
        "query", "pattern", "name", "title", "text", "message", "body",
    ]

    /// One short line describing the input, from the inbox row's own preview.
    ///
    /// The inbox stores a caller-written preview when there is one and the
    /// serialized payload otherwise (`ApprovalInbox.stageApproval`), so this
    /// reads an object when it can and falls back to the raw string.
    private static func inputSummary(_ row: ApprovalRecord) -> String? {
        guard let raw = nonEmpty(row.payloadPreview) else { return nil }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let parsed = object as? [String: Any]
        else {
            return redactedLine(raw)
        }
        // The filer's envelope is not the tool input. Unwrap it before key
        // selection, then redact every value again before displaying it.
        let fields = (chatApprovalInput(parsed) ?? parsed)
            .filter { !ApprovalActionText.isInternalField($0.key) }
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
              let input = fields["input"] as? [String: Any]
        else { return nil }
        return input
    }

    /// Keys whose VALUE is never shown: one list with the phone and Telegram copies.
    private static func isSecretKey(_ key: String) -> Bool {
        NativeAppSecretRedactor.isSecretArgName(key)
    }

    private static func scalarText(_ value: Any) -> String? {
        switch value {
        case let text as String: return nonEmpty(text)
        case let number as NSNumber: return number.stringValue
        case let nested as [String: Any]:
            // Nested values may contain credentials; show only safe key names.
            return nonEmpty(nested.keys.filter {
                !ApprovalActionText.isInternalField($0) && !isSecretKey($0)
            }.sorted().joined(separator: ", "))
                .map { "{\($0)}" }
        default: return nil
        }
    }

    /// Redact by value before bounding, so a truncated secret cannot survive.
    /// Flatten whitespace and omit control characters, including bidi overrides.
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
    private static func outcome(for row: ApprovalRecord) -> MacChatTurnCardApproval.Outcome {
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

    private static func displayAction(_ row: ApprovalRecord) -> String {
        nonEmpty(row.action).map(ToolActivityPresentation.title) ?? nonEmpty(row.title) ?? "this action"
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension MacChatTurnCardApproval {
    /// Outcomes worth keeping chrome on screen after the turn itself settles.
    /// A proven decision is finished business and lives on in Activity →
    /// Approvals; an unproven one is exactly the thing that must be said out
    /// loud, the same rule `.outcomeUnknown` earns its card by.
    public var keepsCardVisible: Bool {
        switch outcome {
        case .pending, .expired, .unresolved: return true
        case .approved, .denied: return false
        }
    }

}

/// The inline approval card is a safety control, so it has an explicit state
/// for missing authority rather than presenting disabled actions as though the
/// card were merely busy. This also keeps an absent/stale approvals refresh
/// from turning a still-pending request into a resolved-looking card.
public enum InlineApprovalPresentation {
    public enum State: Equatable, Sendable {
        case unavailable
        case pending
        case resolved(decision: String)
    }

    public static func state(
        approvalID: String,
        externalStatus: String?,
        externalDecision: String?
    ) -> State {
        guard !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        let status = externalStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let status, !status.isEmpty, status != "pending" else {
            return .pending
        }
        return .resolved(decision: externalDecision?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }
}
