import Foundation
import NativeAgentShared
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
    public static func effectiveMacControlPolicy(_ policy: TrustPolicy) -> MacControlPolicyWireSnapshot? {
        guard fullMacGrantIsActive(policy) else { return policy.macControlPolicy }
        let root: [String: JSONValue] = [
            "permissionLevel": .string(policy.permissionLevel),
            "filePolicy": .object(["outsideWorkspaceDefault": .string(policy.filePolicy?.outsideWorkspaceDefault ?? "")]),
            "macControlPolicy": .object((policy.macControlPolicy ?? MacControlPolicyWireSnapshot()).wireValue
                .mapValues { JSONValue(fromFoundation: $0) }),
        ]
        let effective = MacControlGate.policyForAdmittedFullMac(.fromTrustPolicyObject(root), admitted: true)
        return MacControlPolicyWireSnapshot(
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

    public static func grantedMacCategories(_ mac: MacControlPolicyWireSnapshot) -> [String] {
        [
            ("Notifications", mac.notificationsAllowed),
            ("Spotlight search", mac.spotlightAllowed),
            ("Shortcuts", mac.shortcutsAllowed),
            ("App automation", mac.applesScriptAllowed || mac.jxaAllowed),
            ("Clicking and typing", mac.accessibilityAllowed),
            ("Files anywhere on this Mac", mac.fileOpsAllowed),
            ("System settings", mac.systemControlAllowed),
            ("Terminal commands", mac.shellAllowed),
        ].compactMap { $0.1 ? $0.0 : nil }
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

    private static func macControlPolicyNeedsWorkspace(_ policy: MacControlPolicyWireSnapshot?) -> Bool {
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
