import Foundation
import NativeAgentShared
// Blueprint: | `TrustAccessModeCapabilityCatalog.swift` | `TrustAccessModeCapabilityCatalog` enum; `normalizedMode`, `macControlPolicy` and Mac integration preset recognition |

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
    ) -> MacControlPolicyWireSnapshot {
        switch normalizedMode(rawMode) {
        case "workspace":
            return MacControlPolicyWireSnapshot(
                enabled: true,
                shortcutsAllowed: true,
                fileOpsAllowed: true,
                notificationsAllowed: true,
                spotlightAllowed: true,
                remoteFromIosAllowed: remoteFromIosAllowed
            )
        case "full":
            return MacControlPolicyWireSnapshot(
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
            return MacControlPolicyWireSnapshot(
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
        macControlPolicy(
            for: rawMode,
            remoteFromIosAllowed: remoteFromIosAllowed,
            developerMode: developerMode
        ).wireValue
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
    public static func macIntegrationPreset(for policy: MacControlPolicyWireSnapshot) -> MacIntegrationPreset {
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
