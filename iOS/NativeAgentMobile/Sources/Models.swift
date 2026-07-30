// iOS/NativeAgentMobile/Sources/Models.swift
// Structs that were mirrored from macOS Models.swift and are byte-identical
// have been extracted to NativeAgentShared. This file retains iOS-specific
// structs and those with divergent shapes from the Mac side.
import Foundation
import NativeAgentShared

// MARK: - iOS-local models (not shared — different shape from Mac side)

struct WorkshopTaskRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var objective: String
    var status: String
    var phase: String
    var priority: String?
    var autonomyLevel: String?
    var permissionProfile: String?
    var summary: String?
    var createdAt: String
    var updatedAt: String?
    var completedAt: String?
    var receiptCount: Int?
    var currentStepId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, objective, status, phase, priority
        case autonomyLevel, permissionProfile, summary
        case createdAt, updatedAt, completedAt, receiptCount, currentStepId
        case autonomy_level, permission_profile, receipt_count
        case created_at, updated_at, completed_at, current_step_id
    }

    init(
        id: String,
        title: String,
        objective: String,
        status: String,
        phase: String,
        priority: String? = nil,
        autonomyLevel: String? = nil,
        permissionProfile: String? = nil,
        summary: String? = nil,
        createdAt: String,
        updatedAt: String? = nil,
        completedAt: String? = nil,
        receiptCount: Int? = nil,
        currentStepId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.status = status
        self.phase = phase
        self.priority = priority
        self.autonomyLevel = autonomyLevel
        self.permissionProfile = permissionProfile
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.receiptCount = receiptCount
        self.currentStepId = currentStepId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        objective = try c.decodeIfPresent(String.self, forKey: .objective) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? status
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        autonomyLevel = try c.decodeIfPresent(String.self, forKey: .autonomyLevel)
            ?? c.decodeIfPresent(String.self, forKey: .autonomy_level)
        permissionProfile = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
            ?? c.decodeIfPresent(String.self, forKey: .permission_profile)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .created_at)
            ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updated_at)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
            ?? c.decodeIfPresent(String.self, forKey: .completed_at)
        receiptCount = try c.decodeIfPresent(Int.self, forKey: .receiptCount)
            ?? c.decodeIfPresent(Int.self, forKey: .receipt_count)
        currentStepId = try c.decodeIfPresent(String.self, forKey: .currentStepId)
            ?? c.decodeIfPresent(String.self, forKey: .current_step_id)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(objective, forKey: .objective)
        try c.encode(status, forKey: .status)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(autonomyLevel, forKey: .autonomyLevel)
        try c.encodeIfPresent(permissionProfile, forKey: .permissionProfile)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(receiptCount, forKey: .receiptCount)
        try c.encodeIfPresent(currentStepId, forKey: .currentStepId)
    }
}

// Command-summary count and policy models live in NativeAgentShared.

// MultimodalAttachment, ChatSession, RuntimeHealth, RunRecord, MemoryRecord,
// PersonalityTraits, PersonalityProfile, PersonalityDoc moved to NativeAgentShared.

struct OrganismLivingStatusFile: Codable, Hashable, Sendable {
    var generatedAt: Date
    var enabled: Bool
    var posture: String
    var bodyLine: String?
    var behaviorLine: String
    var needsUser: Bool
    var needsAttention: Bool?
    var signalCount: Int
    var lastSignalAt: Date?
    var body: OrganismLivingBodyFile
    var counters: OrganismLivingCountersFile
    var reflexCandidates: [OrganismLivingReflexCandidateFile]?
    var standingViewProposals: [OrganismLivingStandingViewProposalFile]?
}

struct OrganismLivingBodyFile: Codable, Hashable, Sendable {
    var macAwake: Bool
    var iPhoneReachable: Bool
    var providersHealthy: Bool
    var memoryHealthy: Bool
    var dreamHealthy: Bool
    var toolHandsAvailable: Bool
    var approvalChannelsOpen: Bool
    var notificationPathHealthy: Bool
    var resourcePressure: String
}

struct OrganismLivingCountersFile: Codable, Hashable, Sendable {
    var fieldNodes: Int
    var pendingPredictions: Int
    var dreamRepairs: Int
    var reflexCandidates: Int
    var reflexesNeedReview: Int
    var approvedReflexBiases: Int?
    var standingViewProposals: Int?
}

