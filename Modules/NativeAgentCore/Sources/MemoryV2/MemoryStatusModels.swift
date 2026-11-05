import Foundation
// Blueprint: | `MemoryStatusModels.swift` | MemoryV2 counts, embedding and after-turn recovery (the journal's owed turns) wire models |

public struct MemoryV2Status: Codable, Hashable {
    public var status: String
    public var version: String?
    public var embedding: MemoryV2Embedding?
    public var counts: MemoryV2Counts?
    public var afterTurn: AfterTurnMemoryRecoveryStatus?
    public var createdAt: String?
    public var storageFailure: String?
    public init(status: String, version: String? = nil, embedding: MemoryV2Embedding? = nil, counts: MemoryV2Counts? = nil,
        afterTurn: AfterTurnMemoryRecoveryStatus? = nil, createdAt: String? = nil, storageFailure: String? = nil) {
        self.status = status
        self.version = version
        self.embedding = embedding
        self.counts = counts
        self.afterTurn = afterTurn
        self.createdAt = createdAt
        self.storageFailure = storageFailure
    }
}

public struct AfterTurnMemoryRecoveryStatus: Codable, Hashable, Sendable {
    public let status: String
    /// Recorded, not yet lived; nil when no journal is open for this data root.
    public let owedCount: Int?

    public var lines: [String] {
        guard let owedCount else { return ["The agent's lived-moment journal is not open here, so owed turns cannot be counted."] }
        guard owedCount > 0 else { return [] }
        return ["\(owedCount) turns owed to the agent: recorded, not yet lived. The next idle pass, the agent's wake or the night lives them."]
    }
}

public struct MemoryV2Embedding: Codable, Hashable {
    public var activeBackend: String?
    public var realSemanticAvailable: Bool?
    public var fallbackReason: String?
    public init(activeBackend: String? = nil, realSemanticAvailable: Bool? = nil, fallbackReason: String? = nil) {
        self.activeBackend = activeBackend
        self.realSemanticAvailable = realSemanticAvailable
        self.fallbackReason = fallbackReason
    }
}

public struct MemoryV2Counts: Codable, Hashable {
    public var memories: Int?
    public var active: Int?
    public var pinned: Int?
    public var pendingProposals: Int?
    public init(memories: Int? = nil, active: Int? = nil, pinned: Int? = nil, pendingProposals: Int? = nil) {
        self.memories = memories
        self.active = active
        self.pinned = pinned
        self.pendingProposals = pendingProposals
    }
}

public struct MemoryMiss: Codable, Hashable, Sendable, Identifiable {
    public var originId: String
    public var memoryId: String
    public var text: String
    public var at: String
    public var week: String
    public var sessionId: String?
    /// Missing kept-turn evidence has no transcript locator.
    public var history: String?
    public var id: String { "\(memoryId.utf8.count):\(memoryId)" + originId }
}

/// Count the full window before bounding examples to ten, newest first.
public struct MemoryMissLesson: Codable, Hashable, Sendable, Identifiable {
    public var lesson: String
    public var countsByWeek: [String: Int]
    public var misses: [MemoryMiss]
    public var id: String { lesson }

    public func count(week: String) -> Int { countsByWeek[week, default: 0] }
}
