import Foundation
import PersistenceCore
import ChatToolParsing
// Blueprint: | `ChatTranscriptToolMessageKind.swift` | `ChatTranscriptToolMessageKind` enum; `pendingApprovalID`, `pendingApprovalReason` |

/// Share the writer's exact receipt vocabulary so surfaces cannot infer approval cards from prose.
public enum ChatTranscriptToolMessageKind {
    public static let toolUse = "tool_use"
    public static let approvalPending = "approval_pending"

    /// Only a canonical approval result with a nonempty identifier can establish an actionable card.
    public static func pendingApprovalID(in resultSummary: String) -> String? {
        guard let value = try? JSONValue.parse(Data(resultSummary.utf8)) else { return nil }
        return pendingApprovalID(in: value)
    }

    /// Use the filed reason for the card's title and detail because it carries what the person is being asked.
    package static func pendingApprovalReason(in value: JSONValue) -> String? {
        let reply = ToolResult(value)
        guard case .object(let object) = reply.payload,
              object["status"]?.stringValue == reply.status, reply.said("waiting_approval"),
              case .string(let reason)? = object["reason"] else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2000))
    }

    package static func pendingApprovalID(in value: JSONValue) -> String? {
        let reply = ToolResult(value)
        guard case .object(let object) = reply.payload,
              object["status"]?.stringValue == reply.status, reply.said("waiting_approval"),
              case .string(let rawID)? = object["approvalId"] ?? object["approval_id"]
        else { return nil }

        let approvalID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return approvalID.isEmpty ? nil : approvalID
    }
}
