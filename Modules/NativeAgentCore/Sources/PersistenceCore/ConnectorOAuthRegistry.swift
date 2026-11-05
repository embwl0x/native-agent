import Foundation
// Blueprint: | `ConnectorOAuthRegistry.swift` | `writeRegistry`, `connectionDecision`; Only owner acts record consent. |

public enum ConnectorOAuthRegistry {
    /// Only the person's connect or disconnect records consent; seeds and health cannot imply it.
    public enum ConnectionDecision: String, Sendable {
        case undecided, connected, disconnected
        public var value: JSONValue { .string(rawValue) }
    }
    public static let decisionField = "connectionDecision"

    /// Check the entire current array before use; pre-decision rows remain undecided until the owner records consent.
    public static func checkedConnectorRows(from value: JSONValue) throws -> [[String: JSONValue]] {
        guard case .array(let entries) = value else {
            throw PersistenceCoreError.ioFailure(
                "Connector registry must be an array of current connector rows. Preserve and convert the file before continuing.")
        }
        var ids = Set<String>()
        return try entries.map { value in
            guard case .object(var row) = value else {
                throw PersistenceCoreError.ioFailure("Connector registry contains a non-object entry")
            }
            guard let rawID = connectorString(row["id"]), !normalizedConnectorID(rawID).isEmpty,
                  ids.insert(normalizedConnectorID(rawID)).inserted else {
                throw PersistenceCoreError.ioFailure("Connector registry has a missing, conflicting or duplicate id")
            }
            if row[decisionField] == nil { row[decisionField] = ConnectionDecision.undecided.value }
            guard let decision = connectorString(row[decisionField]), ConnectionDecision(rawValue: decision) != nil else {
                throw PersistenceCoreError.ioFailure("Connector registry connectionDecision must be undecided, connected or disconnected")
            }
            for field in ["enabled", "registered", "connected", "client_id_present"] {
                if let value = row[field], case .bool = value {} else if row[field] != nil {
                    throw PersistenceCoreError.ioFailure("Connector registry field \(field) must be a boolean")
                }
            }
            for field in ["name", "kind", "description", "authState", "healthStatus", "riskClass",
                          "lastCheckedAt", "updatedAt", "connectedAt",
                          "runtimeStatus", "runtimeDetail", "runtimeUpdatedAt"] {
                guard let value = row[field] else { continue }
                if case .string = value { continue }
                if value == .null, !["name", "kind", "description"].contains(field) { continue }
                throw PersistenceCoreError.ioFailure("Connector registry field \(field) must be a string")
            }
            for field in ["permissions", "actions"] {
                guard let value = row[field], value != .null else { continue }
                guard case .array(let values) = value,
                      values.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                    throw PersistenceCoreError.ioFailure("Connector registry field \(field) must be an array of strings")
                }
            }
            return row
        }
    }

    public static func connectorRegistryPath(root: URL) -> URL {
        root.appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("registry.json")
    }

    /// Sole registry publication owner, including bootstrap. Caller holds the registry lock across its read/edit/write transaction.
    public static func writeRegistry(_ value: JSONValue, at path: URL) throws {
        let rows = try checkedConnectorRows(from: value).map(JSONValue.object)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue.array(rows).serializedData(pretty: true), to: path)
    }

    public static func readRegistry(at path: URL) throws -> [[String: JSONValue]] {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile { return [] }
        let value = try JSONValue.parse(Data(contentsOf: path))
        return try checkedConnectorRows(from: value)
    }

    public static func connectorRow(_ row: [String: JSONValue], matches providerID: String) -> Bool {
        guard let id = connectorString(row["id"]) else { return false }
        return normalizedConnectorID(id) == providerID
    }

    public static func normalizedConnectorID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func connectorString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value { return string }
        return nil
    }
}
