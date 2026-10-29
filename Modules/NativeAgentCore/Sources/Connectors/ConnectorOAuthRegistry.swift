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
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            // Finish an interrupted Slack registry publication before any
            // connector mutation can advance that registry generation.
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            var rows = try readRegistry(at: path)
            let index = rows.firstIndex { connectorRow($0, matches: providerID) }
            guard index != nil || createIfMissing else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "Connector \(providerID) not found in \(path.path)"
                ])
            }
            var entry = index.map { rows[$0] } ?? [:]
            entry["id"] = .string(providerID)
            mutate(&entry)
            if let index { rows[index] = entry } else { rows.append(entry) }
            let updated = JSONValue.array(try checkedConnectorRows(from: .array(rows.map(JSONValue.object))).map(JSONValue.object))
            try await publish(updated) { try writeRegistry(updated, at: path) }
            return entry
        }
    }

    /// Drops the rows `ids` name, under the registry lock; a row that is not
    /// there is nothing to drop.
    public static func removeConnectorRegistryEntries(root: URL, ids: Set<String>) async throws {
        let path = connectorRegistryPath(root: root)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            let rows = try readRegistry(at: path)
            let kept = rows.filter { !ids.contains(normalizedConnectorID(connectorString($0["id"]) ?? "")) }
            guard kept.count != rows.count else { return }
            try writeRegistry(.array(kept.map(JSONValue.object)), at: path)
        }
    }
}
