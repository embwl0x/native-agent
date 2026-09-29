import Foundation
import PersistenceCore

/// Wire vocabulary for tool receipts that have a special transcript
/// presentation. The writer classifies a non-blocking approval result here;
/// app surfaces consume these exact values rather than independently guessing
/// from a result-summary string.
public enum ChatTranscriptToolMessageKind {
    public static let toolUse = "tool_use"
    public static let approvalPending = "approval_pending"

    /// Returns an approval identifier only for the canonical result emitted by
    /// `NonBlockingApprovalFiler`. A malformed result, a differently named
    /// status, or an empty identifier remains an ordinary tool receipt: it
    /// must not surface an actionable approval card without an authority.
    public static func pendingApprovalID(in resultSummary: String) -> String? {
        guard let value = try? JSONValue.parse(Data(resultSummary.utf8)) else { return nil }
        return pendingApprovalID(in: value)
    }

    /// WHAT THE PERSON IS BEING ASKED, in the asking tool's own words. The
    /// inline approval card reads the row's `content` — first line as its
    /// title, the rest as its detail — and this row's content was always empty,
    /// so every card in chat read "… needs a decision" and said nothing about
    /// what for. The filed reason is the one text that knows.
    package static func pendingApprovalReason(in value: JSONValue) -> String? {
        guard case .object(let object) = value,
              case .string("waiting_approval")? = object["status"],
              case .string(let reason)? = object["reason"] else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2000))
    }

    package static func pendingApprovalID(in value: JSONValue) -> String? {
        guard case .object(let object) = value,
              case .string("waiting_approval")? = object["status"],
              case .string(let rawID)? = object["approvalId"] ?? object["approval_id"]
        else { return nil }

        let approvalID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return approvalID.isEmpty ? nil : approvalID
    }
}
