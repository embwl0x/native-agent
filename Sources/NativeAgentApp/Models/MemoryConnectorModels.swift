import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import MemoryV2
import Connectors

typealias MemoryVectorStatus = MemoryV2.MemoryVectorStatus

typealias MemoryV2Status = MemoryV2.MemoryV2Status

typealias MemoryV2Embedding = MemoryV2.MemoryV2Embedding

typealias MemoryV2Counts = MemoryV2.MemoryV2Counts

typealias MemoryVaultStatus = MemoryV2.MemoryVaultStatus

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

typealias ConnectorActionReceipt = Connectors.ConnectorActionReceipt
