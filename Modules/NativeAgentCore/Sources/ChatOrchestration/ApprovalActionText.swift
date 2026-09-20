import Foundation
import NativeAgentCore

/// Presentation only; the original arguments remain authoritative for execution.
public enum ApprovalActionText {
    public static func actionName(_ tool: String) -> String {
        tool.split(whereSeparator: { $0 == "_" || $0 == "." }).joined(separator: " ")
    }

    public static func isInternalField(_ key: String) -> Bool {
        let key = key.lowercased()
        return key.hasPrefix("__") || key == "id" || key == "ids"
            || key.hasSuffix("_id") || key.hasSuffix("_ids")
            || key.hasSuffix("id") || key.hasSuffix("ids")
    }

    public static func sentence(tool: String) -> String {
        "Allow me to use \(actionName(tool))?"
    }

    public static func reason(_ reason: String?, tool: String) -> String {
        guard let reason, !reason.isEmpty,
              !reason.hasPrefix("autonomy="),
              reason != "Your tool permission settings require approval." else {
            return sentence(tool: tool)
        }
        return reason
    }
}
