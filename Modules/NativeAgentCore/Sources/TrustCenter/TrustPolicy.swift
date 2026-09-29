import Foundation
import NativeAgentShared
import PersistenceCore

// MARK: - TrustPolicy

/// The saved trust policy (`trust/policy.json`) in typed form: the headline
/// scalars plus every surface block the app renders. Keys the model does not
/// name stay in the raw policy (`loadTrustPolicyChecked`), which remains the
/// authority; this is its typed read.
public struct TrustPolicy: Sendable, Codable, Hashable {
    public var permissionLevel: String
    public var autonomyDefault: String?
    public var updatedAt: String?
    public var appDataRoot: String?
    public var workshopPolicy: TrustWorkshopPolicy?
    public var toolPolicy: TrustToolPolicy?
    public var filePolicy: TrustFilePolicy?
    public var connectorPolicy: TrustConnectorPolicy?
    public var chromeControlPolicy: TrustChromeControlPolicy?
    public var multimodalPolicy: TrustMultimodalPolicy?
    // PATCH-2026-05-06: dev-mode bypass Auto false-negatives, autonomy env var
    public var developerMode: Bool = false
    public var enableAutonomy: Bool = false
    // PATCH-2026-05-07: training-b1 ui Training-loop trust gates exposed to UI.
    public var trainingPolicy: TrustTrainingPolicy?
    // PATCH-2026-05-07: self-improvement-ui Promotion engine trust gates.
    public var promotionPolicy: TrustPromotionPolicy?
    // PATCH-2026-05-07: living-memory Trust gates for living memory system.
    public var memoryPolicy: TrustMemoryPolicy?
    // PATCH-2026-05-07: mac-control-ui-1 Mac Control trust gates (20 endpoints, iOS remote gate).
    public var macControlPolicy: TrustMacControlPolicy?

    enum CodingKeys: String, CodingKey {
        case permissionLevel, autonomyDefault, updatedAt, appDataRoot
        case workshopPolicy = "missionPolicy" // compatibility wire ID
        case toolPolicy, filePolicy, connectorPolicy, chromeControlPolicy, multimodalPolicy
        case developerMode, enableAutonomy, trainingPolicy, promotionPolicy, memoryPolicy, macControlPolicy
    }

    /// Wave 4 (phase A) read-both: accept the FUTURE `workshopPolicy` spelling
    /// as well as the on-wire `missionPolicy` above. Decode-only — `encode(to:)`
    /// is still the synthesized one, so it emits `missionPolicy` and a 0.3.7 iOS
    /// install keeps decoding Mac snapshots byte-for-byte.
    private enum FutureCodingKeys: String, CodingKey {
        case workshopPolicy
    }

    public init(
        permissionLevel: String = "balanced",
        autonomyDefault: String? = nil,
        updatedAt: String? = nil,
        appDataRoot: String? = nil,
        workshopPolicy: TrustWorkshopPolicy? = nil,
        toolPolicy: TrustToolPolicy? = nil,
        filePolicy: TrustFilePolicy? = nil,
        connectorPolicy: TrustConnectorPolicy? = nil,
        chromeControlPolicy: TrustChromeControlPolicy? = nil,
        multimodalPolicy: TrustMultimodalPolicy? = nil,
        developerMode: Bool = false,
        enableAutonomy: Bool = false,
        trainingPolicy: TrustTrainingPolicy? = nil,
        promotionPolicy: TrustPromotionPolicy? = nil,
        memoryPolicy: TrustMemoryPolicy? = nil,
        macControlPolicy: TrustMacControlPolicy? = nil
    ) {
        self.permissionLevel = permissionLevel
        self.autonomyDefault = autonomyDefault
        self.updatedAt = updatedAt
        self.appDataRoot = appDataRoot
        self.workshopPolicy = workshopPolicy
        self.toolPolicy = toolPolicy
        self.filePolicy = filePolicy
        self.connectorPolicy = connectorPolicy
        self.chromeControlPolicy = chromeControlPolicy
        self.multimodalPolicy = multimodalPolicy
        self.developerMode = developerMode
        self.enableAutonomy = enableAutonomy
        self.trainingPolicy = trainingPolicy
        self.promotionPolicy = promotionPolicy
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
        toolPolicy = try c.decodeIfPresent(TrustToolPolicy.self, forKey: .toolPolicy)
        filePolicy = try c.decodeIfPresent(TrustFilePolicy.self, forKey: .filePolicy)
        connectorPolicy = try c.decodeIfPresent(TrustConnectorPolicy.self, forKey: .connectorPolicy)
        chromeControlPolicy = try c.decodeIfPresent(TrustChromeControlPolicy.self, forKey: .chromeControlPolicy)
        multimodalPolicy = try c.decodeIfPresent(TrustMultimodalPolicy.self, forKey: .multimodalPolicy)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        enableAutonomy = try c.decodeIfPresent(Bool.self, forKey: .enableAutonomy) ?? false
        trainingPolicy = try c.decodeIfPresent(TrustTrainingPolicy.self, forKey: .trainingPolicy)
        promotionPolicy = try c.decodeIfPresent(TrustPromotionPolicy.self, forKey: .promotionPolicy)
        memoryPolicy = try c.decodeIfPresent(TrustMemoryPolicy.self, forKey: .memoryPolicy)
        macControlPolicy = try c.decodeIfPresent(TrustMacControlPolicy.self, forKey: .macControlPolicy)
    }
}