struct OrganismLivingReflexCandidateFile: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var pattern: String
    var trustClass: String
    var confidence: Double
    var reviewRequired: Bool
    var autoActivationAllowed: Bool
    var approvedAt: Date?
}

struct OrganismLivingStandingViewProposalFile: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var rationale: String
    var evidenceIDs: [String]
    var reviewRequired: Bool
}

// Note: iOS ChatView.swift defines its own local ChatMessage for display; this Codable version
// is used for the iCloud snapshot transport layer.
struct ChatMessageRecord: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var sessionId: String? = nil
    var role: String
    var content: String
    var createdAt: String = ISO8601DateFormatter().string(from: Date())
    var runId: String? = nil
    var source: String? = nil
    // eval3/T3: Mac encodes attachment summaries under metadata.attachments
    // (see Sources/NativeAgentApp/Models.swift ChatMessageMetadata). iOS
    // reads them back so refreshChatHistory rebuilds messages with their
    // attachments instead of dropping them on reload.
    var metadata: ChatMessageRecordMetadata? = nil
}

struct ChatMessageRecordMetadata: Codable, Hashable {
    var attachments: [PersistedAttachmentRecord]? = nil
}

struct PersistedAttachmentRecord: Codable, Hashable {
    var id: String
    var type: String
    var mime: String?
    var name: String?
    var byteSize: Int64?
    var path: String?
}

struct ChatTranscriptSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: String { sessionId }
    var sessionId: String
    var messages: [ChatMessageRecord]
}

// MARK: - Turn Inspector W4 — iOS decode-side summary models
//
// The Mac writes `turn_summaries.json` (content-free per-turn summaries) into
// the iCloud snapshot dir. iOS cannot import the Mac app target, so it carries
// its own lenient decode struct here — same convention as every other snapshot
// section (WorkshopTaskRecord etc.). Field names match the Mac `TurnSummaryRecord` /
// `TurnSummaryFile` exactly; dates decode via the loaders' `.iso8601` strategy.
struct TurnSummaryRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String              // turnId
    var surface: String?
    var sessionId: String?
    var startedAt: Date
    var lastAt: Date
    var eventCount: Int
    var wallMs: Int
    var llmTokens: Int?
    var ttftMs: Int?
    var kinds: [String: Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        surface = try c.decodeIfPresent(String.self, forKey: .surface)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        lastAt = try c.decode(Date.self, forKey: .lastAt)
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        wallMs = try c.decodeIfPresent(Int.self, forKey: .wallMs) ?? 0
        llmTokens = try c.decodeIfPresent(Int.self, forKey: .llmTokens)
        ttftMs = try c.decodeIfPresent(Int.self, forKey: .ttftMs)
        kinds = try c.decodeIfPresent([String: Int].self, forKey: .kinds) ?? [:]
    }
}

struct TurnSummaryFile: Codable, Hashable, Sendable {
    var summaries: [TurnSummaryRecord]
    var truncated: Bool
    var totalTurnsSeen: Int
    var generatedAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summaries = try c.decodeIfPresent([TurnSummaryRecord].self, forKey: .summaries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        totalTurnsSeen = try c.decodeIfPresent(Int.self, forKey: .totalTurnsSeen) ?? summaries.count
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }
}

struct SkillRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var status: String
    var kind: String?
    var description: String?
    var triggers: [String]?
    var riskClass: String?
    var autoload: Bool?
    var useCount: Int?
    var updatedAt: String?
}

struct ToolRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String?
    var status: String?
    var description: String?
    var autoRun: Bool?
    var riskClass: String?
    var updatedAt: String?
}

struct TrustWorkshopPolicy: Codable, Hashable, Sendable {
    var enabled: Bool?
    var showTimeline: Bool?
}

struct TrustToolPolicy: Codable, Hashable, Sendable {
    var autoRunRiskClasses: [String]?
}

struct TrustFilePolicy: Codable, Hashable, Sendable {
    var allowedWorkspaceIds: [String]?
    var allowedPaths: [String]?
    var requireBackupBeforeWrite: Bool?
    var allowDestructiveActions: Bool?
    var outsideWorkspaceDefault: String?
}

struct TrustConnectorPolicy: Codable, Hashable, Sendable {
    var enabledConnectors: [String]?
}

