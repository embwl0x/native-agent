import Foundation
import PersistenceCore

public enum ToolApprovalEligibility {
    /// The mounted control only offers activation for an actual proposal that
    /// the last validator pass marked valid. SwiftNativeToolExecution repeats
    /// these checks at promotion time; this shared eligibility gate prevents known
    /// terminal or unloaded records from looking actionable in the meantime.
    public static func refusal(for tool: ToolRecord, ownerAuthorized: Bool = false) -> String? {
        let fields: [String: JSONValue] = if case .object(let fields)? = tool.extras { fields } else { [:] }
        if fields["candidateDigest"] != nil {
            guard ["active", "proposed", "draft", "drafted"].contains(tool.status)
                || (ownerAuthorized && tool.pendingCandidate) else {
                return "Propose or roll back a candidate before approving this stopped tool."
            }
            return fields["candidateValidation"] == .string("valid") ? nil : "This exact candidate has not passed runtime validation."
        }
        let status = tool.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedProposal = ownerAuthorized && status == "disabled" && tool.codeFingerprint != nil
            && fields["admission"] == nil
        guard ["proposed", "draft", "drafted"].contains(status) || selectedProposal else {
            if status == "disabled" {
                return "Use tool.restore to turn this tool on."
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
