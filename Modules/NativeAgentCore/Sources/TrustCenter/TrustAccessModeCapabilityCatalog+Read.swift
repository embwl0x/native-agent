import Foundation
import PersistenceCore
// Blueprint: | `TrustAccessModeCapabilityCatalog+Read.swift` | Trust projections; effective Full Mac uses MacControlGate's admitted-call projection and PermissionLaw's Full Mac posture: no category approval prompts; saved restricted-mode approval metadata remains unchanged |

extension TrustAccessModeCapabilityCatalog {
    public enum FileChangeState {
        case unavailable, supervised, appData, workspace, fullMac
    }

    public static func fileChangeState(_ policy: TrustPolicy, accessMode: String) -> FileChangeState {
        let posture = posture(policy)
        if posture == .readOnly || normalizedMode(accessMode) == "read_only" {
            return .unavailable
        }
        if posture == .fullMac { return .fullMac }
        switch policy.autonomyDefault {
        case "workspace_autonomous": return .workspace
        case "app_data_autonomous": return .appData
        default: return .supervised
        }
    }

    /// Full Mac's effective grants leave the saved restricted-mode settings intact.
    public static func effectiveMacControlPolicy(_ policy: TrustPolicy) -> TrustMacControlPolicy? {
        guard fullMacGrantIsActive(policy) else { return policy.macControlPolicy }
        let root: [String: JSONValue] = [
            "permissionLevel": .string(policy.permissionLevel),
            "filePolicy": .object(["outsideWorkspaceDefault": .string(policy.filePolicy?.outsideWorkspaceDefault ?? "")]),
            "macControlPolicy": .object((policy.macControlPolicy ?? TrustMacControlPolicy()).wireValue
                .mapValues { JSONValue(fromFoundation: $0) }),
        ]
        let effective = MacControlGate.policyForAdmittedFullMac(.fromTrustPolicyObject(root), admitted: true)
        return TrustMacControlPolicy(
            enabled: effective.enabled,
            applesScriptAllowed: effective.categoryAllowed["applescript_allowed"] == true,
            jxaAllowed: effective.categoryAllowed["jxa_allowed"] == true,
            shortcutsAllowed: effective.categoryAllowed["shortcuts_allowed"] == true,
            accessibilityAllowed: effective.categoryAllowed["accessibility_allowed"] == true,
            systemControlAllowed: effective.categoryAllowed["system_control_allowed"] == true,
            fileOpsAllowed: effective.categoryAllowed["file_ops_allowed"] == true,
            shellAllowed: effective.categoryAllowed["shell_allowed"] == true,
            notificationsAllowed: effective.categoryAllowed["notifications_allowed"] == true,
            spotlightAllowed: effective.categoryAllowed["spotlight_allowed"] == true,
            // PermissionLaw's Full Mac posture admits ordinary category writes.
            // Saved approval metadata is not an effective approval boundary.
            approvalRequiredFor: [],
            remoteFromIosAllowed: effective.remoteFromIOSAllowed)
    }

    public static func grantedMacCategories(_ mac: TrustMacControlPolicy) -> [String] {
        let granted = Set(macCategories(mac).filter(\.allowed).map(\.name))
        return ["Notifications", "Spotlight search", "Shortcuts", "App automation",
                "Clicking and typing", "Files anywhere on this Mac", "System settings", "Terminal commands"]
            .filter(granted.contains)
    }

    private static func macCategories(_ mac: TrustMacControlPolicy) -> [(key: String, name: String, allowed: Bool)] {
        [
            ("shell", "Terminal commands", mac.shellAllowed),
            ("file_ops", "Files anywhere on this Mac", mac.fileOpsAllowed),
            ("applescript", "App automation", mac.applesScriptAllowed),
            ("jxa", "App automation", mac.jxaAllowed),
            ("accessibility", "Clicking and typing", mac.accessibilityAllowed),
            ("system_control", "System settings", mac.systemControlAllowed),
            ("shortcuts", "Shortcuts", mac.shortcutsAllowed),
            ("notifications", "Notifications", mac.notificationsAllowed),
            ("spotlight", "Spotlight search", mac.spotlightAllowed),
        ]
    }

    public static func macControlApprovalGroups(_ mac: TrustMacControlPolicy) -> (
        automatic: [String], asks: [String], unavailable: [String]
    ) {
        let categories = macCategories(mac)
        func names(_ rows: [(key: String, name: String, allowed: Bool)]) -> [String] {
            var seen = Set<String>()
            return rows.map(\.name).filter { seen.insert($0).inserted }
        }
        let asks = names(categories.filter { $0.allowed && mac.approvalRequiredFor.contains($0.key) })
        // The shared automation name asks if either AppleScript or JXA asks.
        let automatic = names(categories.filter { $0.allowed && !mac.approvalRequiredFor.contains($0.key) })
            .filter { !asks.contains($0) }
        let allowedNames = Set(categories.filter { $0.allowed }.map(\.name))
        return (automatic, asks, names(categories.filter { !$0.allowed && !allowedNames.contains($0.name) }))
    }

    public static func macControlRiskGroups(_ mac: TrustMacControlPolicy) -> (
        free: [String], asks: [String], hasUnguardedRisk: Bool
    ) {
        let riskKeys: Set<String> = ["shell", "file_ops", "applescript", "jxa", "accessibility"]
        let risky = macCategories(mac).filter { $0.allowed && riskKeys.contains($0.key) }
        let unguarded = Set(risky.filter { !mac.approvalRequiredFor.contains($0.key) }.map(\.name))
        let guarded = Set(risky.map(\.name)).subtracting(unguarded)
        let granted = grantedMacCategories(mac)
        return (granted.filter { !guarded.contains($0) }, granted.filter(guarded.contains), !unguarded.isEmpty)
    }

    public static func agentAccessMode(from policy: TrustPolicy, fallback: String = "auto") -> String {
        switch posture(policy) {
        case .fullMac: return "full"
        case .readOnly: return "read_only"
        case .work: break
        }
        if policy.autonomyDefault == "workspace_autonomous" {
            return "workspace"
        }
        if macControlPolicyNeedsWorkspace(policy.macControlPolicy) {
            return "workspace"
        }
        return normalizedMode(fallback)
    }

    /// The ACTIVE verdict is the law's (`PermissionLaw.posture`), the same
    /// one every gate reads. Full Mac has no timer: it is the saved policy.
    public static func fullMacGrantIsActive(_ policy: TrustPolicy) -> Bool {
        posture(policy) == .fullMac
    }

    /// The saved policy's posture, as every gate reads it.
    public static func posture(_ policy: TrustPolicy) -> PermissionPosture {
        PermissionLaw.posture(permissionLevel: policy.permissionLevel,
                              outsideWorkspaceDefault: policy.filePolicy?.outsideWorkspaceDefault ?? "")
    }

    private static func macControlPolicyNeedsWorkspace(_ policy: TrustMacControlPolicy?) -> Bool {
        guard let policy, policy.enabled else { return false }
        return policy.applesScriptAllowed
            || policy.jxaAllowed
            || policy.shortcutsAllowed
            || policy.accessibilityAllowed
            || policy.systemControlAllowed
            || policy.fileOpsAllowed
            || policy.shellAllowed
            || policy.notificationsAllowed
            || policy.spotlightAllowed
            || policy.remoteFromIosAllowed
    }

}
