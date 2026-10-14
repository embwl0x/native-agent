import Foundation
import Connectors

public struct ConnectorActionRegistry: Codable, Hashable, Sendable {
    public var status: String
    public var actions: [ConnectorActionRecord]
    public var receiptCount: Int?
    public var latestReceipt: ConnectorActionReceipt?
    public var createdAt: String?

    /// The static connector action manifest with the same non-secret
    /// readiness overlay the connector list uses, and the newest of its last
    /// 50 receipts. A failed connector read propagates: it is a read failure,
    /// not an unavailable registry.
    public static func read(dataRoot: URL, platform: any ConnectorStatusPlatform) async throws -> ConnectorActionRegistry {
        let connectors = try await ConnectorStatusProjection.readConnectorRecords(
            root: dataRoot, platform: platform
        )
        return await read(dataRoot: dataRoot, connectors: connectors)
    }

    public static func read(dataRoot: URL, connectors: [ConnectorRecord]) async -> ConnectorActionRegistry {
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

extension ConnectorActionRecord {
    /// Each action's capability status for TrustCenter: active when its
    /// connector is ready, else the connector's state or needs_setup.
    public static func checkedStatuses(root: URL, platform: any ConnectorStatusPlatform) async throws -> [String: String] {
        let connectors = try await ConnectorStatusProjection.readConnectorRecords(
            root: root, platform: platform
        )
        let ready: Set<String> = ["active", "ready", "ok", "healthy", "connected"]
        return Dictionary(uniqueKeysWithValues: records(connectors: connectors).map { action in
            let status = action.connectorStatus ?? "needs_setup"
            let capabilityStatus = action.enabled == true
                ? (ready.contains(status) ? "active" : status) : "needs_setup"
            return (action.id, capabilityStatus)
        })
    }
}