// MARK: - Surface blocks

public struct TrustWorkshopPolicy: Sendable, Codable, Hashable {
    public var allowBackgroundExecutions: Bool?
    public var requireReceipts: Bool?
    public var autoCreateWorkshopExecutionFromChat: Bool?
    // PATCH-2026-05-07: executions-b master gate for autonomous execution submission
    public var enabled: Bool?
    public var showTimeline: Bool?

    enum CodingKeys: String, CodingKey {
        case requireReceipts, enabled, showTimeline
        case allowBackgroundExecutions = "allowBackgroundMissions" // compatibility wire ID
        case autoCreateWorkshopExecutionFromChat = "autoCreateMissionFromChat" // compatibility wire ID
    }

    public init(
        allowBackgroundExecutions: Bool? = nil,
        requireReceipts: Bool? = nil,
        autoCreateWorkshopExecutionFromChat: Bool? = nil,
        enabled: Bool? = nil,
        showTimeline: Bool? = nil
    ) {
        self.allowBackgroundExecutions = allowBackgroundExecutions
        self.requireReceipts = requireReceipts
        self.autoCreateWorkshopExecutionFromChat = autoCreateWorkshopExecutionFromChat
        self.enabled = enabled
        self.showTimeline = showTimeline
    }
}

public struct TrustToolPolicy: Sendable, Codable, Hashable {
    public var autoPromoteSafeTools: Bool?
    public var autoRunSafeTools: Bool?
    public var riskyToolApproval: String?

    public init(autoPromoteSafeTools: Bool? = nil, autoRunSafeTools: Bool? = nil, riskyToolApproval: String? = nil) {
        self.autoPromoteSafeTools = autoPromoteSafeTools
        self.autoRunSafeTools = autoRunSafeTools
        self.riskyToolApproval = riskyToolApproval
    }
}

public struct TrustFilePolicy: Sendable, Codable, Hashable {
    public var allowedWorkspaceIds: [String]?
    public var requireBackupBeforeWrite: Bool?
    public var allowDestructiveActions: Bool?
    public var outsideWorkspaceDefault: String?

    public init(
        allowedWorkspaceIds: [String]? = nil,
        requireBackupBeforeWrite: Bool? = nil,
        allowDestructiveActions: Bool? = nil,
        outsideWorkspaceDefault: String? = nil
    ) {
        self.allowedWorkspaceIds = allowedWorkspaceIds
        self.requireBackupBeforeWrite = requireBackupBeforeWrite
        self.allowDestructiveActions = allowDestructiveActions
        self.outsideWorkspaceDefault = outsideWorkspaceDefault
    }
}

public struct TrustConnectorPolicy: Sendable, Codable, Hashable {
    public var defaultEnabled: Bool?
    public var sendExternalMessagesRequiresApproval: Bool?

