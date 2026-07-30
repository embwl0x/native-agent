import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct AppConfig: Codable, Hashable {
    var searxngBaseURL: String?
    var searxngDetected: Bool?
    var telegram: TelegramConfig?
    var codexAuth: CodexAuthStatus?
    var modelRouting: ModelRoutingConfig?
    var autoDoctor: AutoDoctorConfig?
}

struct AutoDoctorConfig: Codable, Hashable {
    var enabled: Bool?
    var runOnStartup: Bool?
    var intervalSeconds: Int?
    var usesModelCalls: Bool?
    var checkLLM: Bool?
}

struct TelegramConfig: Codable, Hashable {
    var tokenConfigured: Bool?
    var allowedChatIds: [String]?
    var allowedUserIds: [String]?
    var requireMention: Bool?
    var enabled: Bool?
    var model: String?
    var reasoningEffort: String?
}

struct TelegramStatus: Codable, Hashable {
    var enabled: Bool
    var tokenConfigured: Bool
    var allowedChatIds: [String]
    var allowedUserIds: [String]
    var requireMention: Bool
    var model: String?
    var reasoningEffort: String?
    var pollerEnabled: Bool
    var lastSeenUpdateId: Int?
    var lastSeenAt: String?
    var lastReplyAt: String?
    var lastError: String?
    /// Consecutive long-poll transport failures. A successful poll resets this
    /// to zero in the canonical Telegram state file.
    var pollBackoffFailures: Int?
    var lastPollAt: String?
    var voiceTranscription: TelegramVoiceTranscriptionStatus?
    var receipts: [TelegramReceipt]
    var blocked: [TelegramBlockedEvent]
    var errors: [TelegramErrorEvent]
}

extension TelegramStatus {
    var normalizedLastError: String? {
        guard let value = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Telegram long polling is a retrying transport. One or two consecutive
    /// interruptions while the canonical poller is still running are
    /// observations, not an outage. The third consecutive failure becomes
    /// actionable so a genuinely unreachable bot still surfaces promptly.
    var isTransientPollInterruption: Bool {
        guard pollerEnabled,
              let error = normalizedLastError,
              error.lowercased().hasPrefix("poll:") else { return false }
        return (pollBackoffFailures ?? 0) < 3
    }

    var actionableError: String? {
        isTransientPollInterruption ? nil : normalizedLastError
    }

    var isOperational: Bool {
        enabled && tokenConfigured && pollerEnabled && actionableError == nil
    }
}

struct TelegramVoiceTranscriptionStatus: Codable, Hashable {
    var enabled: Bool
    var backend: String
    var model: String
    var maxBytes: Int
    var backendSupported: Bool
    var keyConfigured: Bool
    var requiresAPIKey: Bool?
}

struct TelegramReceipt: Identifiable, Codable, Hashable {
    var eventId: String?
    var at: String
    var kind: String?
    var chatId: String?
    var userId: String?
    var updateId: Int?
    var messageId: Int?
    var textPreview: String?
    var replyPreview: String?
    var model: String?
    var reasoningEffort: String?

    var id: String { eventId ?? "\(at)-\(chatId ?? "")-\(messageId ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case at
        case kind
        case chatId
        case userId
        case updateId
        case messageId
        case textPreview
        case replyPreview
        case model
        case reasoningEffort
    }
}

struct ReasoningEffortOption: Identifiable, Codable, Hashable {
    var id: String
    var label: String
    var description: String?
}

struct ModelCatalogItem: Identifiable, Codable, Hashable {
    var id: String
    var displayName: String
    var description: String?
    var defaultReasoningEffort: String?
    var supportedReasoningEfforts: [String]?
    var supportsFast: Bool?
    var priority: Int?
}

struct ModelSurfacePreference: Codable, Hashable {
    var surface: String?
    var model: String
    var reasoningEffort: String
    var serviceTier: String? = nil
    var source: String?
    var modelKnown: Bool?
}

struct ModelRoutingCurrent: Codable, Hashable {
    var chat: ModelSurfacePreference
    var telegram: ModelSurfacePreference
    // FIX: the other 6 routing surfaces silently dropped on decode because they
    // were never declared. Optional so they don't break existing chat/telegram.
    var ios: ModelSurfacePreference?
    var executions: ModelSurfacePreference?
    var autonomy: ModelSurfacePreference?
    var swarms: ModelSurfacePreference?
    var dream: ModelSurfacePreference?
    var training: ModelSurfacePreference?

