import Foundation
// Blueprint: | `InspectorModels.swift` | Shared content-free Inspector turn summaries and mobile tool catalog rows with compatible summary decoding |

public struct TurnSummaryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String              // turnId
    public var surface: String?
    public var sessionId: String?
    public var startedAt: Date
    public var lastAt: Date
    public var eventCount: Int
    public var wallMs: Int
    public var llmTokens: Int?
    public var ttftMs: Int?
    public var kinds: [String: Int]

    public init(id: String, surface: String?, sessionId: String?, startedAt: Date, lastAt: Date,
                eventCount: Int, wallMs: Int, llmTokens: Int?, ttftMs: Int?, kinds: [String: Int]) {
        self.id = id; self.surface = surface; self.sessionId = sessionId
        self.startedAt = startedAt; self.lastAt = lastAt; self.eventCount = eventCount
        self.wallMs = wallMs; self.llmTokens = llmTokens; self.ttftMs = ttftMs; self.kinds = kinds
    }

    public init(from decoder: Decoder) throws {
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

public struct TurnSummaryFile: Codable, Hashable, Sendable {
    public var summaries: [TurnSummaryRecord]
    public var truncated: Bool
    public var totalTurnsSeen: Int
    public var generatedAt: Date?

    public init(summaries: [TurnSummaryRecord], truncated: Bool = false, totalTurnsSeen: Int) {
        self.summaries = summaries
        self.truncated = truncated
        self.totalTurnsSeen = totalTurnsSeen
        self.generatedAt = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summaries = try c.decodeIfPresent([TurnSummaryRecord].self, forKey: .summaries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        totalTurnsSeen = try c.decodeIfPresent(Int.self, forKey: .totalTurnsSeen) ?? summaries.count
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }
}

public struct MobileToolCatalogRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var status: String?
    public var description: String?
    public var autoRun: Bool?
    public var riskClass: String?
    public var updatedAt: String?

    public init(
        id: String, name: String, kind: String? = nil, status: String? = nil, description: String? = nil,
        autoRun: Bool? = nil, riskClass: String? = nil, updatedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.description = description
        self.autoRun = autoRun
        self.riskClass = riskClass
        self.updatedAt = updatedAt
    }
}
