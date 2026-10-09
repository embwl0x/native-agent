import Foundation

public enum DoctorRepairScope: Sendable {
    case automatic
    case onboarding
    case button
}

/// Safe repair admission and receipt interpretation shared by Doctor and its UI.
public enum DoctorSafeRepairPolicy {
    public static let oauthRefreshInstruction = "Run Repair Safe Issues to refresh expired OAuth access through each credential owner."

    // Doctor fixes what it finds: automatic runs every core repair that backs
    // up and revalidates under the writer's lock before it replaces, except
    // authority stores (`createMissingOnlyIDs`). Onboarding only creates.
    // OAuth refresh runs through its credential owners in every scope.
    // Persona/identity writes always require the button, even for missing docs.
    public static let automaticCoreIDs: Set<String> = [
        "icloud_bridge_state", "runtime_json_stores", "chat_messages", "oauth_token_expiry",
        "inspector.trace_integrity", "coreml_embedder",
    ]

    /// Runtime JSON stores hold routing, consent and registry authority
    /// (provider picks, MCP consent, connectors, tools); resetting one to `{}`
    /// or `[]` drops User's choices. Automatic runs only create missing ones;
    /// replacing a malformed one stays on the button.
    public static let createMissingOnlyIDs: Set<String> = ["runtime_json_stores"]

    /// Live repairs an unattended run must leave to the button: restoring
    /// cognition from disk would drop in-memory state its blocked writes held.
    public static let buttonOnlyLiveIDs: Set<String> = ["live.cognition.persistence"]

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
                    || (scope == .automatic && executableLiveIDs.contains(check.id)
                        && !buttonOnlyLiveIDs.contains(check.id))
                    || (check.id == "live.embedding_download"
                        && check.detail.hasPrefix("A resumable memory model transfer"))
            case .button: true
            }
            guard isAdverse(check.status) || isOAuthRefresh(check),
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

    /// Sign-ins and permissions are the only steps Doctor hands to User; they
    /// are gathered into one inbox ask.
    public static func isUserAsk(_ check: CheckResult) -> Bool {
        isAdverse(check.status) && check.ask != nil
    }

    public static func isAdverse(_ status: String) -> Bool {
        ["warn", "warning", "fail", "failed", "error"].contains(normalized(status))
    }

    private static func isSafeCoreRepair(_ check: CheckResult) -> Bool {
        isOAuthRefresh(check) || normalized(check.repair).hasPrefix("run repair safe issues")
    }

    private static func isOAuthRefresh(_ check: CheckResult) -> Bool {
        check.id == "oauth_token_expiry" && check.repair == oauthRefreshInstruction
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
