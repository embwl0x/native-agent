import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeTrustCenter {
    /// Default trust policy for the Swift runtime. Saved policy values are
    /// merged over this shape by `loadTrustPolicy()`.
    public nonisolated func defaultTrustPolicy() -> [String: JSONValue] {
        var policy: [String: JSONValue] = [:]
        policy["permissionLevel"] = .string("balanced")
        policy["autonomyDefault"] = .string("supervised")
        // `enableAutonomy` is deliberately NOT here. This shape is the merge
        // base for EVERY saved policy, so a default true would silently grant
        // unattended work to an older strict policy that predates the key.
        // The fresh-install grant lives in `freshInstallTrustPolicyAdditions`,
        // applied only when no policy file exists.
        policy["updatedAt"] = .string(Self.isoTimestamp(clock()))
        policy["appDataRoot"] = .string(dataRoot.path)
        // Wave 4 phase A: STILL the old key. Readers accept `workshopPolicy`
        // too (WorkshopPolicyBlockVocabulary), but every writer keeps emitting
        // `missionPolicy` so a 0.3.7 iOS install decodes this byte-for-byte.
        policy[WorkshopPolicyBlockVocabulary.wireKey] = .object([
            "allowBackgroundMissions": .bool(true),
            "requireReceipts": .bool(true),
            "autoCreateMissionFromChat": .bool(false),
            "enabled": .bool(true),
            "showTimeline": .bool(true),
        ])
        policy["toolPolicy"] = .object([
            "autoPromoteSafeTools": .bool(true),
            "autoRunSafeTools": .bool(true),
            "riskyToolApproval": .string("ask"),
        ])
        policy["filePolicy"] = .object([
            "allowedWorkspaceIds": .array([]),
            "workspaceRoots": .array(TrustCenterDefaultWorkspaceRoots.defaultRootPaths(dataRoot: dataRoot).map { .string($0) }),
            "requireBackupBeforeWrite": .bool(true),
            "allowDestructiveActions": .bool(false),
            "outsideWorkspaceDefault": .string("deny"),
        ])
        policy["connectorPolicy"] = .object([
            "defaultEnabled": .bool(false),
            "sendExternalMessagesRequiresApproval": .bool(true),
        ])
        policy["chromeControlPolicy"] = .object([
            // Real Chrome carries the user's authenticated browsing session.
            // A fresh install must expose no socket and accept no traffic.
            "enabled": .bool(false),
        ])
        policy["multimodalPolicy"] = .object([
            "screen_capture": .bool(false),
            "vision_api_calls": .bool(true),
            "file_ingestion_pdf": .bool(true),
            "file_ingestion_docx": .bool(true),
            "image_generation_openai": .bool(false),
            "tts_openai": .bool(false),
        ])
        policy["trainingPolicy"] = .object([
            "dream_scheduler": .bool(true),
            // Was never declared here, so every consumer invented its own
            // default for it and the Dreams page could disagree with the
            // runner. Declared, the normalized policy always carries it.
            "rem_cycle_enabled": .bool(true),
        ])
        policy["personalityPolicy"] = .object([
            // Second half of the composite dream gate (with
            // trainingPolicy.dream_scheduler). Undeclared until now — see the
            // rem_cycle_enabled note above.
            "dream_cycle_enabled": .bool(true),
            "runtime_v2": .bool(true),
            "confidence_calibration": .bool(false),
            "completion_guard_enabled": .bool(true),
            "completion_guard_max_repairs": .int(2),
        ])
        policy["memoryPolicy"] = .object([
            "consolidation_enabled": .bool(true),
            "cross_session_recall": .bool(true),
            "knowledge_graph_enabled": .bool(true),
            "adaptive_promotion": .bool(true),
            "hygiene_enabled": .bool(true),
            "vault_enabled": .bool(true),
            "vault_require_encryption": .bool(true),
        ])
        policy["skillBuilderPolicy"] = .object([
            "allow_ui_panels": .bool(true),
            "v2_enabled": .bool(true),
        ])
        policy["swarmPolicy"] = .object([
            "enabled": .bool(true),
            "maxAgents": .int(20),
            "maxParallel": .int(6),
            "storeReceipts": .bool(true),
        ])
        policy["inboxPolicy"] = .object(["enabled": .bool(true)])
        policy["mcpPolicy"] = .object(["allow_lifecycle_ops": .bool(false)])
        policy["macControlPolicy"] = .object([
            "enabled": .bool(false),
            "applescript_allowed": .bool(false),
            "jxa_allowed": .bool(false),
            "shortcuts_allowed": .bool(true),
            "accessibility_allowed": .bool(false),
            "system_control_allowed": .bool(false),
            "file_ops_allowed": .bool(false),
            "shell_allowed": .bool(false),
            "notifications_allowed": .bool(true),
            "spotlight_allowed": .bool(true),
            "approval_required_for": .array([
                .string("shell"), .string("file_ops"),
                .string("applescript"), .string("jxa"), .string("accessibility"),
            ]),
            "remote_from_ios_allowed": .bool(false),
            "riskGatePolicy": .object([
                "low": .string("auto"),
                "medium": .string("approve_each"),
                "high": .string("approve_each"),
                "critical": .string("approve_each"),
            ]),
        ])
        policy["securityPolicy"] = .object([
            "securityCenterEnabled": .bool(true),
            "capabilityPolicyEnabled": .bool(true),
            "originTrustEnabled": .bool(true),
            "signedRemoteCommandsRequired": .bool(true),
            "promptInjectionShieldEnabled": .bool(true),
            "dangerGatesEnabled": .bool(true),
            "rollbackByDefault": .bool(true),
            "secretFirewallEnabled": .bool(true),
            "toolSigningRequired": .bool(false),  // USER YOLO 2026-08-12
            "auditReceiptsEnabled": .bool(true),
            "allowAppNotifications": .bool(true),
            "killSwitchEnabled": .bool(false),
            "remoteHighRiskDefault": .string("block"),
            "criticalRequiresDeveloperMode": .bool(false),  // USER YOLO 2026-08-12
        ])
        policy["providerPolicy"] = .object([
            "active_per_surface": .object([
                "chat": .string("openai_oauth_direct"),
                "ios": .string("openai_oauth_direct"),
                "telegram": .string("openai_oauth_direct"),
                // Both spellings: the merge below is default-union-saved, so a
                // saved 0.3.x policy keyed `missions` keeps working while a
                // canonical reader finds `workshop` (P2-3).
                "workshop": .string("openai_oauth_direct"),
                "missions": .string("openai_oauth_direct"),
                "training": .string("openai_oauth_direct"),
                "dream": .string("openai_oauth_direct"),
                "autonomy": .string("openai_oauth_direct"),
            ]),
        ])
        return policy
    }
}
