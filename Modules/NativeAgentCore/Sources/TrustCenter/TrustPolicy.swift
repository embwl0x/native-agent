import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `TrustPolicy.swift` | Typed UI subset, not full authority: security/provider/personality/iOS-remote blocks remain in the raw checked policy sent to the phone |

// MARK: - TrustPolicy

/// Typed UI subset of `trust/policy.json`. Security, provider, personality and
/// iOS-remote blocks remain in the raw checked dictionary, the full authority
/// also sent to the phone; encoding this subset cannot replace it.
public struct TrustPolicy: Sendable, Codable, Hashable {
    public var permissionLevel: String
    public var autonomyDefault: String?
    public var updatedAt: String?
    public var appDataRoot: String?
    public var workshopPolicy: TrustWorkshopPolicy?
    public var filePolicy: TrustFilePolicy?
    public var chromeControlPolicy: TrustChromeControlPolicy?
    public var multimodalPolicy: TrustMultimodalPolicy?
    public var developerMode: Bool = false
    public var enableAutonomy: Bool = false
    // Persisted trainingPolicy retains the dream and REM gates.
    public var trainingPolicy: TrustTrainingPolicy?
    public var memoryPolicy: TrustMemoryPolicy?
    public var macControlPolicy: MacControlPolicyWireSnapshot?

    enum CodingKeys: String, CodingKey {
        case permissionLevel, autonomyDefault, updatedAt, appDataRoot
        case workshopPolicy = "missionPolicy" // compatibility wire ID
        case filePolicy, chromeControlPolicy, multimodalPolicy
        case developerMode, enableAutonomy, trainingPolicy, memoryPolicy, macControlPolicy
    }

    /// Decoding accepts workshopPolicy and missionPolicy; encoding emits only missionPolicy.
    private enum FutureCodingKeys: String, CodingKey {
        case workshopPolicy
    }

    public init(
        permissionLevel: String = "balanced",
        autonomyDefault: String? = nil,
        updatedAt: String? = nil,
        appDataRoot: String? = nil,
        workshopPolicy: TrustWorkshopPolicy? = nil,
        filePolicy: TrustFilePolicy? = nil,
        chromeControlPolicy: TrustChromeControlPolicy? = nil,
        multimodalPolicy: TrustMultimodalPolicy? = nil,
        developerMode: Bool = false,
        enableAutonomy: Bool = false,
        trainingPolicy: TrustTrainingPolicy? = nil,
        memoryPolicy: TrustMemoryPolicy? = nil,
        macControlPolicy: MacControlPolicyWireSnapshot? = nil
    ) {
        self.permissionLevel = permissionLevel
        self.autonomyDefault = autonomyDefault
        self.updatedAt = updatedAt
        self.appDataRoot = appDataRoot
        self.workshopPolicy = workshopPolicy
        self.filePolicy = filePolicy
        self.chromeControlPolicy = chromeControlPolicy
        self.multimodalPolicy = multimodalPolicy
        self.developerMode = developerMode
        self.enableAutonomy = enableAutonomy
        self.trainingPolicy = trainingPolicy
        self.memoryPolicy = memoryPolicy
        self.macControlPolicy = macControlPolicy
    }

    /// The typed read of one raw policy generation (a checked load or the
    /// generation a patch just wrote).
    public init(policyObject: [String: JSONValue]) throws {
        let data = try JSONValue.object(policyObject).serializedData(pretty: false)
        self = try JSONDecoder().decode(TrustPolicy.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissionLevel = try c.decodeIfPresent(String.self, forKey: .permissionLevel) ?? "balanced"
        autonomyDefault = try c.decodeIfPresent(String.self, forKey: .autonomyDefault)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        appDataRoot = try c.decodeIfPresent(String.self, forKey: .appDataRoot)
        // Future spelling first, on-wire spelling as the fallback.
        let futureWorkshopPolicy: TrustWorkshopPolicy? = {
            guard let future = try? decoder.container(keyedBy: FutureCodingKeys.self) else {
                return nil
            }
            return try? future.decodeIfPresent(TrustWorkshopPolicy.self, forKey: .workshopPolicy)
        }()
        workshopPolicy = try futureWorkshopPolicy
            ?? c.decodeIfPresent(TrustWorkshopPolicy.self, forKey: .workshopPolicy)
        filePolicy = try c.decodeIfPresent(TrustFilePolicy.self, forKey: .filePolicy)
        chromeControlPolicy = try c.decodeIfPresent(TrustChromeControlPolicy.self, forKey: .chromeControlPolicy)
        multimodalPolicy = try c.decodeIfPresent(TrustMultimodalPolicy.self, forKey: .multimodalPolicy)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        enableAutonomy = try c.decodeIfPresent(Bool.self, forKey: .enableAutonomy) ?? false
        trainingPolicy = try c.decodeIfPresent(TrustTrainingPolicy.self, forKey: .trainingPolicy)
        memoryPolicy = try c.decodeIfPresent(TrustMemoryPolicy.self, forKey: .memoryPolicy)
        macControlPolicy = try c.decodeIfPresent(MacControlPolicyWireSnapshot.self, forKey: .macControlPolicy)
    }
}

// MARK: - Surface blocks

public struct TrustFilePolicy: Sendable, Codable, Hashable {
    public var requireBackupBeforeWrite: Bool?
    public var outsideWorkspaceDefault: String?

