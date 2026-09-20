import Foundation

/// Canonical Mac-control policy templates used by the access-mode writer.
enum TrustAccessModeCapabilityCatalog {
    static func normalizedMode(_ rawMode: String) -> String {
        let mode = rawMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return ["auto", "read_only", "workspace", "full"].contains(mode) ? mode : "auto"
    }

    static func macControlPolicy(
        for rawMode: String,
        remoteFromIosAllowed: Bool = false,
        developerMode: Bool = false
    ) -> TrustMacControlPolicy {
        switch normalizedMode(rawMode) {
        case "workspace":
            return TrustMacControlPolicy(
                enabled: true,
                shortcutsAllowed: true,
                fileOpsAllowed: true,
                notificationsAllowed: true,
                spotlightAllowed: true,
                remoteFromIosAllowed: remoteFromIosAllowed
            )
        case "full":
            return TrustMacControlPolicy(
                enabled: true,
                applesScriptAllowed: true,
                jxaAllowed: true,
                shortcutsAllowed: true,
                accessibilityAllowed: true,
                systemControlAllowed: developerMode,
                fileOpsAllowed: true,
                shellAllowed: developerMode,
                notificationsAllowed: true,
                spotlightAllowed: true,
                approvalRequiredFor: [],
                remoteFromIosAllowed: true
            )
        default:
            return TrustMacControlPolicy(
                enabled: false,
                applesScriptAllowed: false,
                jxaAllowed: false,
                shortcutsAllowed: false,
                accessibilityAllowed: false,
                systemControlAllowed: false,
                fileOpsAllowed: false,
                shellAllowed: false,
                notificationsAllowed: false,
                spotlightAllowed: false,
                remoteFromIosAllowed: false
            )
        }
    }

    static func macControlWireValue(
        for rawMode: String,
        remoteFromIosAllowed: Bool = false,
        developerMode: Bool = false
    ) -> [String: Any] {
        let policy = macControlPolicy(
            for: rawMode,
            remoteFromIosAllowed: remoteFromIosAllowed,
            developerMode: developerMode
        )
        let defaultRiskGate: [String: Any] = [
            "low": "auto",
            "medium": "approve_each",
            "high": "approve_each",
            "critical": "deny",
        ]
        let riskGate: [String: Any] = normalizedMode(rawMode) == "full"
            ? [
                "low": "auto",
                "medium": "auto",
                "high": "auto",
                "critical": developerMode ? "auto" : "deny",
            ]
            : defaultRiskGate
        return [
            "enabled": policy.enabled,
            "applescript_allowed": policy.applesScriptAllowed,
            "jxa_allowed": policy.jxaAllowed,
            "shortcuts_allowed": policy.shortcutsAllowed,
            "accessibility_allowed": policy.accessibilityAllowed,
            "system_control_allowed": policy.systemControlAllowed,
            "file_ops_allowed": policy.fileOpsAllowed,
            "shell_allowed": policy.shellAllowed,
            "notifications_allowed": policy.notificationsAllowed,
            "spotlight_allowed": policy.spotlightAllowed,
            "remote_from_ios_allowed": policy.remoteFromIosAllowed,
            "approval_required_for": policy.approvalRequiredFor,
            "riskGatePolicy": riskGate,
        ]
    }
}
