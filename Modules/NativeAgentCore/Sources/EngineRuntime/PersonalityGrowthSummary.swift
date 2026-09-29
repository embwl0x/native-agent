import Foundation

public struct PersonalityGrowthSummary: Codable, Hashable {
    public var engineVersion: String
    public var activeKind: String?
    public var fingerprint: String?
    /// 2026-09-13: what changed this week and why, one line per lesson or
    /// view. Replaced `growthEntries`, which counted lines in GROWTH.md.
    public var growthWeek: [String]
    public var feedbackMemories: Int
    public var nextActions: [String]
    public var createdAt: String?
    public init(engineVersion: String, activeKind: String? = nil, fingerprint: String? = nil, growthWeek: [String], feedbackMemories: Int, nextActions: [String], createdAt: String? = nil) {
        self.engineVersion = engineVersion
        self.activeKind = activeKind
        self.fingerprint = fingerprint
        self.growthWeek = growthWeek
        self.feedbackMemories = feedbackMemories
        self.nextActions = nextActions
        self.createdAt = createdAt
    }
}
