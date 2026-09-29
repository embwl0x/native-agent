import Foundation

public enum DoctorRepairScope: Sendable {
    case automatic
    case onboarding
    case button
}

/// Safe repair admission and receipt interpretation shared by Doctor and its UI.
public enum DoctorSafeRepairPolicy {
    public static let oauthRefreshInstruction = "Run Repair Safe Issues to refresh expired OAuth access through each credential owner."

    // Non-button file repairs dispatch only createMissing(). OAuth refresh is
    // non-destructive and runs through its credential owners in every scope.
    // Persona/identity writes always require the button, even for missing docs.
    public static let automaticCoreIDs: Set<String> = [
        "icloud_bridge_state", "runtime_json_stores", "chat_messages", "oauth_token_expiry",
    ]

    public static func checkIDs(
        for checks: [CheckResult], executableLiveIDs: Set<String> = [],
        scope: DoctorRepairScope = .button
    ) -> [String] {
        var seen = Set<String>()
        return checks.compactMap { check in
            let liveRepair = executableLiveIDs.contains(check.id)
                || (check.id.hasPrefix("live.") && check.repair_available == true)
            let scopeAllowsRepair = switch scope {
            case .automatic, .onboarding:
                automaticCoreIDs.contains(check.id)
                    || (check.id == "live.embedding_download"
                        && check.detail.hasPrefix("A resumable memory model transfer"))
            case .button: true
            }
            guard isAdverse(check.status),
                  liveRepair || isSafeCoreRepair(check),
                  check.id != "persona_engine" || scope == .button,
                  scopeAllowsRepair else { return nil }
            let id = check.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted ? id : nil
        }
    }

    /// Completion receipts are separate from executable repair instructions.
    /// These verbs are emitted only after app-owned state was changed.
    public static func appliedRepairCount(in checks: [CheckResult]) -> Int {
        checks.filter { check in
            let receipt = normalized(check.receipt)
            return ["completed:", "created:", "created ", "repaired:", "backed up", "seeded ", "reset ", "wiped "]
                .contains(where: { receipt.hasPrefix($0) })
        }.count
    }

    public static func isAdverse(_ status: String) -> Bool {
        ["warn", "warning", "fail", "failed", "error"].contains(normalized(status))
    }

    private static func isSafeCoreRepair(_ check: CheckResult) -> Bool {
        let oauthRetry = check.id == "oauth_token_expiry"
            && check.repair?.contains(oauthRefreshInstruction) == true
        return oauthRetry || normalized(check.repair).hasPrefix("run repair safe issues")
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
