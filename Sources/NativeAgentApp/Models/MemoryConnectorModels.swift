import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct MemoryVectorStatus: Codable, Hashable {
    var status: String
    var provider: String?
    var providerModel: String?
    var providerConfigured: Bool?
    var providerReason: String?
    var dimensions: Int?
    var nodeCount: Int?
    var entityCount: Int?
    var updatedAt: String?
    var createdAt: String?
}

struct MemoryV2Status: Codable, Hashable {
    var status: String
    var version: String?
    var embedding: MemoryV2Embedding?
    var counts: MemoryV2Counts?
    var hygiene: MemoryHygieneReport?
    var vault: MemoryVaultStatus?
    var createdAt: String?
}

struct MemoryV2Embedding: Codable, Hashable {
    var activeBackend: String?
    var realSemanticAvailable: Bool?
    var fallbackReason: String?
}

struct MemoryV2Counts: Codable, Hashable {
    var memories: Int?
    var active: Int?
    var pinned: Int?
    var noisyReflections: Int?
    var pendingProposals: Int?
}

struct MemoryHygieneReport: Codable, Hashable {
    var id: String?
    var status: String?
    var reason: String?
    var version: String?
    var createdAt: String?
    var beforeCount: Int?
    var afterCount: Int?
    var normalized: Int?
    var archivedDuplicates: Int?
    var archivedReflections: Int?
    var distilledFactsAdded: Int?
    var decayedMemories: Int?
    var proposalHygiene: MemoryProposalHygiene?
    /// F2: surfaced by readHygieneLastRun — ISO8601 of the next cadence-driven
    /// run (weekly: createdAt + 7d, matching the runner's card-staging
    /// cadence). nil if no last-run anchor is on disk.
    var nextScheduled: String?
}

struct MemoryProposalHygiene: Codable, Hashable {
    var rejectedLowValue: Int?
    var nearDuplicates: Int?
}

struct MemoryVaultStatus: Codable, Hashable {
    var status: String?
    var encrypted: Bool?
    var itemCount: Int?
    var detail: String?
}

struct ConnectorActionRegistry: Codable, Hashable {
    var status: String
    var actions: [ConnectorActionRecord]
    var receiptCount: Int?
    var latestReceipt: ConnectorActionReceipt?
    var createdAt: String?
}

struct ConnectorActionRecord: Identifiable, Codable, Hashable {
    var id: String
    var connectorId: String?
    var name: String
    var risk: String?
    var dryRunAvailable: Bool?
    var requiresApproval: Bool?
    var connectorStatus: String?
    var authState: String?
    var enabled: Bool?
}

struct ConnectorActionReceipt: Identifiable, Codable, Hashable {
    var id: String
    var actionId: String
    var connectorId: String?
    var name: String?
    var status: String
    var dryRun: Bool?
    var approvalId: String?
    var createdAt: String?
}