struct TrustProviderPolicy: Codable, Hashable, Sendable {
    var activePerSurface: [String: String]?

    enum CodingKeys: String, CodingKey {
        case activePerSurface = "active_per_surface"
    }
}

struct TrustTrainingPolicy: Codable, Hashable, Sendable {
    var autonomousTraining: Bool?
    var dreamScheduler: Bool?

    enum CodingKeys: String, CodingKey {
        case autonomousTraining
        case dreamScheduler
        case autonomous_training
        case dream_scheduler
    }

    init(autonomousTraining: Bool? = nil, dreamScheduler: Bool? = nil) {
        self.autonomousTraining = autonomousTraining
        self.dreamScheduler = dreamScheduler
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autonomousTraining = try c.decodeIfPresent(Bool.self, forKey: .autonomousTraining)
            ?? c.decodeIfPresent(Bool.self, forKey: .autonomous_training)
        dreamScheduler = try c.decodeIfPresent(Bool.self, forKey: .dreamScheduler)
            ?? c.decodeIfPresent(Bool.self, forKey: .dream_scheduler)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(autonomousTraining, forKey: .autonomousTraining)
        try c.encodeIfPresent(dreamScheduler, forKey: .dreamScheduler)
    }
}

struct TrustPolicy: Codable, Hashable, Sendable {
    var permissionLevel: String?
    var autonomyDefault: String?
    var requireBackups: Bool?
    var outsideDefault: String?
    var developerMode: Bool?
    var workshopPolicy: TrustWorkshopPolicy?
    var toolPolicy: TrustToolPolicy?
    var filePolicy: TrustFilePolicy?
    var connectorPolicy: TrustConnectorPolicy?
    var providerPolicy: TrustProviderPolicy?
    var trainingPolicy: TrustTrainingPolicy?
    var updatedAt: String?
    // PATCH-2026-05-07: mac-control-ui-1 Mirror Mac Control policy
    var macControlPolicy: TrustMacControlPolicy?

    enum CodingKeys: String, CodingKey {
        case permissionLevel, autonomyDefault, requireBackups, outsideDefault, developerMode
        case workshopPolicy = "missionPolicy" // compatibility wire ID
        case toolPolicy, filePolicy, connectorPolicy, providerPolicy, trainingPolicy, updatedAt, macControlPolicy
    }

    var effectiveRequireBackups: Bool? {
        requireBackups ?? filePolicy?.requireBackupBeforeWrite
    }

    var effectiveOutsideDefault: String? {
        outsideDefault ?? filePolicy?.outsideWorkspaceDefault
    }
}

// PATCH-2026-05-07: mac-control-ui-1 iOS mirror of TrustMacControlPolicy (keep in sync with Mac Models.swift)
struct TrustMacControlPolicy: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var applesScriptAllowed: Bool = false
    var jxaAllowed: Bool = false
    var shortcutsAllowed: Bool = true
    var accessibilityAllowed: Bool = false
    var systemControlAllowed: Bool = false
    var fileOpsAllowed: Bool = false
    var shellAllowed: Bool = false
    var notificationsAllowed: Bool = true
    var spotlightAllowed: Bool = true
    var approvalRequiredFor: [String] = []
    var remoteFromIosAllowed: Bool = false

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
}

// PATCH-2026-05-07: mac-control-ui-1 Mac Shortcut record for MacToolsView
struct MacShortcutRecord: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var description: String?
}

// PATCH-2026-05-07: mac-control-ui-1 Mac Control audit entry (iOS display)
struct MacControlAuditEntry: Identifiable, Codable {
    var id: String { "\(ts)-\(action)" }
    var ts: String
    var action: String
    var detail: String?
    var allowed: Bool?
}

// ApprovalRequest moved to NativeAgentShared.


struct ConnectorRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: String?
    var status: String?
    var enabled: Bool?
    var healthStatus: String?
    var lastUsedAt: String?
    var updatedAt: String?
}

struct DoctorReport: Codable, Hashable {
    var status: String
    var checks: [DoctorCheck]?
    var createdAt: String?
}

struct DoctorCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: String
    var detail: String?
}

