import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ApprovalActionText.swift` | `ApprovalActionText`: approval action/reason presentation; original arguments remain execution authority |

/// Presentation only; the original arguments remain authoritative for execution.
public enum ApprovalActionText {
    public static func isInternalField(_ key: String) -> Bool {
        let key = key.lowercased()
        return key.hasPrefix("__") || key == "id" || key == "ids"
            || key.hasSuffix("_id") || key.hasSuffix("_ids")
            || key.hasSuffix("id") || key.hasSuffix("ids")
    }

    /// The act in the person's words (an `app` action by its own label), never the tool id.
    public static func sentence(tool: String, input: [String: JSONValue] = [:]) -> String {
        "Allow this: \(ApprovalWords.call(tool: tool, input: .object(input)).act)?"
    }

    public static func reason(_ reason: String?, tool: String, input: [String: JSONValue] = [:]) -> String {
        guard let reason, !reason.isEmpty else {
            return sentence(tool: tool, input: input)
        }
        return reason
    }
}
