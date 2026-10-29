import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter+Defaults.swift` | Canonical Trust/Mac schema, using immutable MacControlPolicyWireSnapshot scalar defaults shared with typed and phone reads |

extension SwiftNativeTrustCenter {
    /// Default trust policy for the Swift runtime. Saved policy values are
    /// merged over this shape by `loadTrustPolicy()`.
    public nonisolated func defaultTrustPolicy() -> [String: JSONValue] {
        var policy: [String: JSONValue] = [:]
        policy["permissionLevel"] = .string("balanced")
        // Access-mode display/preset projection; PermissionLaw decides each call.
        policy["autonomyDefault"] = .string("supervised")
        // `enableAutonomy` is deliberately NOT here. This shape is the merge
        // base for EVERY saved policy, so a default true would silently grant
        // unattended work to an older strict policy that predates the key.
        // The fresh-install grant lives in `freshInstallTrustPolicyAdditions`,
        // applied when the file is absent or contains an empty object.
        // Read-time default when absent on disk; patching does not stamp edits.
        policy["updatedAt"] = .string(Self.isoTimestamp(clock()))
        policy["appDataRoot"] = .string(dataRoot.path)
        // Readers accept both Workshop spellings; writers retain missionPolicy.
        policy[WorkshopPolicyBlockVocabulary.wireKey] = .object([
            "enabled": .bool(true),
        ])
        policy["filePolicy"] = .object([
            "workspaceRoots": .array(TrustCenterDefaultWorkspaceRoots.defaultRootPaths(dataRoot: dataRoot).map { .string($0) }),
            "requireBackupBeforeWrite": .bool(true),
            "outsideWorkspaceDefault": .string("deny"),
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
            // Normalization gives every dream reader the same REM gate.
            "rem_cycle_enabled": .bool(true),
        ])
        policy["personalityPolicy"] = .object([
            // Second half of the dream gate with trainingPolicy.dream_scheduler.
            "dream_cycle_enabled": .bool(true),
        ])
        policy["memoryPolicy"] = .object([
            "cross_session_recall": .bool(true),
            "knowledge_graph_enabled": .bool(true),
            "adaptive_promotion": .bool(true),
            "vault_enabled": .bool(true),
            "vault_require_encryption": .bool(true),
        ])
        policy["swarmPolicy"] = .object([
            "enabled": .bool(true),
            "maxAgents": .int(20),
            "maxParallel": .int(6),
            "storeReceipts": .bool(true),
        ])
        policy["inboxPolicy"] = .object(["enabled": .bool(true)])
        policy["macControlPolicy"] = .object(Self.defaultMacControlPolicy)
        policy["securityPolicy"] = .object([
            "signedRemoteCommandsRequired": .bool(true),
            "auditReceiptsEnabled": .bool(true),
            "allowAppNotifications": .bool(true),
            "killSwitchEnabled": .bool(false),
        ])
        return policy
    }

    /// Canonical Mac schema; scalar defaults are shared with phone decoding.
    nonisolated static var defaultMacControlPolicy: [String: JSONValue] {
        MacControlPolicyWireSnapshot().wireValue.mapValues { JSONValue(fromFoundation: $0) }
    }
}