    enum CodingKeys: String, CodingKey {
        case chat, telegram, ios, autonomy, swarms, dream, training
        case executions = "missions" // compatibility wire ID (routing-config surface key)
    }
}

struct ModelRoutingConfig: Codable, Hashable {
    var status: String?
    var defaultModel: String?
    var fallbackModels: [String]?
    var reasoningEfforts: [ReasoningEffortOption]?
    var current: ModelRoutingCurrent
}

struct ModelCatalogResponse: Codable, Hashable {
    var status: String
    var source: String?
    var defaultModel: String
    var fallbackModels: [String]
    var models: [ModelCatalogItem]
    var reasoningEfforts: [ReasoningEffortOption]
    var current: ModelRoutingCurrent
    var updatedAt: String?
}

struct TelegramBlockedEvent: Identifiable, Codable, Hashable {
    var eventId: String?
    var at: String
    var reason: String?
    var chatId: String?
    var userId: String?
    var updateId: Int?
    var textPreview: String?

    var id: String { eventId ?? "\(at)-\(chatId ?? "")-\(userId ?? "")-\(reason ?? "")" }

    enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case at
        case reason
        case chatId
        case userId
        case updateId
        case textPreview
    }
}

struct TelegramErrorEvent: Identifiable, Codable, Hashable {
    var eventId: String?
    var at: String
    var context: String?
    var error: String

    var id: String { eventId ?? "\(at)-\(context ?? "")-\(error)" }

    enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case at
        case context
        case error
    }
}

struct TelegramTestResponse: Codable, Hashable {
    var ok: Bool
    var chatId: String
    var messageId: Int?
    var receipt: TelegramReceipt?
}

struct DetectSearXNGResponse: Codable, Hashable {
    var found: Bool
    var baseURL: String?
    var source: String?
    var error: String?
}

struct SetupQuestion: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var question: String
    var action: String
    var required: Bool
}

struct CodexAuthStatus: Codable, Hashable {
    var active: String
    var appOwnedLoggedIn: Bool
    var sharedLoggedIn: Bool
    var codexHome: String
    var detail: String
}

struct CodexDeviceLogin: Codable, Hashable {
    var running: Bool?
    var pid: Int?
    var url: String?
    var code: String?
    var expiresInMinutes: Int?
    var openedBrowser: Bool?
    var codexHome: String?
    var loginCommand: String?
    var detail: String?
    var exitCode: Int?
    var startedAt: String?
    var finishedAt: String?
}

struct DoctorReport: Codable, Hashable {
    var status: String
    var repaired: Bool
    var checks: [DoctorCheck]
}

struct DoctorCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: String
    var detail: String
    var repair: String?
}

// PATCH-2026-05-06: skill-ui Models — skill manifest + registry types for lifecycle UI
struct SkillManifest: Codable, Identifiable {
    var id: String { name }
    let schemaVersion: Int
    let name: String
    let version: String
    let type: String      // "connector" | "tool" | "agent_persona" | "composite"
    let description: String
    let author: SkillAuthor?
    let permissions: [String]?
    let tools: [SkillTool]?
    let oauth: SkillOAuth?
    let tags: [String]?
    let homepage: String?
}

struct SkillAuthor: Codable {
    let name: String
    let email: String?
    let url: String?
}

struct SkillOAuth: Codable {
    let provider: String
    let scopes: [String]
    let deviceFlow: Bool?
}

struct SkillTool: Codable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
}

struct SkillRegistryEntry: Codable, Identifiable {
    var id: String { name }
    let name: String
    let state: String     // "drafted" | "installed" | "active" | "dormant" | "quarantined"
    let version: String
    let type: String
    let installedAt: String?
    let path: String
}

struct SkillInfo: Identifiable {
    let id: String         // == manifest.name
    let manifest: SkillManifest
    let registry: SkillRegistryEntry
    let readme: String?    // optional, loaded on demand

    static func learnedSkill(_ skill: SkillRecord) -> SkillInfo {
        let skillId = skill.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? skill.name : skill.id
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? skillId : skill.name
        let rawState = (skill.status ?? "active").lowercased()
        let state: String = {
            switch rawState {
            case "draft": return "drafted"
            case "disabled": return "dormant"
            default: return rawState.isEmpty ? "active" : rawState
            }
        }()
        let manifest = SkillManifest(
            schemaVersion: 1,
            name: name,
            version: "runtime",
            type: skill.kind ?? "learned_skill",
            description: skill.description,
            author: nil,
            permissions: nil,
            tools: nil,
            oauth: nil,
            tags: skill.autoCreated == true ? ["learned"] : nil,
            homepage: nil
        )
        let registry = SkillRegistryEntry(
            name: skillId,
            state: state,
            version: "runtime",
            type: skill.kind ?? "learned_skill",
            installedAt: skill.createdAt,
            path: skill.bodyPath ?? ""
        )
        return SkillInfo(id: skillId, manifest: manifest, registry: registry, readme: nil)
    }
}

