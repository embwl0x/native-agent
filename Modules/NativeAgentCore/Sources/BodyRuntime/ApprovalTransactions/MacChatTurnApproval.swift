import PersistenceCore
import Foundation
import MacNerves
import NativeAgentShared
// Blueprint: | `MacChatTurnApproval.swift` | canonical turn approval projection, card visibility and inline authority state |

public enum TurnApprovalRead {
    /// An exact-turn approval carries this session and was requested no earlier than the turn opened. Deduplicated rows use lastRequestedAt, since their
    /// creation can belong to an earlier turn. Unreadable provenance fails closed. Pending wins, then newest request, then id for deterministic selection.
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
                  let timestamp = (row.lastRequestedAt ?? row.createdAt).trimmedNonEmpty,
                  let requestedAt = parseTimestamp(timestamp),
                  requestedAt >= turnStartedAt else { return nil }
            return (row, requestedAt)
        }
        guard !candidates.isEmpty else { return nil }

        let chosen = candidates
            // A card the person's own words decided ran its call on their word: it reads as theirs, never as expired.
            .map { (candidate: $0, outcome: $0.row.decidedByPersonsWord ? ApprovalRequest.Outcome.approved
                : ApprovalRequest.Outcome(status: $0.row.status, decision: $0.row.decision)) }
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
            act: displayAction(chosen.candidate.row),
            reason: chosen.candidate.row.reason.trimmedNonEmpty.map {
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

    private static let inputSummaryLimit = 120

    /// Fields worth naming first: they are the ones that decide whether a person says yes. Order is the display preference, not an allowlist.
    private static let preferredInputKeys = [
        "path", "file_path", "filepath", "paths", "directory", "dir",
        "to", "recipient", "recipients", "chat_id", "channel",
        "command", "cmd", "script", "url", "endpoint",
        "query", "pattern", "name", "title", "text", "message", "body",
    ]

    /// The inbox preview is caller-authored prose or serialized payload; only structured payloads can be unwrapped.
    private static func inputSummary(_ row: ApprovalRecord) -> String? {
        guard let raw = row.payloadPreview.trimmedNonEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let parsed = object as? [String: Any]
        else {
            return redactedLine(raw)
        }
        // The filer's envelope is not the tool input. Unwrap it before key selection, then redact every value again before displaying it.
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
            // The value alone says what is asked; only a nested object needs its name, in words.
            return redactedLine(value is [String: Any] ? "\(key.replacingOccurrences(of: "_", with: " ")): \(scalar)" : scalar)
        }
        return nil
    }

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
        case let text as String: return text.trimmedNonEmpty
        case let number as NSNumber: return number.stringValue
        case let nested as [String: Any]:
            // Nested values may contain credentials; show only safe key names.
            return (nested.keys.filter {
                !ApprovalActionText.isInternalField($0) && !isSecretKey($0)
            }.sorted().joined(separator: ", ")).trimmedNonEmpty
                .map { "{\($0)}" }
        default: return nil
        }
    }

    /// Redact by value before bounding, so a truncated secret cannot survive. Flatten whitespace and omit control characters, including bidi overrides.
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

    private static func displayAction(_ row: ApprovalRecord) -> String {
        row.call?.act ?? row.action.trimmedNonEmpty.map(ToolActivityPresentation.title) ?? row.title.trimmedNonEmpty ?? "this action"
    }
}
