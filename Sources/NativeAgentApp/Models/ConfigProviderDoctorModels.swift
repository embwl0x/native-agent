import ProviderRouting
import DoctorChecks
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import MemoryV2
import TrustCenter
import TelegramBot

struct AppConfig: Equatable {
    var searxngBaseURL: String?
    var searxngDetected: Bool?
    var telegram: TelegramConfigurationSummary?
    var codexAuth: CodexAuthStatus?
    var modelRouting: ModelRoutingConfig?
    var autoDoctor: AutoDoctorConfig?
}

typealias AutoDoctorConfig = DoctorChecks.AutoDoctorConfig

struct TelegramTestResponse: Codable, Hashable {
    var ok: Bool
    var chatId: String
    var messageId: Int?
    var receipt: TelegramReceipt?
    /// A successful outgoing reply proves the saved credential can send, but
    /// it does not prove the inbound long-poll lane is alive.  These fields
    /// are attached by NativeClient after the transport reply, from the live
    /// BackgroundLoops owner.
    var tokenConfigured: Bool?
    var pollerRegistered: Bool?
    var pollerTicking: Bool?

    init(result: TelegramTestResult) throws {
        let row = try TelegramReplyFields(result.rawResponse)
        ok = try row.required("ok") { if case .bool(let b) = $0 { return b }; return nil }
        let message = try TelegramReplyFields(row.required("result", { $0 }))
        let chat = try TelegramReplyFields(message.required("chat", { $0 }))
        chatId = String(try chat.required("id", TelegramReplyFields.integer))
        messageId = try message.required("message_id", TelegramReplyFields.integer)
        tokenConfigured = try row.optional("tokenConfigured", TelegramReplyFields.boolean)
        pollerRegistered = try row.optional("pollerRegistered", TelegramReplyFields.boolean)
        pollerTicking = try row.optional("pollerTicking", TelegramReplyFields.boolean)
        if let raw = try row.optional("receipt", { $0 }) {
            let receiptRow = try TelegramReplyFields(raw)
            receipt = TelegramReceipt(
                eventId: try receiptRow.optional("id", TelegramReplyFields.string),
                at: try receiptRow.required("at", TelegramReplyFields.string),
                kind: try receiptRow.optional("kind", TelegramReplyFields.string),
                chatId: try receiptRow.optional("chatId", TelegramReplyFields.string),
                userId: try receiptRow.optional("userId", TelegramReplyFields.string),
                updateId: try receiptRow.optional("updateId", TelegramReplyFields.integer),
                messageId: try receiptRow.optional("messageId", TelegramReplyFields.integer),
                textPreview: try receiptRow.optional("textPreview", TelegramReplyFields.string),
                replyPreview: try receiptRow.optional("replyPreview", TelegramReplyFields.string),
                model: try receiptRow.optional("model", TelegramReplyFields.string),
                reasoningEffort: try receiptRow.optional("reasoningEffort", TelegramReplyFields.string)
            )
        }
    }
}

private struct TelegramReplyFields {
    let fields: [String: JSONValue]

    init(_ value: JSONValue) throws {
        guard case .object(let fields) = value else {
            throw DecodingError.typeMismatch([String: JSONValue].self,
                .init(codingPath: [], debugDescription: "A Telegram reply is a JSON object."))
        }
        self.fields = fields
    }

    func optional<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T? {
        guard let raw = fields[key], raw != .null else { return nil }
        guard let value = read(raw) else {
            throw DecodingError.typeMismatch(T.self,
                .init(codingPath: [Key(stringValue: key)], debugDescription: "Invalid Telegram reply field: \(key)"))
        }
        return value
    }

    func required<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T {
        let codingKey = Key(stringValue: key)
        guard fields[key] != nil else {
            throw DecodingError.keyNotFound(codingKey,
                .init(codingPath: [], debugDescription: "Missing Telegram reply field: \(key)"))
        }
        guard let value = try optional(key, read) else {
            throw DecodingError.valueNotFound(T.self,
                .init(codingPath: [codingKey], debugDescription: "Null Telegram reply field: \(key)"))
        }
        return value
    }

    static func string(_ value: JSONValue) -> String? {
        if case .string(let s) = value { return s }; return nil
    }

    static func boolean(_ value: JSONValue) -> Bool? {
        if case .bool(let b) = value { return b }; return nil
    }

    static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return Int(exactly: d)
        default: return nil
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

struct DetectSearXNGResponse: Codable, Hashable {
    var found: Bool
    var baseURL: String?
    var source: String?
    var error: String?
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
    /// The digest of the script `readme` shows, the one Install admits.
    var scriptDigest: String? = nil

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
        // The script shows where User reviews it before Install admits it.
        return SkillInfo(id: skillId, manifest: manifest, registry: registry,
                         readme: skill.script.map { "\(skill.signature ?? "script")\n\n\($0.source)" },
                         scriptDigest: skill.script == nil ? nil : skill.scriptDigest)
    }
}

// The phone's memory_proposals.json row (MacSyncEngine snapshots). The Mac
// views read MemoryV2's ProposalRecord through engine.memory.
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

    init(_ proposal: ProposalRecord) {
        let evidence = proposal.evidence
        proposal_id = proposal.id
        fact_text = proposal.content
        display_text = nil
        supporting_session_ids = evidence.sessionIDs
        recurrence_count = evidence.recurrenceCount
        first_seen = proposal.createdAt
        last_seen = proposal.createdAt
        status = proposal.status
        staged_at = proposal.createdAt
        resolved_at = nil
        rejection_reason = proposal.rejectionReason
    }
}

// Extend TrustTrainingPolicy with route_through_promotion
extension TrustTrainingPolicy {
    // route_through_promotion added via CodingKeys-free approach below
}

// Perf wave 2 (render-cost audit F11 follow-up): `Equatable` so `refreshAll`
// can route these through `setIfChanged`. All stored properties are
// String/Int/Bool/optionals or already-`Hashable` nested types, so the
// conformance is synthesized — no behavior of its own.
struct TrainingRunSummary: Codable, Identifiable, Equatable {
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

struct TrainingProposalSummary: Codable, Identifiable, Equatable {
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
    /// The persisted training proposal schema uses `rejection_reason`.
    /// Keep the app-facing spelling while decoding the canonical record key,
    /// otherwise a successfully rejected proposal reloads without the reason
    /// that justified the decision.
    var reject_reason: String?

    enum CodingKeys: String, CodingKey {
        case proposal_id, staged_at, source_run_id, target_doc, change_type
        case current, proposed, rationale, expected_drift_addressed, status, reviewed_at
        case reject_reason = "rejection_reason"
    }
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

struct PromotionCandidateSummary: Codable, Identifiable, Equatable {
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

typealias ProviderAuthStatus = NativeAgentShared.ProviderAuthStatus

typealias ProviderModelInfo = NativeAgentShared.ProviderModelInfo

typealias ProviderTestResult = NativeAgentShared.ProviderTestResult

// PATCH-2026-05-08: wave3-health-card Feature A models
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
