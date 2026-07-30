import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct MemoryConsolidation: Codable, Hashable {
    var duplicatesRemoved: Int
    var remaining: Int
    var createdAt: String
}

// PersonalityTraits and PersonalityProfile struct moved to NativeAgentShared.
// defaultProfile static property stays Mac-side as an extension below.

extension PersonalityProfile {
    static let defaultProfile = PersonalityProfile(
        schemaVersion: 2,
        personaEngineVersion: "2.0",
        name: "NativeAgent",
        personaKind: "AI",
        essence: "A calm, sharp, practical native macOS agent that improves itself inside its own sandbox and helps the user get real work done.",
        voice: "Direct, grounded, specific, with no corporate fluff.",
        customDirective: "",
        traits: PersonalityTraits(
            warmth: 0.45,
            directness: 0.82,
            humor: 0.12,
            proactivity: 0.78,
            rigor: 0.86,
            autonomy: 0.82,
            creativity: 0.58,
            brevity: 0.74
        ),
        examples: [
            "Lead with the useful answer, then show only the context needed to act.",
            "When tools are involved, be explicit about what was actually done."
        ],
        forbiddenPatterns: [
            "Corporate filler.",
            "Claiming tool or file actions that did not happen.",
            "Over-explaining simple outcomes."
        ],
        instincts: nil,
        boundaries: nil,
        surfaceOverrides: [
            "chat": "",
            "telegram": "Keep Telegram replies shorter and preserve the same persona without long setup context.",
            "dream": "Reflect like an internal agent maintenance pass: specific lessons, memory candidates, eval ideas, and improvement targets.",
            "autonomy": "Operate as a careful self-improvement engineer inside the app-owned worktree."
        ],
        updatedAt: nil
    )
}

struct CompiledPersonality: Codable, Hashable {
    var surface: String
    var fingerprint: String
    var compiled: String
}

// PATCH-2026-05-07: chat-context-status Per-session context-window usage
// for the small fill bar in the chat brain area + the auto-compact path.
struct SessionContextStatus: Codable, Hashable {
    var session_id: String
    var used_tokens: Int
    var transcript_tokens: Int?
    var prompt_tokens: Int?
    var previous_turn_tokens: Int?
    var turn_delta_tokens: Int?
    var budget: Int
    var percent: Double
    var message_count: Int
    var compactable: Bool
    var auto_compact_threshold: Int
    var model: String
    var context_loaded: Bool?
    var context_mode: String?
    var context_fingerprint: String?
    var context_prompt_chars: Int?
}

struct CompactionResult: Codable, Hashable {
    var compacted: Bool
    var session_id: String?
    var messages_before: Int?
    var messages_after: Int?
    var summary_chars: Int?
    var messages_replaced: Int?
    var reason: String?
    var percent: Double?
    var error: String?
}

// PersonalityDoc moved to NativeAgentShared.

struct PersonalityDocsResponse: Codable, Hashable {
    var docs: [PersonalityDoc]
    var updatedAt: String?
}

struct ContextBudget: Codable, Hashable {
    var historyChars: Int?
    var memoryChars: Int?
    var agentMapChars: Int?
    var loadedSkillChars: Int?
    var toolResultChars: Int?
    var totalChars: Int?
    var maxChars: Int?
    var remainingChars: Int?
    var cached: Bool?
    var cacheKey: String?
    var cacheStatus: String?

    var displayTotal: Int {
        totalChars ?? [historyChars, memoryChars, agentMapChars, loadedSkillChars, toolResultChars].compactMap { $0 }.reduce(0, +)
    }

    enum CodingKeys: String, CodingKey {
        case historyChars
        case memoryChars
        case agentMapChars
        case loadedSkillChars
        case toolResultChars
        case totalChars
        case maxChars
        case remainingChars
        case cached
        case cacheKey
        case cacheStatus
        case history_chars
        case memory_chars
        case agent_map_chars
        case loaded_skill_chars
        case tool_result_chars
        case total_chars
        case max_chars
        case remaining_chars
        case cache_key
        case cache_status
    }

