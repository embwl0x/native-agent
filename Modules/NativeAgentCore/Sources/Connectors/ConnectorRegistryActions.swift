import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// Checked status projection supplied by the higher-level status owner.
public struct ConnectorRegistryProjectionPort: Sendable {
    public let defaultName: @Sendable (String) -> String
    public let overlay: @Sendable ([String: JSONValue], URL) -> [String: JSONValue]
    public init(
        defaultName: @escaping @Sendable (String) -> String,
        overlay: @escaping @Sendable ([String: JSONValue], URL) -> [String: JSONValue]
    ) {
        self.defaultName = defaultName
        self.overlay = overlay
    }
}

public enum ConnectorRegistryActions {
    public static func updateConnector(
        id: String,
        enabled: Bool,
        root: URL,
        projection: ConnectorRegistryProjectionPort
    ) async throws -> JSONValue {
        // DAEMON-DEAD PORT (2026-06-03): registry.json is canonically an array
        // of connector rows. Preserve that shape and update the matching row
        // under flock; older object-shaped files are still supported.
        let normalizedID = ConnectorOAuthRegistry.normalizedConnectorID(id)
        guard let currentEntry = try await ConnectorOAuthRegistry.readConnectorRegistryEntry(
            root: root,
            provider: normalizedID
        ) else {
            throw NSError(domain: "NativeAgentConnectorMutation", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "Connector \(normalizedID) is not registered."
            ])
        }
        let registryToggleOwners: Set<String> = [
            "local_files", "github", "slack", "notion", "gmail", "gcal", "x",
        ]
        guard registryToggleOwners.contains(normalizedID) else {
            throw NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(projection.defaultName(normalizedID)) is controlled by its canonical setup surface."
            ])
        }
        if enabled {
            let runtime = projection.overlay(currentEntry, root)
            let auth = ConnectorOAuthRegistry.connectorString(runtime["authState"])?.lowercased()
            let health = ConnectorOAuthRegistry.connectorString(runtime["healthStatus"])?.lowercased()
            let hasVerifiedReadiness = auth == "connected"
                || auth == "configured"
                || health == "ok"
                || normalizedID == "local_files"
            guard hasVerifiedReadiness else {
                throw NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Configure and verify \(projection.defaultName(normalizedID)) before enabling it."
                ])
            }
        }
        let resultEntry = try await ConnectorOAuthRegistry.mutateConnectorRegistryEntry(
            root: root,
            provider: normalizedID,
            createIfMissing: false
        ) { entry in
            entry["enabled"] = .bool(enabled)
            entry["updatedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(Date()))
        }
        let overlay = projection.overlay(resultEntry, root)
        return .object(overlay)
    }

    public static func addWorkspace(name: String, path: String, permissions: [String], root: URL) async throws -> WorkspaceRecord {
        // DAEMON-DEAD PORT P4: append a new row to <dataRoot>/connectors/
        // workspaces.json under flock. Matches the reader path in
        // Connectors.swift L132.
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            throw workspaceValidationError("Enter a workspace name.")
        }
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw workspaceValidationError("Workspace path must be an existing folder.")
        }
        let resolvedURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path == requestedURL.path else {
            throw workspaceValidationError("Workspace paths cannot use symlinks.")
        }

        let wsPath = root.appendingPathComponent("connectors/workspaces.json")
        let core = SwiftNativePersistenceCore()
        let now = ISO8601DateFormatter().string(from: Date())
        let record = WorkspaceRecord(
            id: UUID().uuidString,
            name: cleanedName,
            path: requestedURL.path,
            permissions: permissions,
            createdAt: now,
            lastUsedAt: nil
        )
        return try await core.withFileLock(wsPath) {
            let fm = FileManager.default
            try fm.createDirectory(at: wsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            var rows: [[String: Any]] = []
            let exists: Bool
            do {
                _ = try fm.attributesOfItem(atPath: wsPath.path)
                exists = true
            } catch CocoaError.fileReadNoSuchFile {
                exists = false
            }
            if exists {
                let data = try Data(contentsOf: wsPath)
                guard let arr = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
                    throw workspaceValidationError("Saved workspaces must be an array of objects.")
                }
                rows = arr
            }
            for existing in rows {
                guard let existingPath = existing["path"] as? String, !existingPath.isEmpty else { continue }
                let existingURL = URL(fileURLWithPath: existingPath).standardizedFileURL
                let candidate = requestedURL.path
                let prior = existingURL.path
                if candidate == prior {
                    throw workspaceValidationError("That workspace is already registered.")
                }
                if candidate.hasPrefix(prior + "/") || prior.hasPrefix(candidate + "/") {
                    throw workspaceValidationError("Workspace folders cannot overlap.")
                }
            }
            let rowData = try JSONEncoder().encode(record)
            let row = try JSONSerialization.jsonObject(with: rowData, options: []) as? [String: Any] ?? [:]
            rows.append(row)
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try out.write(to: wsPath, options: .atomic)
            return record
        }
    }

    private static func workspaceValidationError(_ message: String) -> NSError {
        NSError(domain: "NativeAgentWorkspace", code: 422, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public static func searchWorkspace(query: String, root: URL) async throws -> JSONValue {
        let impl = makeConnectorsClient(root: root)
        if let envelope = try await impl.searchWorkspaces(query: query) {
            return envelope
        }
        return .object(["query": .string(query), "results": .array([])])
    }
}

public struct WorkspaceRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var permissions: [String]
    public var createdAt: String
    public var lastUsedAt: String?
    public init(id: String, name: String, path: String, permissions: [String], createdAt: String, lastUsedAt: String?) {
        self.id = id; self.name = name; self.path = path; self.permissions = permissions
        self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
    }
}
