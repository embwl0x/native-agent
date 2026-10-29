import Foundation
import Connectors
import PersistenceCore
// Blueprint: | `ConnectorStatusProjection+Actions.swift` | connector action registry, records and checked capability statuses |

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
    public static func read(dataRoot: URL, platform: AppConnectorStatusPlatform) async throws -> ConnectorActionRegistry {
        let connectors = try await ConnectorReadiness.readConnectorRecords(
            root: dataRoot, platform: platform
        )
        return try await read(dataRoot: dataRoot, connectors: connectors)
    }

    public static func read(dataRoot: URL, connectors: [ConnectorRecord]) async throws -> ConnectorActionRegistry {
        let actions = ConnectorActionRecord.records(connectors: connectors)
        let receiptsPath = ConnectorActionReceipt.receiptsPath(root: dataRoot)
        let read: (rows: [ConnectorActionReceipt], malformedRows: Int, blankRows: Int, truncated: Bool, readFailed: Bool, failure: String?) =
            await RuntimeReadouts.tailJSONL(path: receiptsPath, limit: 50)
        if let failure = read.failure { throw RuntimeReadError.unreadableFeed(failure) }
        let receipts = read.rows.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
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
    public static func checkedStatuses(root: URL, platform: AppConnectorStatusPlatform) async throws -> [String: String] {
        let connectors = try await ConnectorReadiness.readConnectorRecords(
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