    init(
        historyChars: Int? = nil,
        memoryChars: Int? = nil,
        agentMapChars: Int? = nil,
        loadedSkillChars: Int? = nil,
        toolResultChars: Int? = nil,
        totalChars: Int? = nil,
        maxChars: Int? = nil,
        remainingChars: Int? = nil,
        cached: Bool? = nil,
        cacheKey: String? = nil,
        cacheStatus: String? = nil
    ) {
        self.historyChars = historyChars
        self.memoryChars = memoryChars
        self.agentMapChars = agentMapChars
        self.loadedSkillChars = loadedSkillChars
        self.toolResultChars = toolResultChars
        self.totalChars = totalChars
        self.maxChars = maxChars
        self.remainingChars = remainingChars
        self.cached = cached
        self.cacheKey = cacheKey
        self.cacheStatus = cacheStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        historyChars = try ContextCoding.decodeInt(container, .historyChars) ?? ContextCoding.decodeInt(container, .history_chars)
        memoryChars = try ContextCoding.decodeInt(container, .memoryChars) ?? ContextCoding.decodeInt(container, .memory_chars)
        agentMapChars = try ContextCoding.decodeInt(container, .agentMapChars) ?? ContextCoding.decodeInt(container, .agent_map_chars)
        loadedSkillChars = try ContextCoding.decodeInt(container, .loadedSkillChars) ?? ContextCoding.decodeInt(container, .loaded_skill_chars)
        toolResultChars = try ContextCoding.decodeInt(container, .toolResultChars) ?? ContextCoding.decodeInt(container, .tool_result_chars)
        totalChars = try ContextCoding.decodeInt(container, .totalChars) ?? ContextCoding.decodeInt(container, .total_chars)
        maxChars = try ContextCoding.decodeInt(container, .maxChars) ?? ContextCoding.decodeInt(container, .max_chars)
        remainingChars = try ContextCoding.decodeInt(container, .remainingChars) ?? ContextCoding.decodeInt(container, .remaining_chars)
        cached = try container.decodeIfPresent(Bool.self, forKey: .cached)
        cacheKey = try ContextCoding.decodeString(container, .cacheKey) ?? ContextCoding.decodeString(container, .cache_key)
        cacheStatus = try ContextCoding.decodeString(container, .cacheStatus) ?? ContextCoding.decodeString(container, .cache_status)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(historyChars, forKey: .historyChars)
        try container.encodeIfPresent(memoryChars, forKey: .memoryChars)
        try container.encodeIfPresent(agentMapChars, forKey: .agentMapChars)
        try container.encodeIfPresent(loadedSkillChars, forKey: .loadedSkillChars)
        try container.encodeIfPresent(toolResultChars, forKey: .toolResultChars)
        try container.encodeIfPresent(totalChars, forKey: .totalChars)
        try container.encodeIfPresent(maxChars, forKey: .maxChars)
        try container.encodeIfPresent(remainingChars, forKey: .remainingChars)
        try container.encodeIfPresent(cached, forKey: .cached)
        try container.encodeIfPresent(cacheKey, forKey: .cacheKey)
        try container.encodeIfPresent(cacheStatus, forKey: .cacheStatus)
    }
}

struct ContextSkillRef: Identifiable, Codable, Hashable {
    var skillId: String?
    var name: String?

    var id: String {
        skillId ?? name ?? "skill"
    }

    enum CodingKeys: String, CodingKey {
        case skillId = "id"
        case name
    }
}

struct ContextSelectionRef: Identifiable, Codable, Hashable {
    var refId: String?
    var name: String?
    var kind: String?
    var detail: String?
    var reason: String?
    var score: Double?

    var id: String {
        refId ?? name ?? detail ?? UUID().uuidString
    }

    var displayName: String {
        name ?? refId ?? detail ?? "selected"
    }

    var displayDetail: String {
        reason ?? detail ?? kind ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case refId = "id"
        case name
        case kind
        case detail
        case description
        case reason
        case score
        case sourceId
        case memoryId
        case toolId
        case skillId
        case capabilityId
    }

