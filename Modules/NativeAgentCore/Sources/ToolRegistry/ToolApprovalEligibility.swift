import Foundation

public enum ToolApprovalEligibility {
    /// The mounted control only offers activation for an actual proposal that
    /// the last validator pass marked valid. SwiftNativeToolExecution repeats
    /// these checks at promotion time; this shared eligibility gate prevents known
    /// terminal or unloaded records from looking actionable in the meantime.
    public static func refusal(for tool: ToolRecord) -> String? {
        let status = tool.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["proposed", "draft", "drafted"].contains(status) else {
            if status == "quarantined" {
                return "Quarantined tools must be reviewed before they can be approved."
            }
            if status.isEmpty {
                return "This tool has no loaded proposal status. Refresh before approving it."
            }
            return "Only proposed tools can be approved."
        }
        guard tool.validationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "valid" else {
            return "This proposal has not passed validation."
        }
        return nil
    }
}