    public init(defaultEnabled: Bool? = nil, sendExternalMessagesRequiresApproval: Bool? = nil) {
        self.defaultEnabled = defaultEnabled
        self.sendExternalMessagesRequiresApproval = sendExternalMessagesRequiresApproval
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

// PATCH-2026-05-07: training-b1 ui Trust toggles for Beyond B.1 autonomous training loop.
public struct TrustTrainingPolicy: Sendable, Codable, Hashable {
    public var autonomous_training: Bool = false
    // TrustCenter+Defaults ships dream_scheduler TRUE; a policy that never
    // wrote the key must read as enabled, not silently off.
    public var dream_scheduler: Bool = true
    // PATCH-2026-05-07: self-improvement-ui route proposals through promotion engine
    public var route_through_promotion: Bool = false
    // PATCH-2026-05-29: dreams-tab weekly REM consolidation kill switch
    // (trainingPolicy.rem_cycle_enabled — the second gate for /v1/rem/run).
    // Daemon default is true; mirror that here so a policy that has never
    // written the key reads as enabled rather than silently off.
    public var rem_cycle_enabled: Bool = true

    public init(
        autonomous_training: Bool = false,
        dream_scheduler: Bool = true,
        route_through_promotion: Bool = false,
        rem_cycle_enabled: Bool = true
    ) {
        self.autonomous_training = autonomous_training
        self.dream_scheduler = dream_scheduler
        self.route_through_promotion = route_through_promotion
        self.rem_cycle_enabled = rem_cycle_enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autonomous_training = try c.decodeIfPresent(Bool.self, forKey: .autonomous_training) ?? false
        dream_scheduler = try c.decodeIfPresent(Bool.self, forKey: .dream_scheduler) ?? true
        route_through_promotion = try c.decodeIfPresent(Bool.self, forKey: .route_through_promotion) ?? false
        rem_cycle_enabled = try c.decodeIfPresent(Bool.self, forKey: .rem_cycle_enabled) ?? true
    }
}

// PATCH-2026-05-07: self-improvement-ui Beyond B.1/B.3 — training + promotion models
public struct TrustPromotionPolicy: Sendable, Codable, Hashable {
    public var enabled: Bool = false
    public var auto_promote_tier_a: Bool = false
    public var run_smoke_in_harness: Bool = true

    public init(enabled: Bool = false, auto_promote_tier_a: Bool = false, run_smoke_in_harness: Bool = true) {
        self.enabled = enabled
        self.auto_promote_tier_a = auto_promote_tier_a
        self.run_smoke_in_harness = run_smoke_in_harness
    }
}

// PATCH-2026-05-07: living-memory Trust gates for living memory system
public struct TrustMemoryPolicy: Sendable, Codable, Hashable {
    public var consolidation_enabled: Bool = false
    public var cross_session_recall: Bool = true
    public var auto_promote_consolidated: Bool = false
    public var knowledge_graph_enabled: Bool = true
    public var adaptive_promotion: Bool = false
    public var hygiene_enabled: Bool = true
    public var hygiene_interval_hours: Double = 6
    public var archive_noisy_reflections: Bool = true
    public var reject_low_value_proposals: Bool = true

    public init(
        consolidation_enabled: Bool = false,
        cross_session_recall: Bool = true,
        auto_promote_consolidated: Bool = false,
        knowledge_graph_enabled: Bool = true,
        adaptive_promotion: Bool = false,
        hygiene_enabled: Bool = true,
        hygiene_interval_hours: Double = 6,
        archive_noisy_reflections: Bool = true,
        reject_low_value_proposals: Bool = true
    ) {
        self.consolidation_enabled = consolidation_enabled
        self.cross_session_recall = cross_session_recall
        self.auto_promote_consolidated = auto_promote_consolidated
        self.knowledge_graph_enabled = knowledge_graph_enabled
        self.adaptive_promotion = adaptive_promotion
        self.hygiene_enabled = hygiene_enabled
        self.hygiene_interval_hours = hygiene_interval_hours
        self.archive_noisy_reflections = archive_noisy_reflections
        self.reject_low_value_proposals = reject_low_value_proposals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consolidation_enabled = try c.decodeIfPresent(Bool.self, forKey: .consolidation_enabled) ?? false
        cross_session_recall = try c.decodeIfPresent(Bool.self, forKey: .cross_session_recall) ?? true
        auto_promote_consolidated = try c.decodeIfPresent(Bool.self, forKey: .auto_promote_consolidated) ?? false
        knowledge_graph_enabled = try c.decodeIfPresent(Bool.self, forKey: .knowledge_graph_enabled) ?? true
        adaptive_promotion = try c.decodeIfPresent(Bool.self, forKey: .adaptive_promotion) ?? false
        hygiene_enabled = try c.decodeIfPresent(Bool.self, forKey: .hygiene_enabled) ?? true
        hygiene_interval_hours = try c.decodeIfPresent(Double.self, forKey: .hygiene_interval_hours) ?? 6
        archive_noisy_reflections = try c.decodeIfPresent(Bool.self, forKey: .archive_noisy_reflections) ?? true
        reject_low_value_proposals = try c.decodeIfPresent(Bool.self, forKey: .reject_low_value_proposals) ?? true
    }
}

// Codable mirror of the daemon's macControlPolicy block in trust_policy()
public struct TrustMacControlPolicy: Sendable, Codable, Hashable {
    public var enabled: Bool = false
    public var applesScriptAllowed: Bool = false
    public var jxaAllowed: Bool = false
    public var shortcutsAllowed: Bool = true
    public var accessibilityAllowed: Bool = false
    public var systemControlAllowed: Bool = false
    public var fileOpsAllowed: Bool = false
    public var shellAllowed: Bool = false
    public var notificationsAllowed: Bool = true
    public var spotlightAllowed: Bool = true
    public var approvalRequiredFor: [String] = ["shell", "file_ops", "applescript", "jxa", "accessibility"]
    public var remoteFromIosAllowed: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled
        case applesScriptAllowed = "applescript_allowed"
        case jxaAllowed = "jxa_allowed"
        case shortcutsAllowed = "shortcuts_allowed"
        case accessibilityAllowed = "accessibility_allowed"
        case systemControlAllowed = "system_control_allowed"
        case fileOpsAllowed = "file_ops_allowed"
        case shellAllowed = "shell_allowed"
        case notificationsAllowed = "notifications_allowed"
        case spotlightAllowed = "spotlight_allowed"
        case approvalRequiredFor = "approval_required_for"
        case remoteFromIosAllowed = "remote_from_ios_allowed"
    }

    public init(
        enabled: Bool = false,
        applesScriptAllowed: Bool = false,
        jxaAllowed: Bool = false,
        shortcutsAllowed: Bool = true,
        accessibilityAllowed: Bool = false,
        systemControlAllowed: Bool = false,
        fileOpsAllowed: Bool = false,
        shellAllowed: Bool = false,
        notificationsAllowed: Bool = true,
        spotlightAllowed: Bool = true,
        approvalRequiredFor: [String] = ["shell", "file_ops", "applescript", "jxa", "accessibility"],
        remoteFromIosAllowed: Bool = false
    ) {
        self.enabled = enabled
        self.applesScriptAllowed = applesScriptAllowed
        self.jxaAllowed = jxaAllowed
        self.shortcutsAllowed = shortcutsAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.systemControlAllowed = systemControlAllowed
        self.fileOpsAllowed = fileOpsAllowed
        self.shellAllowed = shellAllowed
        self.notificationsAllowed = notificationsAllowed
        self.spotlightAllowed = spotlightAllowed
        self.approvalRequiredFor = approvalRequiredFor
        self.remoteFromIosAllowed = remoteFromIosAllowed
    }

    public init(from decoder: Decoder) throws {
        let snapshot = try MacControlPolicyWireSnapshot(from: decoder)
        enabled = snapshot.enabled
        applesScriptAllowed = snapshot.applesScriptAllowed
        jxaAllowed = snapshot.jxaAllowed
        shortcutsAllowed = snapshot.shortcutsAllowed
        accessibilityAllowed = snapshot.accessibilityAllowed
        systemControlAllowed = snapshot.systemControlAllowed
        fileOpsAllowed = snapshot.fileOpsAllowed
        shellAllowed = snapshot.shellAllowed
        notificationsAllowed = snapshot.notificationsAllowed
        spotlightAllowed = snapshot.spotlightAllowed
        approvalRequiredFor = snapshot.approvalRequiredFor
        remoteFromIosAllowed = snapshot.remoteFromIosAllowed
    }
}