    init(refId: String? = nil, name: String? = nil, kind: String? = nil, detail: String? = nil, reason: String? = nil, score: Double? = nil) {
        self.refId = refId
        self.name = name
        self.kind = kind
        self.detail = detail
        self.reason = reason
        self.score = score
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            refId = value
            name = value
            kind = nil
            detail = nil
            reason = nil
            score = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        refId =
            try ContextCoding.decodeString(container, .refId) ??
            ContextCoding.decodeString(container, .sourceId) ??
            ContextCoding.decodeString(container, .memoryId) ??
            ContextCoding.decodeString(container, .toolId) ??
            ContextCoding.decodeString(container, .skillId) ??
            ContextCoding.decodeString(container, .capabilityId)
        name = try ContextCoding.decodeString(container, .name)
        kind = try ContextCoding.decodeString(container, .kind)
        detail = try ContextCoding.decodeString(container, .detail) ?? ContextCoding.decodeString(container, .description)
        reason = try ContextCoding.decodeString(container, .reason)
        score = try container.decodeIfPresent(Double.self, forKey: .score)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(refId, forKey: .refId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(score, forKey: .score)
    }
}

struct ContextInjectedSection: Identifiable, Codable, Hashable {
    var sectionId: String?
    var title: String?
    var kind: String?
    var chars: Int?
    var cached: Bool?

    var id: String {
        sectionId ?? title ?? kind ?? UUID().uuidString
    }

    var displayTitle: String {
        title ?? sectionId ?? kind ?? "section"
    }

    enum CodingKeys: String, CodingKey {
        case sectionId = "id"
        case title
        case name
        case kind
        case chars
        case characterCount
        case cached
    }

    init(sectionId: String? = nil, title: String? = nil, kind: String? = nil, chars: Int? = nil, cached: Bool? = nil) {
        self.sectionId = sectionId
        self.title = title
        self.kind = kind
        self.chars = chars
        self.cached = cached
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            sectionId = value
            title = value
            kind = nil
            chars = nil
            cached = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionId = try ContextCoding.decodeString(container, .sectionId)
        title = try ContextCoding.decodeString(container, .title) ?? ContextCoding.decodeString(container, .name)
        kind = try ContextCoding.decodeString(container, .kind)
        chars = try ContextCoding.decodeInt(container, .chars) ?? ContextCoding.decodeInt(container, .characterCount)
        cached = try container.decodeIfPresent(Bool.self, forKey: .cached)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sectionId, forKey: .sectionId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(chars, forKey: .chars)
        try container.encodeIfPresent(cached, forKey: .cached)
    }
}

struct ContextCacheState: Codable, Hashable {
    var status: String?
    var key: String?
    var hit: Bool?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case key
        case cacheKey
        case hit
        case cached
        case createdAt
    }

