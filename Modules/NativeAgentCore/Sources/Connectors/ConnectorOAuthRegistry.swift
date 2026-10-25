import Foundation
import PersistenceCore
import SlackBot
// Blueprint: | `ConnectorOAuthRegistry.swift` | Canonical connector row edits, including revocation; extends PersistenceCore's checked registry owner with `mutateConnectorRegistryEntry`, `removeConnectorRegistryEntries` |

extension ConnectorOAuthRegistry {
    public static func mutateConnectorRegistryEntry(
        root: URL,
        provider: String,
        createIfMissing: Bool,
        publish: @escaping @Sendable (JSONValue, @Sendable () async throws -> Void) async throws -> Void = { _, write in try await write() },
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
            // Finish an interrupted Slack registry publication before any
            // connector mutation can advance that registry generation.
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            let current = try readRegistry(at: path)
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
                    let updated = JSONValue.array(rows)
                    try await publish(updated) { try writeRegistry(updated, at: path) }
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
                let updated = JSONValue.array(rows)
                try await publish(updated) { try writeRegistry(updated, at: path) }
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
                let updated = JSONValue.object(object)
                try await publish(updated) { try writeRegistry(updated, at: path) }
                return entry
            default:
                throw PersistenceCoreError.ioFailure("Connector registry is not an array or object")
            }
        }
    }

    /// Drops the rows `ids` name, under the registry lock; a row that is not
    /// there is nothing to drop.
    public static func removeConnectorRegistryEntries(root: URL, ids: Set<String>) async throws {
        let path = connectorRegistryPath(root: root)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            let left: JSONValue
            switch try readRegistry(at: path) {
            case .array(let rows):
                let kept = rows.filter { row in
                    guard case .object(let fields) = row else { return true }
                    return !ids.contains(normalizedConnectorID(connectorString(fields["id"]) ?? ""))
                }
                guard kept.count != rows.count else { return }
                left = .array(kept)
            case .object(let rows):
                let kept = rows.filter { !ids.contains(normalizedConnectorID($0.key)) }
                guard kept.count != rows.count else { return }
                left = .object(kept)
            default: return
            }
            try writeRegistry(left, at: path)
        }
    }
}