// PATCH-2026-05-07: self-improvement-ui Beyond B.1/B.3 — training + promotion models

struct TrustPromotionPolicy: Codable, Hashable {
    var enabled: Bool = false
    var auto_promote_tier_a: Bool = false
    var run_smoke_in_harness: Bool = true
}

// PATCH-2026-05-07: living-memory Trust gates for living memory system
struct TrustMemoryPolicy: Codable, Hashable {
    var consolidation_enabled: Bool = false
    var cross_session_recall: Bool = true
    var auto_promote_consolidated: Bool = false
    var knowledge_graph_enabled: Bool = false
    var adaptive_promotion: Bool = false
    var hygiene_enabled: Bool = true
    var hygiene_interval_hours: Double = 6
    var archive_noisy_reflections: Bool = true
    var reject_low_value_proposals: Bool = true

    init(
        consolidation_enabled: Bool = false,
        cross_session_recall: Bool = true,
        auto_promote_consolidated: Bool = false,
        knowledge_graph_enabled: Bool = false,
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consolidation_enabled = try c.decodeIfPresent(Bool.self, forKey: .consolidation_enabled) ?? false
        cross_session_recall = try c.decodeIfPresent(Bool.self, forKey: .cross_session_recall) ?? true
        auto_promote_consolidated = try c.decodeIfPresent(Bool.self, forKey: .auto_promote_consolidated) ?? false
        knowledge_graph_enabled = try c.decodeIfPresent(Bool.self, forKey: .knowledge_graph_enabled) ?? false
        adaptive_promotion = try c.decodeIfPresent(Bool.self, forKey: .adaptive_promotion) ?? false
        hygiene_enabled = try c.decodeIfPresent(Bool.self, forKey: .hygiene_enabled) ?? true
        hygiene_interval_hours = try c.decodeIfPresent(Double.self, forKey: .hygiene_interval_hours) ?? 6
        archive_noisy_reflections = try c.decodeIfPresent(Bool.self, forKey: .archive_noisy_reflections) ?? true
        reject_low_value_proposals = try c.decodeIfPresent(Bool.self, forKey: .reject_low_value_proposals) ?? true
    }
}

// PATCH-2026-05-07: living-memory MemoryProposal model for pending-review UI
struct MemoryProposalRecord: Codable, Identifiable, Hashable {
    var proposal_id: String
    var fact_text: String
    var display_text: String?
    var supporting_session_ids: [String]
    var recurrence_count: Int
    var first_seen: String
    var last_seen: String
    var status: String
    var staged_at: String
    var resolved_at: String?
    var rejection_reason: String?
    var id: String { proposal_id }

    var evidenceSummary: String {
        let sessions = supporting_session_ids.count
        if sessions == 0 {
            return recurrence_count == 1
                ? "Observed once; session evidence unavailable"
                : "Observed \(recurrence_count)x; session evidence unavailable"
        }
        return "Observed \(recurrence_count)x in \(sessions) session\(sessions == 1 ? "" : "s")"
    }
}

// Extend TrustTrainingPolicy with route_through_promotion
extension TrustTrainingPolicy {
    // route_through_promotion added via CodingKeys-free approach below
}

struct TrainingRunSummary: Codable, Identifiable {
    var id: String { run_id }
    var run_id: String
    var started_at: String?
    var completed_at: String?
    var surface: String?
    var score: Int?
    var max_score: Int?
    var drift_summary: String?
    var proposals_staged: Int?
    var verdict: String?  // "PASS" / "REGRESSION" / "RUNNING"
}

struct TrainingProposalSummary: Codable, Identifiable {
    var id: String { proposal_id }
    var proposal_id: String
    var staged_at: String?
    var source_run_id: String?
    var target_doc: String    // "SOUL.md" | "VOICE.md"
    var change_type: String   // "append" | "edit"
    var current: String
    var proposed: String
    var rationale: String
    var expected_drift_addressed: String?
    var status: String        // "pending" | "approved" | "rejected"
    var reviewed_at: String?
    var reject_reason: String?
}

struct PromotionHarnessResult: Codable, Hashable {
    var eval_score: Double?
    var eval_baseline: Double?
    var eval_delta: Double?
    var test_passed: Bool?
    var smoke_passed: Bool?
    var error: String?
}

