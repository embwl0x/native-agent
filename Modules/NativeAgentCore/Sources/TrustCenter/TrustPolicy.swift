import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `TrustPolicy.swift` | UI subset cannot replace raw checked authority. |

// MARK: - TrustPolicy

/// This UI subset cannot replace raw authority, whose additional blocks also reach the phone.
public struct TrustPolicy: Sendable, Codable, Hashable {
    public var permissionLevel: String
    public var autonomyDefault: String?
    public var updatedAt: String?
    public var appDataRoot: String?
    public var filePolicy: TrustFilePolicy?
    public var chromeControlPolicy: TrustChromeControlPolicy?
    public var multimodalPolicy: TrustMultimodalPolicy?
    public var developerMode: Bool = false
    public var enableAutonomy: Bool = false
    public var trainingPolicy: TrustTrainingPolicy?
    public var memoryPolicy: TrustMemoryPolicy?
    public var macControlPolicy: MacControlPolicyWireSnapshot?

    enum CodingKeys: String, CodingKey {
        case permissionLevel, autonomyDefault, updatedAt, appDataRoot
        case filePolicy, chromeControlPolicy, multimodalPolicy
        case developerMode, enableAutonomy, trainingPolicy, memoryPolicy, macControlPolicy
    }

    public init(
        permissionLevel: String = "balanced",
        autonomyDefault: String? = nil,
        updatedAt: String? = nil,
        appDataRoot: String? = nil,
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
        self.filePolicy = filePolicy
        self.chromeControlPolicy = chromeControlPolicy
        self.multimodalPolicy = multimodalPolicy
        self.developerMode = developerMode
        self.enableAutonomy = enableAutonomy
        self.trainingPolicy = trainingPolicy
        self.memoryPolicy = memoryPolicy
        self.macControlPolicy = macControlPolicy
    }

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

// Missing dream and REM fields must use the canonical enabled defaults rather than silently disabling their gates.
public struct TrustTrainingPolicy: Sendable, Codable, Hashable {
    public var dream_scheduler: Bool = true
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
    public static let adaptivePromotionDefault = true
    public var cross_session_recall: Bool = true
    public var knowledge_graph_enabled: Bool = true
    public var adaptive_promotion: Bool

    public init(
        cross_session_recall: Bool = true,
        knowledge_graph_enabled: Bool = true,
        adaptive_promotion: Bool = TrustMemoryPolicy.adaptivePromotionDefault
    ) {
        self.cross_session_recall = cross_session_recall
        self.knowledge_graph_enabled = knowledge_graph_enabled
        self.adaptive_promotion = adaptive_promotion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cross_session_recall = try c.decodeIfPresent(Bool.self, forKey: .cross_session_recall) ?? true
        knowledge_graph_enabled = try c.decodeIfPresent(Bool.self, forKey: .knowledge_graph_enabled) ?? true
        adaptive_promotion = try c.decodeIfPresent(Bool.self, forKey: .adaptive_promotion) ?? Self.adaptivePromotionDefault
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
