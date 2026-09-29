import AppToolRuntime
import Foundation
import PersistenceCore
import TrustCenter

extension NativeClient {
    /// The Mac picker and paired phone share one complete, locked preset patch.
    static func saveTrustPreset(
        _ preset: TrustPolicyPreset,
        dataRoot: URL,
        fullMacConfirmed: Bool,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        let plan = preset.plan
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
                "allowDestructiveActions": destructive,
            ],
            "macControlPolicy": macControlPolicyForAccessMode(
                plan.agentAccessMode, remoteFromIosAllowed: remoteAllowed, developerMode: destructive
            ),
        ]
        if let enablesAutonomy = plan.enablesAutonomy { body["enableAutonomy"] = enablesAutonomy }
        return try await applyTrustPolicyPatch(
            body: body, dataRoot: dataRoot, guardedByLockedPolicy: guardedByLockedPolicy
        )
    }
}