struct MemoryProposalRecord: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var text: String
    var displayText: String?
    var layer: String?
    var importance: Double?
    var status: String?
    var sourceRunId: String?
    var createdAt: String?
    var supportingSessionIds: [String]
    var recurrenceCount: Int

    var isPending: Bool {
        let normalized = (status ?? "pending").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "pending" || normalized == "proposed"
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, displayText, layer, importance, status, sourceRunId, createdAt
        case proposalId = "proposal_id"
        case factText = "fact_text"
        case displayTextSnake = "display_text"
        case targetDoc = "target_doc"
        case sourceRunIdSnake = "source_run_id"
        case createdAtSnake = "created_at"
        case supportingSessionIdsSnake = "supporting_session_ids"
        case recurrenceCountSnake = "recurrence_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedId = try? container.decode(String.self, forKey: .id) {
            id = decodedId
        } else {
            id = try container.decode(String.self, forKey: .proposalId)
        }
        if let decodedText = try? container.decode(String.self, forKey: .text) {
            text = decodedText
        } else {
            text = try container.decode(String.self, forKey: .factText)
        }
        displayText = (try? container.decode(String.self, forKey: .displayText))
            ?? (try? container.decode(String.self, forKey: .displayTextSnake))
        layer = (try? container.decode(String.self, forKey: .layer))
            ?? (try? container.decode(String.self, forKey: .targetDoc))
        importance = try? container.decode(Double.self, forKey: .importance)
        status = try? container.decode(String.self, forKey: .status)
        sourceRunId = (try? container.decode(String.self, forKey: .sourceRunId))
            ?? (try? container.decode(String.self, forKey: .sourceRunIdSnake))
        createdAt = (try? container.decode(String.self, forKey: .createdAt))
            ?? (try? container.decode(String.self, forKey: .createdAtSnake))
        supportingSessionIds = (try? container.decode(
            [String].self,
            forKey: .supportingSessionIdsSnake
        )) ?? []
        recurrenceCount = (try? container.decode(
            Int.self,
            forKey: .recurrenceCountSnake
        )) ?? 1
    }

    var evidenceSummary: String {
        let sessions = supportingSessionIds.count
        if sessions == 0 {
            return recurrenceCount == 1
                ? "Observed once"
                : "Observed \(recurrenceCount)x"
        }
        return "Observed \(recurrenceCount)x in \(sessions) session\(sessions == 1 ? "" : "s")"
    }
}

struct TrainingProposalSummary: Decodable, Identifiable, Sendable {
    var id: String
    var title: String
    var status: String
    var kind: String?
    var targetDoc: String?
    var proposed: String?
    var rationale: String?
    var createdAt: String?

    var isHumanActionable: Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let proposedText = (proposed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rationaleText = (rationale ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedStatus == "pending"
            && !proposedText.isEmpty
            && !rationaleText.contains("proposal generation failed")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, kind, targetDoc, proposed, rationale, createdAt
        case proposalId = "proposal_id"
        case summary
        case targetDocSnake = "target_doc"
        case createdAtSnake = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .proposalId))
            ?? UUID().uuidString
        title = (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .summary))
            ?? "Training proposal"
        status = (try? container.decode(String.self, forKey: .status)) ?? "pending"
        kind = try? container.decode(String.self, forKey: .kind)
        targetDoc = (try? container.decode(String.self, forKey: .targetDoc))
            ?? (try? container.decode(String.self, forKey: .targetDocSnake))
        proposed = try? container.decode(String.self, forKey: .proposed)
        rationale = try? container.decode(String.self, forKey: .rationale)
        createdAt = (try? container.decode(String.self, forKey: .createdAt))
            ?? (try? container.decode(String.self, forKey: .createdAtSnake))
    }
}

struct PromotionCandidateSummary: Decodable, Identifiable, Sendable {
    var id: String
    var title: String
    var status: String
    var decision: String?
    var source: String?
    var score: Double?
    var createdAt: String?

    var isHumanActionable: Bool {
        let normalizedDecision = (decision ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedSource = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedDecision == "STAGE_FOR_HUMAN" && normalizedSource != "self_test"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, decision, source, score, createdAt
        case candidateId = "candidate_id"
        case summary
        case createdAtSnake = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .candidateId))
            ?? UUID().uuidString
        title = (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .summary))
            ?? "Promotion candidate"
        status = (try? container.decode(String.self, forKey: .status)) ?? "pending"
        decision = try? container.decode(String.self, forKey: .decision)
        source = try? container.decode(String.self, forKey: .source)
        score = try? container.decode(Double.self, forKey: .score)
        createdAt = (try? container.decode(String.self, forKey: .createdAt))
            ?? (try? container.decode(String.self, forKey: .createdAtSnake))
    }
}

