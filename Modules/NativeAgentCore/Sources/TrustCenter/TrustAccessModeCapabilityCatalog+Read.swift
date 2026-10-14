import Foundation

extension TrustAccessModeCapabilityCatalog {
    public enum FileChangeState {
        case unavailable, supervised, appData, workspace, fullMac
    }

    public static func fileChangeState(_ policy: TrustPolicy, accessMode: String) -> FileChangeState {
        if policy.permissionLevel == "strict" || normalizedMode(accessMode) == "read_only" {
            return .unavailable
        }
        if fullMacGrantIsActive(policy) { return .fullMac }
        switch policy.autonomyDefault {
        case "workspace_autonomous": return .workspace
        case "app_data_autonomous": return .appData
        default: return .supervised
        }
    }

    /// Full Mac's effective grants leave the saved restricted-mode settings intact.
    public static func effectiveMacControlPolicy(_ policy: TrustPolicy) -> TrustMacControlPolicy? {
        fullMacGrantIsActive(policy)
            ? macControlPolicy(for: "full", developerMode: true)
            : policy.macControlPolicy
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
        if (policy.permissionLevel == "full_mac_os" || policy.filePolicy?.outsideWorkspaceDefault == "allow"),
           fullMacGrantIsActive(policy) {
            return "full"
        }
        if policy.permissionLevel == "strict" {
            return "read_only"
        }
        if policy.autonomyDefault == "workspace_autonomous" {
            return "workspace"
        }
        if macControlPolicyNeedsWorkspace(policy.macControlPolicy) {
            return "workspace"
        }
        return normalizedMode(fallback)
    }

    /// The ACTIVE verdict is the REAL gate's — `MacControlGate.fullMacActive`,
    /// the same check `SwiftToolDispatcher.fullMacToolAccess` runs before
    /// including the Full-Mac file-ops tool block in the agent's catalog.
    /// 2026-09-10: Full Mac has no timer, so this is purely the saved policy.
    public static func fullMacGrantIsActive(_ policy: TrustPolicy) -> Bool {
        MacControlGate.fullMacActive(
            MacControlTrustPolicy(
                outsideWorkspaceDefault: policy.filePolicy?.outsideWorkspaceDefault ?? "deny",
                permissionLevel: policy.permissionLevel.isEmpty ? "balanced" : policy.permissionLevel,
                developerMode: policy.developerMode,
                allowDestructiveActions: policy.filePolicy?.allowDestructiveActions ?? false
            )
        )
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
