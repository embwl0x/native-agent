import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustPolicyActions.swift` | `TrustPolicyActions`, `saveMacIntegrationPreset`, `saveMacControlPolicy` |


public struct TrustPolicyActions: Sendable {
    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    private func postTrustWrite(body: [String: Any]) async throws -> TrustPolicy {
        try await TrustPolicyToolWriter.applyTrustPolicyPatch(body: body, dataRoot: dataRoot)
    }

    public func saveChromeControlEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: [
            "chromeControlPolicy": ["enabled": enabled]
        ])
    }

    public func saveKillSwitchEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: [
            "securityPolicy": ["killSwitchEnabled": enabled]
        ])
    }

    /// Compare edited-field baselines under the canonical write lock so conflicts refuse while unrelated choices survive.
    public func saveMacControlPolicy(
        _ policy: MacControlPolicyWireSnapshot,
        comparedTo baseline: MacControlPolicyWireSnapshot,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        let baselineValues = baseline.wireValue.mapValues { JSONValue(fromFoundation: $0) }
        let changes = policy.wireValue.filter { baselineValues[$0.key] != JSONValue(fromFoundation: $0.value) }
        let changedKeys = Array(changes.keys)
        return try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: ["macControlPolicy": changes],
            dataRoot: dataRoot,
            guardedByLockedPolicy: { locked in
                try guardedByLockedPolicy?(locked)
                let current = try TrustPolicy(policyObject: SwiftNativeTrustCenter.normalizeTrustPolicy(locked))
                    .macControlPolicy ?? MacControlPolicyWireSnapshot()
                let currentValues = current.wireValue.mapValues { JSONValue(fromFoundation: $0) }
                guard changedKeys.allSatisfy({ currentValues[$0] == baselineValues[$0] }) else {
                    throw TrustCenterError.policyConflict
                }
            }
        )
    }

    public func saveMacIntegrationPreset(_ preset: String) async throws -> TrustPolicy {
        let normalized = preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_")
        if normalized == "full" || normalized == "full_mac" {
            return try await postTrustWrite(body: [
                "permissionLevel": "full_mac_os",
                "autonomyDefault": "workspace_autonomous",
                "developerMode": true,
                "filePolicy": [
                    "requireBackupBeforeWrite": true,
                    "outsideWorkspaceDefault": "allow",
                ],
                "macControlPolicy": Self.macControlPolicyForAccessMode("full", remoteFromIosAllowed: true, developerMode: true),
            ])
        }

        let filePolicy: [String: Any] = [
            "requireBackupBeforeWrite": true,
            "outsideWorkspaceDefault": "deny",
        ]

        let body: [String: Any]
        switch normalized {
        case "off", "disable", "disabled", "read_only":
            body = [
                "permissionLevel": "strict",
                "autonomyDefault": "supervised",
                "developerMode": false,
                "filePolicy": filePolicy,
                "macControlPolicy": Self.macControlPolicyForAccessMode("read_only", remoteFromIosAllowed: false),
            ]
        case "watch", "watch_only":
            body = [
                "permissionLevel": "balanced",
                "autonomyDefault": "supervised",
                "developerMode": false,
                "filePolicy": filePolicy,
                "macControlPolicy": MacControlPolicyWireSnapshot(enabled: true, remoteFromIosAllowed: true).wireValue,
            ]
        default:
            body = [
                "permissionLevel": "balanced",
                "autonomyDefault": "workspace_autonomous",
                "developerMode": false,
                "filePolicy": filePolicy,
                "macControlPolicy": Self.macControlPolicyForAccessMode("workspace", remoteFromIosAllowed: true),
            ]
        }
        return try await postTrustWrite(body: body)
    }

    public static func macControlPolicyForAccessMode(_ mode: String, remoteFromIosAllowed: Bool = false, developerMode: Bool = false) -> [String: Any] {
        TrustAccessModeCapabilityCatalog.macControlWireValue(
            for: mode,
            remoteFromIosAllowed: remoteFromIosAllowed,
            developerMode: developerMode
        )
    }
}
