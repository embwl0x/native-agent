import Foundation

public struct MemoryVectorStatus: Codable, Hashable {
    public var status: String
    public var provider: String?
    public var providerModel: String?
    public var providerConfigured: Bool?
    public var providerReason: String?
    public var dimensions: Int?
    public var nodeCount: Int?
    public var entityCount: Int?
    public var updatedAt: String?
    public var createdAt: String?
    public init(status: String, provider: String? = nil, providerModel: String? = nil, providerConfigured: Bool? = nil, providerReason: String? = nil, dimensions: Int? = nil, nodeCount: Int? = nil, entityCount: Int? = nil, updatedAt: String? = nil, createdAt: String? = nil) {
        self.status = status
        self.provider = provider
        self.providerModel = providerModel
        self.providerConfigured = providerConfigured
        self.providerReason = providerReason
        self.dimensions = dimensions
        self.nodeCount = nodeCount
        self.entityCount = entityCount
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

public struct MemoryV2Status: Codable, Hashable {
    public var status: String
    public var version: String?
    public var embedding: MemoryV2Embedding?
    public var counts: MemoryV2Counts?
    public var hygiene: MemoryHygieneReport?
    public var vault: MemoryVaultStatus?
    public var afterTurn: AfterTurnMemoryRecoveryStatus?
    public var createdAt: String?
    public init(status: String, version: String? = nil, embedding: MemoryV2Embedding? = nil, counts: MemoryV2Counts? = nil, hygiene: MemoryHygieneReport? = nil, vault: MemoryVaultStatus? = nil, afterTurn: AfterTurnMemoryRecoveryStatus? = nil, createdAt: String? = nil) {
        self.status = status
        self.version = version
        self.embedding = embedding
        self.counts = counts
        self.hygiene = hygiene
        self.vault = vault
        self.afterTurn = afterTurn
        self.createdAt = createdAt
    }
}

public struct AfterTurnMemoryRecoveryStatus: Codable, Hashable, Sendable {
    public let status: String
    public let heldCount: Int?
    public let failure: AfterTurnMemoryFailure?

    public var lines: [String] {
        guard let heldCount else {
            return ["Held memory turns could not be read. Repair memory/moments_held.json without discarding its turns; recovery is paused."]
        }
        guard heldCount > 0 else { return [] }
        var result = ["\(heldCount) turns waiting for the memory model. Their held memory opportunities have not become saved memories or review proposals.",
                      "Held turns are reconsidered when the selected memory model next answers successfully.",
                      "Recovery respects enabled memory lanes and the daily moment limit; remaining opportunities stay held."]
        if let failure {
            result.append(failure.detail)
            result.append("Memory route for that failed pass: \(failure.surface) / \(failure.model ?? "unreported").")
        }
        return result
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
    public var noisyReflections: Int?
    public var pendingProposals: Int?
    public init(memories: Int? = nil, active: Int? = nil, pinned: Int? = nil, noisyReflections: Int? = nil, pendingProposals: Int? = nil) {
        self.memories = memories
        self.active = active
        self.pinned = pinned
        self.noisyReflections = noisyReflections
        self.pendingProposals = pendingProposals
    }
}

public struct MemoryVaultStatus: Codable, Hashable {
    public var status: String?
    public var encrypted: Bool?
    public var itemCount: Int?
    public var detail: String?
    public init(status: String? = nil, encrypted: Bool? = nil, itemCount: Int? = nil, detail: String? = nil) {
        self.status = status
        self.encrypted = encrypted
        self.itemCount = itemCount
        self.detail = detail
    }
}
