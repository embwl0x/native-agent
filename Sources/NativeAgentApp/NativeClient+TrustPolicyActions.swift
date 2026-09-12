import Foundation
import NativeAgentShared
import TrustCenter


extension NativeClient {
    /// The Developer Mode toggle is an operator-facing, restart-applied policy
    /// change. Keep its persistence separate from changing Full Mac access.
    ///
    /// The same patch also keeps the dependent destructive-action, shell, and
    /// system-control gates coherent on the next launch. Deep merge preserves
    /// all unrelated Trust Center policy and canonical normalization remains
    /// the final authority.
    static func developerModePatchBody(enabled: Bool) -> [String: Any] {
        [
            "developerMode": enabled,
            "filePolicy": [
                "allowDestructiveActions": enabled,
            ],
            "macControlPolicy": [
                "shell_allowed": enabled,
                "system_control_allowed": enabled,
                "riskGatePolicy": [
                    "critical": enabled ? "auto" : "deny",
                ],
            ],
        ]
    }

    func saveDeveloperMode(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: Self.developerModePatchBody(enabled: enabled))
    }

    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async throws -> TrustPolicy {
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

    func saveEnableAutonomy(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: ["enableAutonomy": enabled])
    }

    func saveChromeControlEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await postTrustWrite(body: [
            "chromeControlPolicy": ["enabled": enabled]
        ])
    }

    // PATCH-2026-05-07: mac-control-ui-1 POST macControlPolicy block to /v1/trust.
    func saveMacControlPolicy(_ policy: TrustMacControlPolicy) async throws -> TrustPolicy {
        let approvalList: [String] = policy.approvalRequiredFor
        let body: [String: Any] = [
            "macControlPolicy": [
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
                "approval_required_for": approvalList,
                "remote_from_ios_allowed": policy.remoteFromIosAllowed,
            ] as [String: Any]
        ]
        return try await postTrustWrite(body: body)
    }

    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        let normalized = preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_")
        if normalized == "full" || normalized == "full_mac" {
            return try await saveAgentAccessMode("full", currentPolicy: currentPolicy)
        }

        let approvals = ["shell", "file_ops", "applescript", "jxa", "accessibility"]
        let riskGate: [String: Any] = [
            "low": "auto",
            "medium": "approve_each",
            "high": "approve_each",
            "critical": "deny",
        ]

        let filePolicy: [String: Any] = [
            "requireBackupBeforeWrite": true,
            "outsideWorkspaceDefault": "deny",
            "allowDestructiveActions": false,
        ]

        let watchPolicy: [String: Any] = [
            "enabled": true,
            "applescript_allowed": false,
            "jxa_allowed": false,
            "shortcuts_allowed": true,
            "accessibility_allowed": false,
            "system_control_allowed": false,
            "file_ops_allowed": false,
            "shell_allowed": false,
            "notifications_allowed": true,
            "spotlight_allowed": true,
            "remote_from_ios_allowed": true,
            "approval_required_for": approvals,
            "riskGatePolicy": riskGate,
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
                "macControlPolicy": watchPolicy,
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

    func saveAgentAccessMode(_ mode: String, currentPolicy: TrustPolicy? = nil, developerMode: Bool? = nil) async throws -> TrustPolicy {
        let normalized = AppModel.normalizedAgentAccessMode(mode)
        let existingPolicy: TrustPolicy?
        if let currentPolicy {
            existingPolicy = currentPolicy
        } else {
            existingPolicy = try? await getTrustPolicy()
        }
        let requestedDeveloperMode = developerMode ?? existingPolicy?.developerMode ?? false
        let destructiveMode = normalized == "full" && requestedDeveloperMode
        let remoteFromIosAllowed = existingPolicy?.macControlPolicy?.remoteFromIosAllowed ?? false
        var body: [String: Any] = [:]
        switch normalized {
        case "read_only":
            body = [
                "permissionLevel": "strict",
                "autonomyDefault": "supervised",
                "developerMode": false,
                "filePolicy": [
                    "requireBackupBeforeWrite": true,
                    "outsideWorkspaceDefault": "deny",
                    "allowDestructiveActions": false,
                ],
                "macControlPolicy": Self.macControlPolicyForAccessMode("read_only", remoteFromIosAllowed: false),
            ]
        case "workspace":
            body = [
                "permissionLevel": "balanced",
                "autonomyDefault": "workspace_autonomous",
                "developerMode": false,
                "filePolicy": [
                    "requireBackupBeforeWrite": true,
                    "outsideWorkspaceDefault": "deny",
                    "allowDestructiveActions": false,
                ],
                "macControlPolicy": Self.macControlPolicyForAccessMode("workspace", remoteFromIosAllowed: remoteFromIosAllowed),
            ]
        case "full":
            body = [
                "permissionLevel": "full_mac_os",
                "autonomyDefault": "workspace_autonomous",
                "developerMode": destructiveMode,
                "filePolicy": [
                    "requireBackupBeforeWrite": true,
                    "outsideWorkspaceDefault": "allow",
                    "allowDestructiveActions": destructiveMode,
                ],
                "macControlPolicy": Self.macControlPolicyForAccessMode(
                    "full",
                    remoteFromIosAllowed: true,
                    developerMode: destructiveMode
                ),
            ]
        default:
            body = [
                "permissionLevel": "balanced",
                "autonomyDefault": "supervised",
                "developerMode": false,
                "filePolicy": [
                    "requireBackupBeforeWrite": true,
                    "outsideWorkspaceDefault": "deny",
                    "allowDestructiveActions": false,
                ],
                "macControlPolicy": Self.macControlPolicyForAccessMode("read_only", remoteFromIosAllowed: false),
            ]
        }
        return try await postTrustWrite(body: body)
    }

    static func macControlPolicyForAccessMode(_ mode: String, remoteFromIosAllowed: Bool = false, developerMode: Bool = false) -> [String: Any] {
        TrustAccessModeCapabilityCatalog.macControlWireValue(
            for: mode,
            remoteFromIosAllowed: remoteFromIosAllowed,
            developerMode: developerMode
        )
    }

    func saveTrustPolicyFull(
        permissionLevel: String,
        autonomyDefault: String,
        requireBackups: Bool,
        outsideDefault: String,
        developerMode: Bool = false,
        autonomousTraining: Bool? = nil,
        dreamScheduler: Bool? = nil,
        routeThroughPromotion: Bool? = nil,
        promotionEnabled: Bool? = nil,
        autoPromoteTierA: Bool? = nil
    ) async throws -> TrustPolicy {
        var body: [String: Any] = [
            "permissionLevel": permissionLevel,
            "autonomyDefault": autonomyDefault,
            "developerMode": developerMode,
            "filePolicy": [
                "requireBackupBeforeWrite": requireBackups,
                "outsideWorkspaceDefault": outsideDefault
            ]
        ]
        if autonomousTraining != nil || dreamScheduler != nil || routeThroughPromotion != nil {
            var training: [String: Any] = [:]
            if let v = autonomousTraining { training["autonomous_training"] = v }
            if let v = dreamScheduler { training["dream_scheduler"] = v }
            if let v = routeThroughPromotion { training["route_through_promotion"] = v }
            body["trainingPolicy"] = training
        }
        if promotionEnabled != nil || autoPromoteTierA != nil {
            var promo: [String: Any] = [:]
            if let v = promotionEnabled { promo["enabled"] = v }
            if let v = autoPromoteTierA { promo["auto_promote_tier_a"] = v }
            body["promotionPolicy"] = promo
        }
        return try await postTrustWrite(body: body)
    }
}