struct PromotionPatch: Codable, Hashable {
    var file: String
    var before_sha: String?
    var after_sha: String?
}

struct PromotionCandidateSummary: Codable, Identifiable {
    var id: String { candidate_id }
    var candidate_id: String
    var submitted_at: String?
    var created_at: String?
    var source: String          // "manual" | "training_b1" | "skill_builder"
    var tier: String?           // "A" | "B" | "C"
    var decision: String?       // "AUTO_PROMOTE" | "STAGE_FOR_HUMAN" | "REVERT" | "BLOCK" | nil
    var status: String          // "running" | "complete" | "done" | "error"
    var harness: PromotionHarnessResult?
    var reason: String?
    var patches: [PromotionPatch]?
    var merged_commit_sha: String?

    enum CodingKeys: String, CodingKey {
        case candidate_id, candidateId, submitted_at, submittedAt, created_at, createdAt
        case source, tier, decision, status, harness, reason, patches, merged_commit_sha
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidate_id = try c.decodeIfPresent(String.self, forKey: .candidate_id)
            ?? c.decodeIfPresent(String.self, forKey: .candidateId)
            ?? ""
        submitted_at = try c.decodeIfPresent(String.self, forKey: .submitted_at)
            ?? c.decodeIfPresent(String.self, forKey: .submittedAt)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
            ?? c.decodeIfPresent(String.self, forKey: .createdAt)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "promotion_stage"
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        harness = try c.decodeIfPresent(PromotionHarnessResult.self, forKey: .harness)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        patches = try c.decodeIfPresent([PromotionPatch].self, forKey: .patches)
        merged_commit_sha = try c.decodeIfPresent(String.self, forKey: .merged_commit_sha)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(candidate_id, forKey: .candidate_id)
        try c.encodeIfPresent(submitted_at, forKey: .submitted_at)
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(tier, forKey: .tier)
        try c.encodeIfPresent(decision, forKey: .decision)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(harness, forKey: .harness)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(patches, forKey: .patches)
        try c.encodeIfPresent(merged_commit_sha, forKey: .merged_commit_sha)
    }
}

// PATCH-2026-05-07: model-providers v1 — Swift models for multi-provider registry

struct ProviderAuthStatus: Codable, Hashable {
    var provider_id: String
    var state: String           // "ready" | "needs_key" | "needs_oauth" | "error"
    var detail: String
    /// Free-form metadata. The daemon emits arbitrary JSON shapes here —
    /// bools, numbers, strings, and dicts thereof. We coerce everything
    /// to a [String:String] dict during decode so the existing
    /// subscript-based call sites keep working.
    /// PATCH-2026-05-07: provider-list-decode Without this coercion, a
    /// single non-string nested value (e.g.
    /// anthropic_mcp.user_info.mcp_process_alive: false) failed the whole
    /// /v1/providers decode and the per-surface picker stayed empty.
    var user_info: [String: String]?
    var last_checked_at: String?

