import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustPolicyActions.swift` | `TrustPolicyActions` struct; `developerModePatchBody`, `saveMemoryPolicy`, `saveAgentAccessMode`; `saveMacControlPolicy` patches edited fields and checks their baseline inside the policy lock |


/// Operator choices mapped to the canonical checked TrustCenter writer.
public struct TrustPolicyActions: Sendable {
    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    private func postTrustWrite(body: [String: Any]) async throws -> TrustPolicy {
        try await TrustPolicyToolWriter.applyTrustPolicyPatch(body: body, dataRoot: dataRoot)
    }

    public func saveWorkshopPolicyToggle(enabled: Bool? = nil) async throws -> TrustPolicy {
        var patch: [String: Any] = [:]
        if let enabled { patch["enabled"] = enabled }
        return try await postTrustWrite(body: [WorkshopPolicyBlockVocabulary.wireKey: patch])
    }

    /// The Developer Mode toggle is an operator-facing, restart-applied policy
    /// change. Keep its persistence separate from changing Full Mac access.
    ///
    /// The same patch also keeps the dependent shell and
    /// system-control gates coherent on the next launch. Deep merge preserves
    /// all unrelated Trust Center policy and canonical normalization remains
    /// the final authority.
    public static func developerModePatchBody(enabled: Bool) -> [String: Any] {
        [
            "developerMode": enabled,
            "macControlPolicy": [
                "shell_allowed": enabled,
                "system_control_allowed": enabled,
            ],
        ]
    }

    public func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async throws -> TrustPolicy {
        let body: [String: Any] = [
            "multimodalPolicy": [
                "screen_capture": policy.screen_capture,
                "vision_api_calls": policy.vision_api_calls,
                "file_ingestion_pdf": policy.file_ingestion_pdf,
                "file_ingestion_docx": policy.file_ingestion_docx,
                "image_generation_openai": policy.image_generation_openai,
                "tts_openai": policy.tts_openai,
            ]
        ]
        return try await postTrustWrite(body: body)
    }

    public func saveEnableAutonomy(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: ["enableAutonomy": enabled])
    }

    public func saveChromeControlEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: [
            "chromeControlPolicy": ["enabled": enabled]
        ])
    }

    /// Security Center's "Pause everything": `securityPolicy.killSwitchEnabled`,
    /// deep-merged through the one trust-write chokepoint.
    public func saveKillSwitchEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: [
            "securityPolicy": ["killSwitchEnabled": enabled]
        ])
    }

    public func saveMemoryPolicy(crossSessionRecall: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: [
            "memoryPolicy": [
                "cross_session_recall": crossSessionRecall,
            ]
        ])
    }

    public func patchMemoryPolicy(
        knowledgeGraphEnabled: Bool? = nil,
        adaptivePromotion: Bool? = nil
    ) async throws -> TrustPolicy {
        var memoryPolicy: [String: Any] = [:]
        if let knowledgeGraphEnabled {
            memoryPolicy["knowledge_graph_enabled"] = knowledgeGraphEnabled
        }
        if let adaptivePromotion {
            memoryPolicy["adaptive_promotion"] = adaptivePromotion
        }
        return try await postTrustWrite(body: ["memoryPolicy": memoryPolicy])
    }

    /// Save only edited fields. Compare their original values with the current
    /// effective policy inside the canonical writer's lock; a conflicting edit
    /// leaves the policy untouched, and unrelated concurrent choices survive.
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

    public func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        let normalized = preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_")
        if normalized == "full" || normalized == "full_mac" {
            return try await saveAgentAccessMode("full", currentPolicy: currentPolicy)
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

    public func saveAgentAccessMode(_ mode: String, currentPolicy: TrustPolicy? = nil, developerMode: Bool? = nil) async throws -> TrustPolicy {
        let normalized = TrustAccessModeCapabilityCatalog.normalizedMode(mode)
        let existingPolicy: TrustPolicy?
        if let currentPolicy {
            existingPolicy = currentPolicy
        } else {
            existingPolicy = try? await SwiftNativeTrustCenter(dataRoot: dataRoot).getTrust()
        }
        let requestedDeveloperMode = developerMode ?? (normalized == "full")
        let destructiveMode = normalized == "full" && requestedDeveloperMode
        let remoteFromIosAllowed = existingPolicy?.macControlPolicy?.remoteFromIosAllowed ?? false
        let full = normalized == "full"
        let workspace = normalized == "workspace"
        let body: [String: Any] = [
            "permissionLevel": full ? "full_mac_os" : normalized == "read_only" ? "strict" : "balanced",
            "autonomyDefault": full || workspace ? "workspace_autonomous" : "supervised",
            "developerMode": destructiveMode,
            "filePolicy": [
                "requireBackupBeforeWrite": true,
                "outsideWorkspaceDefault": full ? "allow" : "deny",
            ],
            "macControlPolicy": Self.macControlPolicyForAccessMode(
                normalized,
                remoteFromIosAllowed: full || (workspace && remoteFromIosAllowed),
                developerMode: destructiveMode
            ),
        ]
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