struct SkillManifest: Codable, Identifiable {
    var id: String { name }
    var name: String
    var version: String?
    var description: String?
    var status: String?
    var kind: String?
    var triggers: [String]?
}

struct EvalRun: Identifiable, Codable, Hashable {
    var id: String
    var status: String
    var passCount: Int?
    var failCount: Int?
    var score: Double?
    var createdAt: String?
}

struct SchedulerJob: Identifiable, Codable, Hashable {
    var id: String
    var name: String?
    var kind: String?
    var status: String?
    var nextRunAt: String?
    var lastRunAt: String?
}

// PATCH-2026-05-07: leftover-1 iOS provider models — mirror of Mac ProviderInfo types

struct ProviderAuthStatus: Codable, Hashable, Sendable {
    var provider_id: String
    var state: String           // "ready" | "needs_key" | "needs_oauth" | "error"
    var detail: String
    /// Free-form metadata coerced to [String:String] — mirrors tolerant decoder on Mac side.
    /// The Mac may emit bools/numbers/nested dicts; we stringify everything so existing
    /// subscript call sites keep working.
    var user_info: [String: String]?
    var last_checked_at: String?

    enum CodingKeys: String, CodingKey {
        case provider_id, state, detail, user_info, last_checked_at
    }

    init(
        provider_id: String,
        state: String,
        detail: String,
        user_info: [String: String]?,
        last_checked_at: String?
    ) {
        self.provider_id = provider_id
        self.state = state
        self.detail = detail
        self.user_info = user_info
        self.last_checked_at = last_checked_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider_id     = try c.decode(String.self, forKey: .provider_id)
        self.state           = try c.decode(String.self, forKey: .state)
        self.detail          = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.last_checked_at = try c.decodeIfPresent(String.self, forKey: .last_checked_at)
        if c.contains(.user_info), try !c.decodeNil(forKey: .user_info) {
            let nested = try? c.decode([String: _AnyJSONValue].self, forKey: .user_info)
            self.user_info = nested?.compactMapValues { $0.asString }
        } else {
            self.user_info = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider_id, forKey: .provider_id)
        try c.encode(state, forKey: .state)
        try c.encode(detail, forKey: .detail)
        try c.encodeIfPresent(last_checked_at, forKey: .last_checked_at)
        try c.encodeIfPresent(user_info, forKey: .user_info)
    }
}

/// Helper used by ProviderAuthStatus to swallow arbitrary JSON values and surface them as strings.
private struct _AnyJSONValue: Decodable {
    let asString: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                        { self.asString = nil }
        else if let s = try? c.decode(String.self)              { self.asString = s }
        else if let b = try? c.decode(Bool.self)                { self.asString = String(b) }
        else if let i = try? c.decode(Int.self)                 { self.asString = String(i) }
        else if let d = try? c.decode(Double.self)              { self.asString = String(d) }
        else if let arr = try? c.decode([_AnyJSONValue].self)   { self.asString = arr.compactMap { $0.asString }.joined(separator: ",") }
        else if let dict = try? c.decode([String: _AnyJSONValue].self) { self.asString = dict.keys.sorted().joined(separator: ",") }
        else                                                    { self.asString = nil }
    }
}

struct ProviderModelInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var context_length: Int
    var supports_streaming: Bool
    var supports_vision: Bool
    var supports_tools: Bool
    var supports_json_mode: Bool
    var cost_per_1k_in: Double?
    var cost_per_1k_out: Double?
    var default_reasoning_effort: String? = nil
    var supported_reasoning_efforts: [String]? = nil
    var supports_fast: Bool? = nil
}

struct ProviderInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String { provider_id }
    var provider_id: String
    var display_name: String
    var auth_modes: [String]
    var auth_status: ProviderAuthStatus
    var models: [ProviderModelInfo]
}

struct ProviderTestResult: Codable, Hashable {
    var provider_id: String
    var status: String
    var tested: Bool
    var response: String?
    var model_used: String?
    var detail: String?
    var error: String?
}

// AnyCodable moved to NativeAgentShared.
