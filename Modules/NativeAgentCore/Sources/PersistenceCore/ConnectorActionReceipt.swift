import Foundation
// Blueprint: | `ConnectorActionReceipt.swift` | Sole capped receipt writer; health projects outcomes. |

/// Health projects outcomes without raw receipt rows; backup retains them but production export excludes them.
public struct ConnectorActionReceipt: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var actionId: String
    public var connectorId: String?
    public var name: String?
    public var status: String
    public var dryRun: Bool?
    public var approvalId: String?
    public var createdAt: String?

    public static func receiptsPath(root: URL) -> URL {
        root.appendingPathComponent("connectors/actions/receipts.jsonl")
    }

    public static func append(
        actionId: String, connectorId: String, name: String?, status: String, ok: Bool?,
        dryRun: Bool, approvalId: String?, createdAt: String, output: JSONValue, dataRoot: URL
    ) async throws -> ConnectorActionReceipt {
        let receipt = ConnectorActionReceipt(
            id: UUID().uuidString.lowercased(), actionId: actionId,
            connectorId: connectorId, name: name, status: status,
            dryRun: dryRun, approvalId: approvalId, createdAt: createdAt
        )
        let record: JSONValue = .object([
            "id": .string(receipt.id), "actionId": .string(actionId),
            "connectorId": .string(connectorId), "name": .string(name ?? actionId),
            "status": .string(status), "dryRun": .bool(dryRun),
            "approvalId": approvalId.map(JSONValue.string) ?? .null,
            "createdAt": .string(createdAt), "ok": ok.map(JSONValue.bool) ?? .null,
            "output": output,
        ])
        try await appendJSONLCapped(record, to: receiptsPath(root: dataRoot),
            maxLines: JSONLLineCaps.actionReceipts,
            logLabel: "NativeClient.connectorAction")
        return receipt
    }
}
