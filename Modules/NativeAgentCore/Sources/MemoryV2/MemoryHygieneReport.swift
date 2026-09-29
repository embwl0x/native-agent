public struct MemoryHygieneReport: Codable, Hashable {
    public var id: String?
    public var status: String?
    public var reason: String?
    public var version: String?
    public var createdAt: String?
    public var beforeCount: Int?
    public var afterCount: Int?
    public var normalized: Int?
    public var archivedDuplicates: Int?
    public var archivedReflections: Int?
    public var distilledFactsAdded: Int?
    public var decayedMemories: Int?
    public var proposalHygiene: MemoryProposalHygiene?
    /// Exact gated-consolidation run represented by this maintenance receipt.
    /// It prevents an unrelated historical success from clearing a newly
    /// staged or failed maintenance state.
    public var consolidationRunId: String?
    /// F2: surfaced by readHygieneLastRun — ISO8601 of the next cadence-driven
    /// run (weekly: createdAt + 7d, matching the runner's card-staging
    /// cadence). nil if no last-run anchor is on disk.
    public var nextScheduled: String?

    public init(
        id: String? = nil, status: String? = nil, reason: String? = nil,
        version: String? = nil, createdAt: String? = nil,
        beforeCount: Int? = nil, afterCount: Int? = nil, normalized: Int? = nil,
        archivedDuplicates: Int? = nil, archivedReflections: Int? = nil,
        distilledFactsAdded: Int? = nil, decayedMemories: Int? = nil,
        proposalHygiene: MemoryProposalHygiene? = nil,
        consolidationRunId: String? = nil, nextScheduled: String? = nil
    ) {
        self.id = id
        self.status = status
        self.reason = reason
        self.version = version
        self.createdAt = createdAt
        self.beforeCount = beforeCount
        self.afterCount = afterCount
        self.normalized = normalized
        self.archivedDuplicates = archivedDuplicates
        self.archivedReflections = archivedReflections
        self.distilledFactsAdded = distilledFactsAdded
        self.decayedMemories = decayedMemories
        self.proposalHygiene = proposalHygiene
        self.consolidationRunId = consolidationRunId
        self.nextScheduled = nextScheduled
    }
}

public struct MemoryProposalHygiene: Codable, Hashable {
    public var rejectedLowValue: Int?
    public var nearDuplicates: Int?

    public init(rejectedLowValue: Int? = nil, nearDuplicates: Int? = nil) {
        self.rejectedLowValue = rejectedLowValue
        self.nearDuplicates = nearDuplicates
    }
}
