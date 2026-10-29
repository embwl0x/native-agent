import Foundation
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `QuietTrustPolicyPreset.swift` | `MobileTrustAction.Preset` policy plans, locked save and effective-policy matching |

extension MobileTrustAction.Preset {
    /// The presets the agent may apply to itself while this Mac is in Full Mac.
    /// Full Mac is deliberately absent: lowering the fence is allowed, raising
    /// it to Full Mac is the person's alone.
    public static var quietWritable: [MobileTrustAction.Preset] { [.safe, .workMode, .builder] }

    public static func matching(policy: TrustPolicy, accessMode: String?) -> MobileTrustAction.Preset? {
        // Developer mode is a separate axis; the Full Mac fence is its access policy.
        let fullMac = MobileTrustAction.Preset.fullMac.plan
        if accessMode == fullMac.agentAccessMode,
           policy.permissionLevel == fullMac.permissionLevel,
           (policy.filePolicy?.outsideWorkspaceDefault ?? "deny") == fullMac.outsideDefault {
            return .fullMac
        }
        return allCases.first {
            guard $0 != .fullMac else { return false }
            let plan = $0.plan
            return plan.agentAccessMode == accessMode
                && plan.permissionLevel == policy.permissionLevel
                && plan.autonomyDefault == (policy.autonomyDefault ?? "supervised")
                && plan.requireBackups == (policy.filePolicy?.requireBackupBeforeWrite ?? true)
                && plan.outsideDefault == (policy.filePolicy?.outsideWorkspaceDefault ?? "deny")
                && plan.developerMode == policy.developerMode
                && (policy.macControlPolicy?.shellAllowed ?? false) == plan.developerMode
                && (policy.macControlPolicy?.systemControlAllowed ?? false) == plan.developerMode
        }
    }

    /// The Mac picker and paired phone share one complete, locked preset patch.
    public func save(
        dataRoot: URL,
        fullMacConfirmed: Bool,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        let plan = plan
        guard !plan.requiresFullMacConfirmation || fullMacConfirmed else {
            throw TrustCenterError.invalidRequest
        }
        let existing = try await SwiftNativeTrustCenter(dataRoot: dataRoot).getTrust()
        let destructive = plan.agentAccessMode == "full" && plan.developerMode
        let remoteAllowed: Bool
        switch plan.agentAccessMode {
        case "read_only": remoteAllowed = false
        case "full": remoteAllowed = true
        default: remoteAllowed = existing.macControlPolicy?.remoteFromIosAllowed ?? false
        }
        var body: [String: Any] = [
            "permissionLevel": plan.permissionLevel,
            "autonomyDefault": plan.autonomyDefault,
            "developerMode": plan.developerMode,
            "filePolicy": [
                "requireBackupBeforeWrite": plan.requireBackups,
                "outsideWorkspaceDefault": plan.outsideDefault,
            ],
            "macControlPolicy": TrustPolicyActions.macControlPolicyForAccessMode(
                plan.agentAccessMode, remoteFromIosAllowed: remoteAllowed, developerMode: destructive
            ),
        ]
        if let enablesAutonomy = plan.enablesAutonomy { body["enableAutonomy"] = enablesAutonomy }
        return try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: body, dataRoot: dataRoot, guardedByLockedPolicy: guardedByLockedPolicy
        )
    }

    public var plan: TrustPolicyPresetPlan {
        switch self {
        case .safe:
            TrustPolicyPresetPlan(
                agentAccessMode: "read_only", permissionLevel: "strict",
                autonomyDefault: "supervised", requireBackups: true,
                outsideDefault: "deny", developerMode: false,
                commit: .accessModeOnly, requiresFullMacConfirmation: false,
                enablesAutonomy: false
            )
        case .workMode:
            TrustPolicyPresetPlan(
                agentAccessMode: "workspace", permissionLevel: "balanced",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "deny", developerMode: false,
                commit: .accessModeOnly, requiresFullMacConfirmation: false
            )
        case .builder:
            TrustPolicyPresetPlan(
                agentAccessMode: "workspace", permissionLevel: "balanced",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "ask", developerMode: false,
                commit: .accessModeThenTrustPolicy, requiresFullMacConfirmation: false
            )
        case .fullMac:
            TrustPolicyPresetPlan(
                agentAccessMode: "full", permissionLevel: "full_mac_os",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "allow", developerMode: true,
                commit: .accessModeOnly, requiresFullMacConfirmation: true,
                enablesAutonomy: true
            )
        }
    }
}

public struct TrustPolicyPresetPlan: Equatable, Sendable {
    public enum Commit: Equatable, Sendable {
        case accessModeOnly
        case accessModeThenTrustPolicy
    }

    public let agentAccessMode: String
    public let permissionLevel: String
    public let autonomyDefault: String
    public let requireBackups: Bool
    public let outsideDefault: String
    public let developerMode: Bool
    public let commit: Commit
    public let requiresFullMacConfirmation: Bool
    /// Full Mac enables unattended work, Safe disables it, and Work/Builder leave it unchanged.
    public var enablesAutonomy: Bool? = nil
}
