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
    /// 2026-09-06: the Mac session's transcript version at publication (see
    /// MacSyncEngine.ChatTranscriptSnapshot). A row carrying `messages: []` is
    /// the Mac stating the transcript is empty; this counter is what makes that
    /// statement provably newer than whatever the phone already applied. It is
    /// a counter bumped on every clear and every transcript write, never a
    /// clock. Absent on pre-2026-09-06 Mac builds, and then an empty row stays
    /// inert.
    var transcriptGeneration: Int? = nil
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

}

/// Wave 4 (phase A) read-both: accept the FUTURE `workshopPolicy` spelling as
/// well as the on-wire `missionPolicy`. Decode-only — `encode(to:)` stays the
/// synthesized one, so this build keeps writing `missionPolicy` and a 0.3.7
/// Mac decodes iOS snapshots byte-for-byte. Declared in an EXTENSION so the
/// synthesized memberwise initializer survives (an init in the struct body
/// suppresses it).
extension TrustPolicy {
    private enum FutureCodingKeys: String, CodingKey {
        case workshopPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissionLevel = try c.decodeIfPresent(String.self, forKey: .permissionLevel)
        autonomyDefault = try c.decodeIfPresent(String.self, forKey: .autonomyDefault)
        requireBackups = try c.decodeIfPresent(Bool.self, forKey: .requireBackups)
        outsideDefault = try c.decodeIfPresent(String.self, forKey: .outsideDefault)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode)
        // Future spelling first, on-wire spelling as the fallback. A PRESENT
        // but malformed future block throws, exactly like the legacy key —
        // the future spelling must never be the more forgiving one.
        let future = try decoder.container(keyedBy: FutureCodingKeys.self)
        workshopPolicy = try future.decodeIfPresent(TrustWorkshopPolicy.self, forKey: .workshopPolicy)
            ?? c.decodeIfPresent(TrustWorkshopPolicy.self, forKey: .workshopPolicy)
        toolPolicy = try c.decodeIfPresent(TrustToolPolicy.self, forKey: .toolPolicy)
        filePolicy = try c.decodeIfPresent(TrustFilePolicy.self, forKey: .filePolicy)
        connectorPolicy = try c.decodeIfPresent(TrustConnectorPolicy.self, forKey: .connectorPolicy)
        providerPolicy = try c.decodeIfPresent(TrustProviderPolicy.self, forKey: .providerPolicy)
        trainingPolicy = try c.decodeIfPresent(TrustTrainingPolicy.self, forKey: .trainingPolicy)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        macControlPolicy = try c.decodeIfPresent(TrustMacControlPolicy.self, forKey: .macControlPolicy)
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

// Keep iOS tolerant of snapshots written by older Mac builds that omitted
// newly added gates. Missing fields use the same fail-closed (or deliberate
// display-only) defaults as the Mac-side policy mirror; malformed present
// fields still reject the snapshot.
extension TrustMacControlPolicy {
    init(from decoder: Decoder) throws {
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

typealias ProviderAuthStatus = NativeAgentShared.ProviderAuthStatus

typealias ProviderModelInfo = NativeAgentShared.ProviderModelInfo

struct ProviderInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String { provider_id }
    var provider_id: String
    var display_name: String
    var auth_modes: [String]
    var auth_status: ProviderAuthStatus
    var models: [ProviderModelInfo]
}

typealias ProviderTestResult = NativeAgentShared.ProviderTestResult

// AnyCodable moved to NativeAgentShared.