    enum CodingKeys: String, CodingKey {
        case provider_id, state, detail, user_info, last_checked_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider_id = try c.decode(String.self, forKey: .provider_id)
        self.state       = try c.decode(String.self, forKey: .state)
        self.detail      = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.last_checked_at = try c.decodeIfPresent(String.self, forKey: .last_checked_at)
        // Coerce any nested JSON value into a string. Drop nulls.
        if c.contains(.user_info), try !c.decodeNil(forKey: .user_info) {
            let nested = try? c.decode([String: AnyJSONValue].self, forKey: .user_info)
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

/// Helper used by ProviderAuthStatus to swallow arbitrary JSON values and
/// surface them as strings.
struct AnyJSONValue: Decodable, Hashable {
    let asString: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                  { self.asString = nil }
        else if let s = try? c.decode(String.self)        { self.asString = s }
        else if let b = try? c.decode(Bool.self)          { self.asString = String(b) }
        else if let i = try? c.decode(Int.self)           { self.asString = String(i) }
        else if let d = try? c.decode(Double.self)        { self.asString = String(d) }
        else if let arr = try? c.decode([AnyJSONValue].self) {
            self.asString = arr.compactMap { $0.asString }.joined(separator: ",")
        }
        else if let dict = try? c.decode([String: AnyJSONValue].self) {
            self.asString = dict.keys.sorted().joined(separator: ",")
        }
        else { self.asString = nil }
    }
}

struct ProviderModelInfo: Codable, Hashable, Identifiable {
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

struct ProviderInfo: Codable, Hashable, Identifiable {
    var id: String { provider_id }
    var provider_id: String
    var display_name: String
    var auth_modes: [String]
    var auth_status: ProviderAuthStatus
    var models: [ProviderModelInfo]
    var auth_mode: String?
    var default_model: String?
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

// PATCH-2026-05-08: wave3-health-card Feature A models
struct HealthCardSubsystem: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var status: String  // "ok" | "warn" | "error"
    var detail: String
    var fixAction: String?
}

struct HealthCard: Codable, Hashable {
    var overall: String  // "ok" | "warn" | "error"
    var subsystems: [HealthCardSubsystem]
    var createdAt: String?  // Fix 9: optional — older daemon responses may omit this
}

// Swift-native embeddings backend status payload. The field names preserve
// the former daemon wire shape so existing UI/state decoding stays stable.
// The active runtime is one of: CoreML MiniLM, explicit mock (config or env
// opt-in), or fail-closed (CoreML resources missing / load failed).
struct EmbeddingsStatus: Codable, Hashable {
    var libraryAvailable: Bool
    var modelLoadable: Bool?
    // gpt-5.5 review-7 NEEDS_FIX: configBackend mirrors what the user
    // requested via `config/embeddings.json::backend` — "coreml-minilm" when
    // CoreML is enabled OR the Swift-native config value when set (legacy
    // "local" still possible for back-compat). It is NOT the legacy "hash"
    // string anymore.
    var configBackend: String         // "coreml-minilm" | "mock" | legacy "local"
    var envEnabled: Bool
    // effectiveBackend is the runtime terminal state for THIS panel:
    //   "local"       -> CoreML MiniLM serving real semantic vectors
    //   "hash"        -> mock vectors (explicit user opt-out OR env opt-in)
    //   "unavailable" -> fail-closed (resources missing / load failed and
    //                    no env opt-in; embed() throws)
    var effectiveBackend: String      // "local" | "hash" | "unavailable"
    var modelName: String
    var requestedEnabled: Bool
    var memoryMode: String?
    var memoryModeDetail: EmbeddingsMemoryModeDetail?
    var idleUnloadSeconds: Int?
    var modelState: EmbeddingsModelState?
    var installState: EmbeddingsInstallState?
    var reindexState: EmbeddingsInstallState?
    var extrasPath: String?
}

struct EmbeddingsMemoryModeDetail: Codable, Hashable {
    var mode: String?
    var title: String?
    var detail: String?
    var idleUnloadSeconds: Int?
}

struct EmbeddingsModelState: Codable, Hashable {
    var mode: String?
    var loaded: Bool?
    var parentLoaded: Bool?
    var workerRunning: Bool?
    var workerPid: Int?
    var lastUsedAt: String?
    var lastLoadedAt: String?
    var lastUnloadedAt: String?
    var unloadReason: String?
    var loadCount: Int?
    var unloadCount: Int?
    var cacheSize: Int?
    var cacheMaxSize: Int?
}

// Result envelope for embedding settings changes.
struct EmbeddingsToggleResult: Codable, Hashable {
    var ok: Bool?
    var error: String?
    var detail: String?
    var status: EmbeddingsStatus
}

// Progress payload embedded inside EmbeddingsStatus (installState /
// reindexState). Retained for model-prep/indexing status and legacy decode
// compatibility.
// state: "idle" | "installing" | "running" | "complete" | "failed".
struct EmbeddingsInstallState: Codable, Hashable {
    var state: String
    var currentStep: String?
    var progress: Int?
    var error: String?
    var detail: String?
    var startedAt: String?
    var failedAt: String?
    var completedAt: String?
    var extrasPath: String?
    var hfCachePath: String?
    var total: Int?
    var candidates: Int?
    var embedded: Int?
    var skipped: Int?
    var failed: Int?
    var reason: String?
    var lastUpdatedAt: String?
}

// Retired installer kickoff response shape. Kept so stale callers decode a
// clear error instead of breaking ABI while the UI no longer presents the
// installer path.
struct EmbeddingsInstallKickoff: Codable, Hashable {
    var ok: Bool
    var alreadyRunning: Bool?
    var status: EmbeddingsInstallState
}

// PATCH-2026-05-08: wave3-whats-running Feature B models
struct WhatsRunningItem: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var label: String
    var startedAt: String?
    var startsAt: String?
    var cancellable: Bool
    var cancelHint: String?
}

struct WhatsRunning: Codable, Hashable {
    var items: [WhatsRunningItem]
    var count: Int?  // Fix 9: optional — can be derived from items.count if missing
}