    init(status: String? = nil, key: String? = nil, hit: Bool? = nil, createdAt: String? = nil) {
        self.status = status
        self.key = key
        self.hit = hit
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try ContextCoding.decodeString(container, .status)
        key = try ContextCoding.decodeString(container, .key) ?? ContextCoding.decodeString(container, .cacheKey)
        hit = try container.decodeIfPresent(Bool.self, forKey: .hit) ?? container.decodeIfPresent(Bool.self, forKey: .cached)
        createdAt = try ContextCoding.decodeString(container, .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(hit, forKey: .hit)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

struct ContextReceipt: Codable, Hashable {
    var runId: String?
    var sessionId: String?
    var surface: String?
    var createdAt: String?
    var personaFingerprint: String?
    var fingerprint: String?
    var contextMode: String?
    var routeReasons: [String]?
    var injectedSections: [ContextInjectedSection]?
    var selectedCapabilities: [ContextSelectionRef]?
    var selectedMemories: [ContextSelectionRef]?
    var selectedTools: [ContextSelectionRef]?
    var selectedSkills: [ContextSelectionRef]?
    var loadedSkills: [ContextSkillRef]?
    var budgets: ContextBudget?
    var budgetTotals: ContextBudget?
    var cacheState: ContextCacheState?

    enum CodingKeys: String, CodingKey {
        case runId
        case sessionId
        case surface
        case createdAt
        case personaFingerprint
        case fingerprint
        case contextMode
        case routeReasons
        case injectedSections
        case selectedCapabilities
        case selectedMemories
        case selectedTools
        case selectedSkills
        case loadedSkills
        case budgets
        case budgetTotals
        case cacheState
        case cache
        case run_id
        case session_id
        case created_at
        case persona_fingerprint
        case context_mode
        case route_reasons
        case injected_sections
        case selected_capabilities
        case selected_memories
        case selected_tools
        case selected_skills
        case loaded_skills
        case budget_totals
        case cache_state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try ContextCoding.decodeString(container, .runId) ?? ContextCoding.decodeString(container, .run_id)
        sessionId = try ContextCoding.decodeString(container, .sessionId) ?? ContextCoding.decodeString(container, .session_id)
        surface = try ContextCoding.decodeString(container, .surface)
        createdAt = try ContextCoding.decodeString(container, .createdAt) ?? ContextCoding.decodeString(container, .created_at)
        personaFingerprint = try ContextCoding.decodeString(container, .personaFingerprint) ?? ContextCoding.decodeString(container, .persona_fingerprint)
        fingerprint = try ContextCoding.decodeString(container, .fingerprint)
        contextMode = try ContextCoding.decodeString(container, .contextMode) ?? ContextCoding.decodeString(container, .context_mode)
        routeReasons = try ContextCoding.decodeStringArray(container, .routeReasons) ?? ContextCoding.decodeStringArray(container, .route_reasons)
        injectedSections = try container.decodeIfPresent([ContextInjectedSection].self, forKey: .injectedSections) ?? container.decodeIfPresent([ContextInjectedSection].self, forKey: .injected_sections)
        selectedCapabilities = try container.decodeIfPresent([ContextSelectionRef].self, forKey: .selectedCapabilities) ?? container.decodeIfPresent([ContextSelectionRef].self, forKey: .selected_capabilities)
        selectedMemories = try container.decodeIfPresent([ContextSelectionRef].self, forKey: .selectedMemories) ?? container.decodeIfPresent([ContextSelectionRef].self, forKey: .selected_memories)
        selectedTools = try container.decodeIfPresent([ContextSelectionRef].self, forKey: .selectedTools) ?? container.decodeIfPresent([ContextSelectionRef].self, forKey: .selected_tools)
        selectedSkills = try container.decodeIfPresent([ContextSelectionRef].self, forKey: .selectedSkills) ?? container.decodeIfPresent([ContextSelectionRef].self, forKey: .selected_skills)
        loadedSkills = try container.decodeIfPresent([ContextSkillRef].self, forKey: .loadedSkills) ?? container.decodeIfPresent([ContextSkillRef].self, forKey: .loaded_skills)
        budgets = try container.decodeIfPresent(ContextBudget.self, forKey: .budgets)
        budgetTotals = try container.decodeIfPresent(ContextBudget.self, forKey: .budgetTotals) ?? container.decodeIfPresent(ContextBudget.self, forKey: .budget_totals)
        cacheState = try container.decodeIfPresent(ContextCacheState.self, forKey: .cacheState) ?? container.decodeIfPresent(ContextCacheState.self, forKey: .cache_state) ?? container.decodeIfPresent(ContextCacheState.self, forKey: .cache)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(runId, forKey: .runId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(surface, forKey: .surface)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(personaFingerprint, forKey: .personaFingerprint)
        try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(contextMode, forKey: .contextMode)
        try container.encodeIfPresent(routeReasons, forKey: .routeReasons)
        try container.encodeIfPresent(injectedSections, forKey: .injectedSections)
        try container.encodeIfPresent(selectedCapabilities, forKey: .selectedCapabilities)
        try container.encodeIfPresent(selectedMemories, forKey: .selectedMemories)
        try container.encodeIfPresent(selectedTools, forKey: .selectedTools)
        try container.encodeIfPresent(selectedSkills, forKey: .selectedSkills)
        try container.encodeIfPresent(loadedSkills, forKey: .loadedSkills)
        try container.encodeIfPresent(budgets, forKey: .budgets)
        try container.encodeIfPresent(budgetTotals, forKey: .budgetTotals)
        try container.encodeIfPresent(cacheState, forKey: .cacheState)
    }
}

private enum ContextCoding {
    static func decodeString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        if let value = try? container.decodeIfPresent(NextGenJSONValue.self, forKey: key) {
            return value.displayString
        }
        return nil
    }

    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    static func decodeStringArray<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> [String]? {
        if let values = try? container.decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let values = try? container.decodeIfPresent([NextGenJSONValue].self, forKey: key) {
            return values.map(\.displayString)
        }
        if let value = try decodeString(container, key) {
            return [value]
        }
        return nil
    }
}
