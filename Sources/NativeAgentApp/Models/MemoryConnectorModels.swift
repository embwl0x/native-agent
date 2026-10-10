import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import MemoryV2
import Connectors
import TrustCenter

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

    /// The static connector action manifest with the same non-secret
    /// readiness overlay the connector list uses, and the newest of its last
    /// 50 receipts. A failed connector read propagates: it is a read failure,
    /// not an unavailable registry.
    static func read(dataRoot: URL) async throws -> ConnectorActionRegistry {
        let connectors = try await ConnectorStatusProjection.readConnectorRecords(
            root: dataRoot, platform: AppConnectorStatusPlatform()
        )
        let actions = ConnectorActionRecord.records(connectors: connectors)
        let receiptsPath = dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        let receipts: [ConnectorActionReceipt] = await RuntimeReadProjection.tailJSONL(path: receiptsPath, limit: 50)
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return ConnectorActionRegistry(
            status: actions.isEmpty ? "unavailable" : "ready",
            actions: actions,
            receiptCount: receipts.count,
            latestReceipt: receipts.first,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }
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

extension ConnectorActionRecord {
    /// Each action's capability status for TrustCenter: active when its
    /// connector is ready, else the connector's state or needs_setup.
    static func checkedStatuses(root: URL) async throws -> [String: String] {
        let connectors = try await ConnectorStatusProjection.readConnectorRecords(
            root: root, platform: AppConnectorStatusPlatform()
        )
        let ready: Set<String> = ["active", "ready", "ok", "healthy", "connected"]
        return Dictionary(uniqueKeysWithValues: records(connectors: connectors).map { action in
            let status = action.connectorStatus ?? "needs_setup"
            let capabilityStatus = action.enabled == true
                ? (ready.contains(status) ? "active" : status) : "needs_setup"
            return (action.id, capabilityStatus)
        })
    }

    /// One record per connector action descriptor, its readiness overlaid
    /// from the connector registry (native connectors read as active).
    static func records(connectors: [ConnectorRecord]) -> [ConnectorActionRecord] {
        var byID: [String: ConnectorRecord] = [:]
        for connector in connectors {
            byID[ConnectorStatusProjection.normalizedConnectorID(connector.id)] = connector
        }
        let nativeConnectors: Set<String> = [
            "mobile", "scheduler", "mac", "mac_assistant",
            "local_files", "codex_work", "codex_handoff",
            "markets",
        ]
        return connectorActionDescriptors().map { descriptor in
            let key = ConnectorStatusProjection.normalizedConnectorID(descriptor.connectorId)
            let connector = byID[key]
            let enabled = connector?.enabled ?? nativeConnectors.contains(key)
            let connectorStatus = connector?.healthStatus ?? (enabled ? "active" : "needs_setup")
            let authState = connector?.authState ?? (enabled ? "not_required" : "not_connected")
            return ConnectorActionRecord(
                id: descriptor.id,
                connectorId: descriptor.connectorId,
                name: descriptor.name ?? descriptor.id,
                risk: descriptor.risk,
                dryRunAvailable: descriptor.dryRunAvailable,
                requiresApproval: descriptor.requiresApproval,
                connectorStatus: connectorStatus,
                authState: authState,
                enabled: enabled
            )
        }
    }
}

typealias ConnectorActionReceipt = Connectors.ConnectorActionReceipt
