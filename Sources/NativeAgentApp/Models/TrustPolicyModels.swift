import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct TrustWorkshopPolicy: Codable, Hashable {
    var allowBackgroundExecutions: Bool?
    var requireReceipts: Bool?
    var autoCreateWorkshopExecutionFromChat: Bool?
    // PATCH-2026-05-07: executions-b master gate for autonomous execution submission
    var enabled: Bool?
    var showTimeline: Bool?

    enum CodingKeys: String, CodingKey {
        case requireReceipts, enabled, showTimeline
        case allowBackgroundExecutions = "allowBackgroundMissions" // compatibility wire ID
        case autoCreateWorkshopExecutionFromChat = "autoCreateMissionFromChat" // compatibility wire ID
    }
}

// PATCH-2026-05-07: executions-b Self-test result model
struct WorkshopSelfTestResult: Codable, Hashable {
    var status: String
    var executionId: String
    var steps_executed: Int
    var timeline_events: Int
    var verified: Bool

    enum CodingKeys: String, CodingKey {
        case status, steps_executed, timeline_events, verified
        case executionId = "mission_id" // compatibility wire ID
    }
}

struct WorkshopActionResult: Codable, Hashable {
    var executionId: String?
    var status: String?
    var title: String?
    var plan_steps: Int?
    // Legacy path returns WorkshopExecutionRecord fields — partial decode is fine
    var id: String?
    var desk_handle: String? = nil
    var desk_alias: String? = nil

    enum CodingKeys: String, CodingKey {
        case status, title, plan_steps, id, desk_handle, desk_alias
        case executionId = "mission_id" // compatibility wire ID
    }
}

struct TriggerRecord: Identifiable, Codable, Hashable {
    var name: String
    var kind: String
    var enabled: Bool
    var objective: String
    var title: String
    var trust_required: String?
    var id: String { name }
}

struct TrustToolPolicy: Codable, Hashable {
    var autoPromoteSafeTools: Bool?
    var autoRunSafeTools: Bool?
    var riskyToolApproval: String?
}

struct TrustFilePolicy: Codable, Hashable {
    var allowedWorkspaceIds: [String]?
    var requireBackupBeforeWrite: Bool?
    var allowDestructiveActions: Bool?
    var outsideWorkspaceDefault: String?
}

struct TrustConnectorPolicy: Codable, Hashable {
    var defaultEnabled: Bool?
    var sendExternalMessagesRequiresApproval: Bool?
}

struct TrustMultimodalPolicy: Codable, Hashable {
    var screen_capture: Bool = false
    var vision_api_calls: Bool = true
    var file_ingestion_pdf: Bool = true
    var file_ingestion_docx: Bool = true
    var image_generation_openai: Bool = false
    var tts_openai: Bool = false

    init(
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen_capture = try c.decodeIfPresent(Bool.self, forKey: .screen_capture) ?? false
        vision_api_calls = try c.decodeIfPresent(Bool.self, forKey: .vision_api_calls) ?? true
        file_ingestion_pdf = try c.decodeIfPresent(Bool.self, forKey: .file_ingestion_pdf) ?? true
        file_ingestion_docx = try c.decodeIfPresent(Bool.self, forKey: .file_ingestion_docx) ?? true
        image_generation_openai = try c.decodeIfPresent(Bool.self, forKey: .image_generation_openai) ?? false
        tts_openai = try c.decodeIfPresent(Bool.self, forKey: .tts_openai) ?? false
    }
}

struct TrustPolicy: Codable, Hashable {
    var permissionLevel: String
    var autonomyDefault: String?
    var updatedAt: String?
    var appDataRoot: String?
    var workshopPolicy: TrustWorkshopPolicy?
    var toolPolicy: TrustToolPolicy?
    var filePolicy: TrustFilePolicy?
    var connectorPolicy: TrustConnectorPolicy?
    var multimodalPolicy: TrustMultimodalPolicy?
    var fullMacNeverExpires: Bool?
    var fullMacMaxDurationHours: Double?
    var fullMacExpiresAt: String?
    var fullMacConfirmedAt: String?
    // PATCH-2026-05-06: dev-mode bypass Auto false-negatives, Full Mac expiry, autonomy env var
    var developerMode: Bool = false
    var enableAutonomy: Bool = false
    // PATCH-2026-05-07: training-b1 ui Training-loop trust gates exposed to UI.
    var trainingPolicy: TrustTrainingPolicy?
    // PATCH-2026-05-07: self-improvement-ui Promotion engine trust gates.
    var promotionPolicy: TrustPromotionPolicy?
    // PATCH-2026-05-07: living-memory Trust gates for living memory system.
    var memoryPolicy: TrustMemoryPolicy?
    // PATCH-2026-05-07: mac-control-ui-1 Mac Control trust gates (20 endpoints, iOS remote gate).
    var macControlPolicy: TrustMacControlPolicy?

    enum CodingKeys: String, CodingKey {
        case permissionLevel, autonomyDefault, updatedAt, appDataRoot
        case workshopPolicy = "missionPolicy" // compatibility wire ID
        case toolPolicy, filePolicy, connectorPolicy, multimodalPolicy
        case fullMacNeverExpires, fullMacMaxDurationHours, fullMacExpiresAt, fullMacConfirmedAt
        case developerMode, enableAutonomy, trainingPolicy, promotionPolicy, memoryPolicy, macControlPolicy
    }

