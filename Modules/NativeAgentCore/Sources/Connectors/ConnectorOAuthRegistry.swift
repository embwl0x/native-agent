import Foundation
import PersistenceCore

public enum ConnectorOAuthRegistry {
    public static func mutateConnectorRegistryEntry(
        root: URL,
        provider: String,
        createIfMissing: Bool,
        prepare: @escaping @Sendable () async throws -> Void = {},
        publish: @escaping @Sendable (@Sendable () async throws -> Void) async throws -> Void = { try await $0() },
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> Void
    ) async throws -> [String: JSONValue] {
        let providerID = normalizedConnectorID(provider)
        guard !providerID.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "Connector provider id is empty"
            ])
        }
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(path) {
            let current = try readRegistry(at: path)
            _ = try checkedConnectorRows(from: current)
            switch current {
            case .array(var rows):
                for idx in rows.indices {
                    guard case .object(var entry) = rows[idx],
                          connectorRow(entry, matches: providerID)
                    else { continue }
                    entry["id"] = .string(providerID)
                    mutate(&entry)
                    rows[idx] = .object(entry)
                    _ = try checkedConnectorRows(from: .array(rows))
                    try await prepare()
                    let updated = JSONValue.array(rows)
                    try await publish { try await persistence.writeJSON(updated, to: path) }
                    return entry
                }
                guard createIfMissing else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                        NSLocalizedDescriptionKey: "Connector \(providerID) not found in \(path.path)"
                    ])
                }
                var entry: [String: JSONValue] = ["id": .string(providerID)]
                mutate(&entry)
                rows.append(.object(entry))
                _ = try checkedConnectorRows(from: .array(rows))
                try await prepare()
                let updated = JSONValue.array(rows)
                try await publish { try await persistence.writeJSON(updated, to: path) }
                return entry
            case .object(var object):
                var entry: [String: JSONValue]
                if case .object(let existing)? = object[providerID] {
                    entry = existing
                } else if let matchedKey = object.keys.first(where: { normalizedConnectorID($0) == providerID }),
                          case .object(let existing)? = object[matchedKey] {
                    entry = existing
                    object.removeValue(forKey: matchedKey)
                } else {
                    guard createIfMissing else {
                        throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                            NSLocalizedDescriptionKey: "Connector \(providerID) not found in \(path.path)"
                        ])
                    }
                    entry = [:]
                }
                entry["id"] = .string(providerID)
                mutate(&entry)
                object[providerID] = .object(entry)
                _ = try checkedConnectorRows(from: .object(object))
                try await prepare()
                let updated = JSONValue.object(object)
                try await publish { try await persistence.writeJSON(updated, to: path) }
                return entry
            default:
                throw PersistenceCoreError.ioFailure("Connector registry is not an array or object")
            }
        }
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

    public static func readRegistry(at path: URL) throws -> JSONValue {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile { return .array([]) }
        let value = try JSONValue.parse(Data(contentsOf: path))
        _ = try checkedConnectorRows(from: value)
        return value
    }

    /// Credential and OAuth app files are authority too. Only absence permits
    /// creation; callers retain their path lock through publication or unlink.
    public static func checkedCredentialObject(at path: URL) throws -> [String: JSONValue] {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
        guard case .object(let object) = try JSONValue.parse(Data(contentsOf: path)) else {
            throw PersistenceCoreError.ioFailure("Saved connector credentials must be a JSON object")
        }
        for field in ["access_token", "refresh_token", "oauth_token", "token", "token_type", "scope",
                      "client_id", "client_secret", "connector_id", "redirect_uri", "provider",
                      "saved_at", "validated_at", "credential_store", "auth_mode", "bot_token", "app_token",
                      "socket_mode_app_token", "team_id", "team", "url", "user", "bot_id", "enterprise_id",
                      "login", "name", "html_url", "type", "account_id", "refresh_token_account_id",
                      "account_sub", "refresh_token_account_sub"] {
            guard let value = object[field] else { continue }
            guard case .string = value else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be a string")
            }
        }
        if let value = object["user_id"] {
            switch value {
            case .string, .int: break // Slack IDs are strings; GitHub IDs are integers.
            default: throw PersistenceCoreError.ioFailure("Saved connector user_id must be a string or integer")
            }
        }
        if let value = object["credential_version"], case .int = value {} else if object["credential_version"] != nil {
            throw PersistenceCoreError.ioFailure("Saved connector credential_version must be an integer")
        }
        for field in ["socket_mode_enabled", "require_mention"] {
            guard let value = object[field] else { continue }
            guard case .bool = value else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be a boolean")
            }
        }
        for field in ["allowed_channel_ids", "allowed_user_ids"] {
            guard let value = object[field] else { continue }
            guard case .array(let ids) = value,
                  ids.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) must be an array of strings")
            }
        }
        for field in ["expires_at", "expires_in"] {
            guard let value = object[field] else { continue }
            switch value {
            case .string, .int, .double: break
            default: throw PersistenceCoreError.ioFailure("Saved connector credential field \(field) has an invalid type")
            }
        }
        return object
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
