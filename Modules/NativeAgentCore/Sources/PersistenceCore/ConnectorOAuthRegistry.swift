import Foundation
// Blueprint: | `ConnectorOAuthRegistry.swift` | Sole checked connector registry reader/schema and durable publication owner (`writeRegistry`), including bootstrap and Slack recovery; canonical IDs and `connectionDecision`. A connection decision is recorded only by the person's own connect or disconnect; seeds, first reads and migrations are undecided, and missing decision fields read as undecided without inferring from enabled/authState. `permitsCredentialMigration` reads only that decision: connected or undecided may migrate; a recorded person-disconnect never does. Malformed authority throws |

/// Checked connector registry authority, shared by mutations and credential migration.
public enum ConnectorOAuthRegistry {
    /// Only the person's own connect or disconnect records a choice. Catalog
    /// seeds, first reads and migrations are undecided, never inferred from health or enabled.
    public enum ConnectionDecision: String, Sendable {
        case undecided, connected, disconnected
        public var value: JSONValue { .string(rawValue) }
    }
    public static let decisionField = "connectionDecision"

    /// Only the recorded decision governs migration: connected or undecided may
    /// migrate credentials; a recorded person-disconnect never may.
    /// Caller holds the registry lock through any resulting import or retirement.
    public static func permitsCredentialMigration(root: URL, provider: String) throws -> Bool {
        let rows = try checkedConnectorRows(from: readRegistry(at: connectorRegistryPath(root: root)))
        guard let row = rows.first(where: { connectorRow($0, matches: normalizedConnectorID(provider)) }) else { return true }
        return row[decisionField] != ConnectionDecision.disconnected.value
    }

    /// Validate the entire authority before projecting or changing any row.
    /// Missing legacy fields are supported; present fields must keep their type.
    public static func checkedConnectorRows(from value: JSONValue) throws -> [[String: JSONValue]] {
        let entries: [(String?, JSONValue)]
        switch value {
        case .array(let rows): entries = rows.map { (nil, $0) }
        case .object(let rows): entries = rows.keys.sorted().map { ($0, rows[$0]!) }
        default: throw PersistenceCoreError.ioFailure("Connector registry is not an array or object")
        }
        var ids = Set<String>()
        return try entries.map { key, value in
            guard case .object(var row) = value else {
                throw PersistenceCoreError.ioFailure("Connector registry contains a non-object entry")
            }
            if row["id"] == nil, let key { row["id"] = .string(normalizedConnectorID(key)) }
            guard let rawID = connectorString(row["id"]), !normalizedConnectorID(rawID).isEmpty,
                  key == nil || normalizedConnectorID(key!) == normalizedConnectorID(rawID),
                  ids.insert(normalizedConnectorID(rawID)).inserted else {
                throw PersistenceCoreError.ioFailure("Connector registry has a missing, conflicting or duplicate id")
            }
            if row[decisionField] == nil { row[decisionField] = ConnectionDecision.undecided.value }
            guard let decision = connectorString(row[decisionField]), ConnectionDecision(rawValue: decision) != nil else {
                throw PersistenceCoreError.ioFailure("Connector registry connectionDecision must be undecided, connected or disconnected")
            }
            for field in ["enabled", "registered", "connected", "client_id_present", "clientIdPresent"] {
                if let value = row[field], case .bool = value {} else if row[field] != nil {
                    throw PersistenceCoreError.ioFailure("Connector registry field \(field) must be a boolean")
                }
            }
            for field in ["name", "kind", "description", "authState", "healthStatus", "riskClass",
                          "lastCheckedAt", "updatedAt", "registered_at", "registeredAt", "connected_at", "connectedAt",
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

    /// Sole registry publication owner, including bootstrap and Slack recovery.
    /// Caller holds the registry lock across its read/edit/write transaction.
    public static func writeRegistry(_ value: JSONValue, at path: URL) throws {
        _ = try checkedConnectorRows(from: value)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(value.serializedData(pretty: true), to: path)
    }

    public static func readRegistry(at path: URL) throws -> JSONValue {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile { return .array([]) }
        let value = try JSONValue.parse(Data(contentsOf: path))
        let rows = try checkedConnectorRows(from: value).map(JSONValue.object)
        if case .object(let entries) = value {
            return .object(Dictionary(uniqueKeysWithValues: zip(entries.keys.sorted(), rows)))
        }
        return .array(rows)
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
