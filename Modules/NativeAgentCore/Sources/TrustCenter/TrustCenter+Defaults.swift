import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter+Defaults.swift` | Canonical scalar defaults shared with typed and phone reads. |

extension SwiftNativeTrustCenter {
    /// Saved values merge over this canonical shape so readers share defaults.
    public nonisolated func defaultTrustPolicy() -> [String: JSONValue] {
        var policy: [String: JSONValue] = [:]
        policy["permissionLevel"] = .string("balanced")
        // Access-mode display/preset projection; PermissionLaw decides each call.
        policy["autonomyDefault"] = .string("supervised")
        // Autonomy additions apply only to proven fresh installs; putting them in the merge base would grant existing policies.
        // updatedAt belongs to a saved policy. An absent source date stays absent on every read.
        policy["appDataRoot"] = .string(dataRoot.path)
        policy["filePolicy"] = .object([
            "workspaceRoots": .array(TrustCenterDefaultWorkspaceRoots.defaultRootPaths(dataRoot: dataRoot).map { .string($0) }),
            "requireBackupBeforeWrite": .bool(true),
            "outsideWorkspaceDefault": .string("deny"),
        ])
        policy["chromeControlPolicy"] = .object([
            // Real Chrome carries the user's authenticated browsing session. A fresh install must expose no socket and accept no traffic.
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
            // Shared normalization keeps every dream reader on the same REM gate.
            "rem_cycle_enabled": .bool(true),
        ])
        policy["personalityPolicy"] = .object([
            // REM also requires the scheduler gate.
            "dream_cycle_enabled": .bool(true),
        ])
        policy["memoryPolicy"] = .object([
            "cross_session_recall": .bool(true),
            "knowledge_graph_enabled": .bool(true),
            "adaptive_promotion": .bool(TrustMemoryPolicy.adaptivePromotionDefault),
            "vault_enabled": .bool(true),
            "vault_require_encryption": .bool(true),
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
