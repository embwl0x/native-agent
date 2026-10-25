import Foundation
// Blueprint: | `DoctorSafeRepairPolicy.swift` | `DoctorSafeRepairPolicy` enum; `checkIDs`, `appliedRepairCount` |

public enum DoctorRepairScope: Sendable {
    case automatic
    case onboarding
    case button
}

/// Safe repair admission and receipt interpretation shared by Doctor and its UI.
public enum DoctorSafeRepairPolicy {
    public static let oauthRefreshInstruction = "Press Repair in Diagnostics → Health checks to refresh expired OAuth access through each credential owner."

    // Automatic repair delegates to registered owners. Doctor never seeds
    // persona, resets runtime authority or rewrites transcripts.
    public static let automaticCoreIDs: Set<String> = [
        "icloud_bridge_state", "oauth_token_expiry",
        "inspector.trace_integrity", "coreml_embedder",
    ]

    public static func checkIDs(
        for checks: [CheckResult], executableLiveIDs: Set<String> = [],
        scope: DoctorRepairScope = .button
    ) -> [String] {
        var seen = Set<String>()
        return checks.compactMap { check in
            let liveRepair = executableLiveIDs.contains(check.checkID)
                || (check.checkID.hasPrefix("live.") && check.repair_available == true)
            let scopeAllowsRepair = switch scope {
            case .automatic, .onboarding:
                automaticCoreIDs.contains(check.checkID)
                    || (scope == .automatic && executableLiveIDs.contains(check.checkID)
                        && check.automaticRepairEligible != false)
                    || (check.checkID == "live.embedding_download"
                        && check.detail.hasPrefix("A resumable memory model transfer"))
            case .button: true
            }
            guard isAdverse(check.status) || isOAuthRefresh(check),
                  liveRepair || check.repair_available == true || isSafeCoreRepair(check),
                  scopeAllowsRepair else { return nil }
            let id = check.checkID.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted ? id : nil
        }
    }

    /// Count the repair owner's outcome, independently of receipt wording.
    public static func appliedRepairCount(in checks: [CheckResult]) -> Int {
        checks.filter { $0.repairApplied == true }.count
    }

    /// Core checks still return legacy repair copy. Only an advertised,
    /// registered handler may survive in the report's executable field.
    public static func executableCoreIDs(for checks: [CheckResult]) -> Set<String> {
        let handlers = Set(SwiftNativeDoctorChecks.defaultChecks.compactMap {
            $0 is any RepairingDoctorCheck ? $0.id : nil
        })
        return Set(checkIDs(for: checks)).intersection(handlers)
    }

    /// Only sign-ins and permissions join the consent inbox ask; app-defect
    /// recovery instructions do not become consent requests.
    public static func isUserAsk(_ check: CheckResult) -> Bool {
        isAdverse(check.status) && check.ask != nil
    }

    public static func isAdverse(_ status: String) -> Bool {
        ["warning", "failing"].contains(DoctorPlainCopy.bucket(for: normalized(status)))
    }

    /// Recognize current instructions and older cached reports in both admission
    /// and human-step projection.
    static func isCoreRepairInstruction(_ instruction: String?) -> Bool {
        let instruction = normalized(instruction)
        return instruction.hasPrefix("run repair safe issues")
            || instruction.hasPrefix("press repair in diagnostics → health checks")
    }

    private static func isSafeCoreRepair(_ check: CheckResult) -> Bool {
        isOAuthRefresh(check) || isCoreRepairInstruction(check.repair)
    }

    private static func isOAuthRefresh(_ check: CheckResult) -> Bool {
        check.checkID == "oauth_token_expiry" && (check.repair == oauthRefreshInstruction
            || check.repair == "Run Repair Safe Issues to refresh expired OAuth access through each credential owner.")
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
