import Foundation
// Blueprint: | `MemoryStatusModels.swift` | MemoryV2 counts, embedding and after-turn recovery (the journal's owed turns) wire models |

public struct MemoryV2Status: Codable, Hashable {
    public var status: String
    public var version: String?
    public var embedding: MemoryV2Embedding?
    public var counts: MemoryV2Counts?
    public var afterTurn: AfterTurnMemoryRecoveryStatus?
    public var createdAt: String?
    public init(status: String, version: String? = nil, embedding: MemoryV2Embedding? = nil, counts: MemoryV2Counts? = nil, afterTurn: AfterTurnMemoryRecoveryStatus? = nil, createdAt: String? = nil) {
        self.status = status
        self.version = version
        self.embedding = embedding
        self.counts = counts
        self.afterTurn = afterTurn
        self.createdAt = createdAt
    }
}

/// Her journal's owed turns, as status reads them.
public struct AfterTurnMemoryRecoveryStatus: Codable, Hashable, Sendable {
    public let status: String
    /// Recorded, not yet lived; nil when no journal is open for this data root.
    public let owedCount: Int?

    public var lines: [String] {
        guard let owedCount else { return ["Her lived-moment journal is not open here, so owed turns cannot be counted."] }
        guard owedCount > 0 else { return [] }
        return ["\(owedCount) turns owed to her: recorded, not yet lived. The next idle pass, her wake or the night lives them."]
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

/// One time she was given a correction, in the miss ledger
/// (`MemoryRecoveryReadout.misses`).
public struct MemoryMiss: Codable, Hashable, Sendable, Identifiable {
    public var memoryId: String
    public var text: String
    /// When, and the ISO week that falls in ("2026-W41").
    public var at: String
    public var week: String
    public var sessionId: String?
    /// `history:<message id>` in that session; nil on rows kept before turns were stamped.
    public var history: String?
    public var id: String { memoryId + "@" + at }
}

/// The corrections that teach one lesson, newest first.
public struct MemoryMissLesson: Codable, Hashable, Sendable, Identifiable {
    public var lesson: String
    public var misses: [MemoryMiss]
    public var id: String { lesson }

    public func count(week: String) -> Int { misses.filter { $0.week == week }.count }
}
