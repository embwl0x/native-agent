import Foundation
import NativeAgentShared
import PersistenceCore

public struct ContextBudget: Codable, Hashable {
    public var historyChars: Int?
    public var memoryChars: Int?
    public var agentMapChars: Int?
    public var loadedSkillChars: Int?
    public var toolResultChars: Int?
    public var totalChars: Int?
    public var maxChars: Int?
    public var remainingChars: Int?
    public var cached: Bool?
    public var cacheKey: String?
    public var cacheStatus: String?

    public var displayTotal: Int {
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

    public init(
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public struct ContextSkillRef: Identifiable, Codable, Hashable {
    public var skillId: String?
    public var name: String?

    public var id: String {
        skillId ?? name ?? "skill"
    }

    enum CodingKeys: String, CodingKey {
        case skillId = "id"
        case name
    }
    public init(skillId: String? = nil, name: String? = nil) {
        self.skillId = skillId
        self.name = name
    }
}

public struct ContextSelectionRef: Identifiable, Codable, Hashable {
    public var refId: String?
    public var name: String?
    public var kind: String?
    public var detail: String?
    public var reason: String?
    public var score: Double?

    public var id: String {
        refId ?? name ?? detail ?? UUID().uuidString
    }

    public var displayName: String {
        name ?? refId ?? detail ?? "selected"
    }

    public var displayDetail: String {
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

    public init(refId: String? = nil, name: String? = nil, kind: String? = nil, detail: String? = nil, reason: String? = nil, score: Double? = nil) {
        self.refId = refId
        self.name = name
        self.kind = kind
        self.detail = detail
        self.reason = reason
        self.score = score
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(refId, forKey: .refId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(score, forKey: .score)
    }
}

public struct ContextInjectedSection: Identifiable, Codable, Hashable {
    public var sectionId: String?
    public var title: String?
    public var kind: String?
    public var chars: Int?
    public var cached: Bool?

    public var id: String {
        sectionId ?? title ?? kind ?? UUID().uuidString
    }

    public var displayTitle: String {
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

    public init(sectionId: String? = nil, title: String? = nil, kind: String? = nil, chars: Int? = nil, cached: Bool? = nil) {
        self.sectionId = sectionId
        self.title = title
        self.kind = kind
        self.chars = chars
        self.cached = cached
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sectionId, forKey: .sectionId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(chars, forKey: .chars)
        try container.encodeIfPresent(cached, forKey: .cached)
    }
}

public struct ContextCacheState: Codable, Hashable {
    public var status: String?
    public var key: String?
    public var hit: Bool?
    public var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case key
        case cacheKey
        case hit
        case cached
        case createdAt
    }

    public init(status: String? = nil, key: String? = nil, hit: Bool? = nil, createdAt: String? = nil) {
        self.status = status
        self.key = key
        self.hit = hit
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try ContextCoding.decodeString(container, .status)
        key = try ContextCoding.decodeString(container, .key) ?? ContextCoding.decodeString(container, .cacheKey)
        hit = try container.decodeIfPresent(Bool.self, forKey: .hit) ?? container.decodeIfPresent(Bool.self, forKey: .cached)
        createdAt = try ContextCoding.decodeString(container, .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(hit, forKey: .hit)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

public struct ContextReceipt: Codable, Hashable {
    public var runId: String?
    public var sessionId: String?
    public var surface: String?
    public var createdAt: String?
    public var personaFingerprint: String?
    public var fingerprint: String?
    public var contextMode: String?
    public var routeReasons: [String]?
    public var injectedSections: [ContextInjectedSection]?
    public var selectedCapabilities: [ContextSelectionRef]?
    public var selectedMemories: [ContextSelectionRef]?
    public var selectedTools: [ContextSelectionRef]?
    public var selectedSkills: [ContextSelectionRef]?
    public var loadedSkills: [ContextSkillRef]?
    public var budgets: ContextBudget?
    public var budgetTotals: ContextBudget?
    public var cacheState: ContextCacheState?

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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
        decodeTolerantDisplayString(container, key)
    }

    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            // 2026-09-07: Int(Double) traps on NaN/inf/out-of-range; keep the truncation, reject the rest.
            return Int(exactly: value.rounded(.towardZero))
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
