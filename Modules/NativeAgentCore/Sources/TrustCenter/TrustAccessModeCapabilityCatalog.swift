import Foundation

/// Canonical Mac-control policy templates used by the access-mode writer.
public enum TrustAccessModeCapabilityCatalog {
    public static func normalizedMode(_ rawMode: String) -> String {
        let mode = rawMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return ["auto", "read_only", "workspace", "full"].contains(mode) ? mode : "auto"
    }

    public static func macControlPolicy(
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

    public static func macControlWireValue(
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
        var value = policy.wireValue
        value["riskGatePolicy"] = riskGate
        return value
    }
}

public enum MacIntegrationPreset: String, Identifiable {
    case off
    case watch
    case assistant
    case full

    public var id: String { rawValue }

}

extension TrustAccessModeCapabilityCatalog {
    public static func macIntegrationPreset(for policy: TrustMacControlPolicy) -> MacIntegrationPreset {
        if policy.enabled == false {
            return .off
        }
        if policy.shellAllowed && policy.fileOpsAllowed && policy.accessibilityAllowed && policy.approvalRequiredFor.isEmpty {
            return .full
        }
        if policy.fileOpsAllowed || policy.shellAllowed || policy.systemControlAllowed || policy.accessibilityAllowed || policy.applesScriptAllowed || policy.jxaAllowed {
            return .assistant
        }
        return .watch
    }

}