    public init(
        requireBackupBeforeWrite: Bool? = nil,
        outsideWorkspaceDefault: String? = nil
    ) {
        self.requireBackupBeforeWrite = requireBackupBeforeWrite
        self.outsideWorkspaceDefault = outsideWorkspaceDefault
    }
}

public struct TrustChromeControlPolicy: Sendable, Codable, Hashable {
    public var enabled: Bool = false

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

public struct TrustMultimodalPolicy: Sendable, Codable, Hashable {
    public var screen_capture: Bool = false
    public var vision_api_calls: Bool = true
    public var file_ingestion_pdf: Bool = true
    public var file_ingestion_docx: Bool = true
    public var image_generation_openai: Bool = false
    public var tts_openai: Bool = false

    public init(
        screen_capture: Bool = false,
        vision_api_calls: Bool = true,
        file_ingestion_pdf: Bool = true,
        file_ingestion_docx: Bool = true,
        image_generation_openai: Bool = false,
        tts_openai: Bool = false
    ) {
        self.screen_capture = screen_capture
        self.vision_api_calls = vision_api_calls
        self.file_ingestion_pdf = file_ingestion_pdf
        self.file_ingestion_docx = file_ingestion_docx
        self.image_generation_openai = image_generation_openai
        self.tts_openai = tts_openai
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen_capture = try c.decodeIfPresent(Bool.self, forKey: .screen_capture) ?? false
        vision_api_calls = try c.decodeIfPresent(Bool.self, forKey: .vision_api_calls) ?? true
        file_ingestion_pdf = try c.decodeIfPresent(Bool.self, forKey: .file_ingestion_pdf) ?? true
        file_ingestion_docx = try c.decodeIfPresent(Bool.self, forKey: .file_ingestion_docx) ?? true
        image_generation_openai = try c.decodeIfPresent(Bool.self, forKey: .image_generation_openai) ?? false
        tts_openai = try c.decodeIfPresent(Bool.self, forKey: .tts_openai) ?? false
    }
}

// Dream and REM gates retain their persisted trainingPolicy block.
public struct TrustTrainingPolicy: Sendable, Codable, Hashable {
    // TrustCenter+Defaults ships dream_scheduler TRUE; a policy that never
    // wrote the key must read as enabled, not silently off.
    public var dream_scheduler: Bool = true
    // REM is enabled when the saved policy omits this key.
    public var rem_cycle_enabled: Bool = true

    public init(
        dream_scheduler: Bool = true,
        rem_cycle_enabled: Bool = true
    ) {
        self.dream_scheduler = dream_scheduler
        self.rem_cycle_enabled = rem_cycle_enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dream_scheduler = try c.decodeIfPresent(Bool.self, forKey: .dream_scheduler) ?? true
        rem_cycle_enabled = try c.decodeIfPresent(Bool.self, forKey: .rem_cycle_enabled) ?? true
    }
}

public struct TrustMemoryPolicy: Sendable, Codable, Hashable {
    public var cross_session_recall: Bool = true
    public var knowledge_graph_enabled: Bool = true
    public var adaptive_promotion: Bool = false

    public init(
        cross_session_recall: Bool = true,
        knowledge_graph_enabled: Bool = true,
        adaptive_promotion: Bool = false
    ) {
        self.cross_session_recall = cross_session_recall
        self.knowledge_graph_enabled = knowledge_graph_enabled
        self.adaptive_promotion = adaptive_promotion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cross_session_recall = try c.decodeIfPresent(Bool.self, forKey: .cross_session_recall) ?? true
        knowledge_graph_enabled = try c.decodeIfPresent(Bool.self, forKey: .knowledge_graph_enabled) ?? true
        adaptive_promotion = try c.decodeIfPresent(Bool.self, forKey: .adaptive_promotion) ?? false
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
