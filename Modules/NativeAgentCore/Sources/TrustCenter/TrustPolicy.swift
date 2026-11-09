import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `TrustPolicy.swift` | Typed checked policy decoding and effect-time Mac control serialization |

extension TrustPolicy {
    public static func requireEditRevision(_ revision: String, policyObject: [String: JSONValue], dataRoot: URL) throws {
        let center = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let current = try Self(policyObject: center.normalizedTrustPolicy(saved: policyObject,
            defaults: center.defaultTrustPolicy(), freshInstall: policyObject.isEmpty))
        guard try current.editRevision() == revision else { throw TrustCenterError.policyConflict }
    }
    public init(policyObject: [String: JSONValue]) throws {
        let data = try JSONValue.object(policyObject).serializedData(pretty: false)
        self = try JSONDecoder().decode(TrustPolicy.self, from: data)
    }

}

// Effect-time policy serialization stays with TrustCenter.
extension MacControlPolicyWireSnapshot {
    var wireValue: [String: Any] {
        [
            "enabled": enabled,
            "applescript_allowed": applesScriptAllowed,
            "jxa_allowed": jxaAllowed,
            "shortcuts_allowed": shortcutsAllowed,
            "accessibility_allowed": accessibilityAllowed,
            "system_control_allowed": systemControlAllowed,
            "file_ops_allowed": fileOpsAllowed,
            "shell_allowed": shellAllowed,
            "notifications_allowed": notificationsAllowed,
            "spotlight_allowed": spotlightAllowed,
            "approval_required_for": approvalRequiredFor,
            "remote_from_ios_allowed": remoteFromIosAllowed,
        ]
    }
}