    /// Wave 4 (phase A) read-both: accept the FUTURE `workshopPolicy` spelling
    /// as well as the on-wire `missionPolicy` above. Decode-only — `encode(to:)`
    /// is still the synthesized one, so it emits `missionPolicy` and a 0.3.7 iOS
    /// install keeps decoding Mac snapshots byte-for-byte.
    private enum FutureCodingKeys: String, CodingKey {
        case workshopPolicy
    }

    init(
        permissionLevel: String = "balanced",
        autonomyDefault: String? = nil,
        updatedAt: String? = nil,
        appDataRoot: String? = nil,
        workshopPolicy: TrustWorkshopPolicy? = nil,
        toolPolicy: TrustToolPolicy? = nil,
        filePolicy: TrustFilePolicy? = nil,
        connectorPolicy: TrustConnectorPolicy? = nil,
        multimodalPolicy: TrustMultimodalPolicy? = nil,
        fullMacNeverExpires: Bool? = nil,
        fullMacMaxDurationHours: Double? = nil,
        fullMacExpiresAt: String? = nil,
        fullMacConfirmedAt: String? = nil,
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
        self.multimodalPolicy = multimodalPolicy
        self.fullMacNeverExpires = fullMacNeverExpires
        self.fullMacMaxDurationHours = fullMacMaxDurationHours
        self.fullMacExpiresAt = fullMacExpiresAt
        self.fullMacConfirmedAt = fullMacConfirmedAt
        self.developerMode = developerMode
        self.enableAutonomy = enableAutonomy
        self.trainingPolicy = trainingPolicy
        self.promotionPolicy = promotionPolicy
        self.memoryPolicy = memoryPolicy
        self.macControlPolicy = macControlPolicy
    }

    init(from decoder: Decoder) throws {
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
        multimodalPolicy = try c.decodeIfPresent(TrustMultimodalPolicy.self, forKey: .multimodalPolicy)
        fullMacNeverExpires = try c.decodeIfPresent(Bool.self, forKey: .fullMacNeverExpires)
        fullMacMaxDurationHours = try c.decodeIfPresent(Double.self, forKey: .fullMacMaxDurationHours)
        fullMacExpiresAt = try c.decodeIfPresent(String.self, forKey: .fullMacExpiresAt)
        fullMacConfirmedAt = try c.decodeIfPresent(String.self, forKey: .fullMacConfirmedAt)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        enableAutonomy = try c.decodeIfPresent(Bool.self, forKey: .enableAutonomy) ?? false
        trainingPolicy = try c.decodeIfPresent(TrustTrainingPolicy.self, forKey: .trainingPolicy)
        promotionPolicy = try c.decodeIfPresent(TrustPromotionPolicy.self, forKey: .promotionPolicy)
        memoryPolicy = try c.decodeIfPresent(TrustMemoryPolicy.self, forKey: .memoryPolicy)
        macControlPolicy = try c.decodeIfPresent(TrustMacControlPolicy.self, forKey: .macControlPolicy)
    }
}

// PATCH-2026-05-07: training-b1 ui Trust toggles for Beyond B.1 autonomous training loop.
struct TrustTrainingPolicy: Codable, Hashable {
    var autonomous_training: Bool = false
    var dream_scheduler: Bool = false
    // PATCH-2026-05-07: self-improvement-ui route proposals through promotion engine
    var route_through_promotion: Bool = false
    // PATCH-2026-05-29: dreams-tab weekly REM consolidation kill switch
    // (trainingPolicy.rem_cycle_enabled — the second gate for /v1/rem/run).
    // Daemon default is true; mirror that here so a policy that has never
    // written the key reads as enabled rather than silently off.
    var rem_cycle_enabled: Bool = true

    init(
        autonomous_training: Bool = false,
        dream_scheduler: Bool = false,
        route_through_promotion: Bool = false,
        rem_cycle_enabled: Bool = true
    ) {
        self.autonomous_training = autonomous_training
        self.dream_scheduler = dream_scheduler
        self.route_through_promotion = route_through_promotion
        self.rem_cycle_enabled = rem_cycle_enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autonomous_training = try c.decodeIfPresent(Bool.self, forKey: .autonomous_training) ?? false
        dream_scheduler = try c.decodeIfPresent(Bool.self, forKey: .dream_scheduler) ?? false
        route_through_promotion = try c.decodeIfPresent(Bool.self, forKey: .route_through_promotion) ?? false
        rem_cycle_enabled = try c.decodeIfPresent(Bool.self, forKey: .rem_cycle_enabled) ?? true
    }
}

// PATCH-2026-05-29: dreams-tab Decodable models for the dream/REM diary surface.
// Keys match the retired daemon exactly:
//   list_entries()/latest_entry() -> {date, filename, content, size, modified_at}
//   get_entry()                   -> {date, filename, content, size}  (no modified_at)
// The diary endpoint wraps entries in {"entries": [...], "enabled": <bool>} where
// `enabled` is the COMPOSITE dream gate (trainingPolicy.dream_scheduler AND
// personalityPolicy.dream_cycle_enabled), per /v1/dream/diary in the retired daemon.
