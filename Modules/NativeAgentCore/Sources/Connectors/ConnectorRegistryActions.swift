import Foundation
import NativeAgentCore
import PersistenceCore
import SlackBot
import TrustCenter
// Blueprint: | `ConnectorRegistryActions.swift` | connector/workspace registry operations and ordered workspace readback verification; Slack disconnect records the person’s decision before credential removal; socket-mode metadata writes delegate to SlackCredentials |

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
    public static func disconnectSlack(root: URL) async throws {
        try SlackCredentials.recoverPendingSave(dataRoot: root)
        // A credential effect alone is not confirmation of the registry change.
        _ = try await ConnectorOAuthRegistry.mutateConnectorRegistryEntry(
            root: root, provider: "slack", createIfMissing: false,
            publish: { _, write in
                try await SlackCredentials.revoke(dataRoot: root, publishRegistry: write)
            }) { entry in
            entry[ConnectorOAuthRegistry.decisionField] = ConnectorOAuthRegistry.ConnectionDecision.disconnected.value
            entry["enabled"] = .bool(false)
            entry["authState"] = .string("not_connected")
            entry[SlackCredentials.generationField] = .string(UUID().uuidString)
            entry["healthStatus"] = .string("planned")
            entry["updatedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(Date()))
        }
    }

    public static func updateConnector(
        id: String,
        enabled: Bool,
        root: URL,
        projection: ConnectorRegistryProjectionPort
    ) async throws -> JSONValue {
        // registry.json uses an array of rows; flock-protected updates also support object-shaped files.
        let normalizedID = ConnectorOAuthRegistry.normalizedConnectorID(id)
        guard let currentEntry = try await ConnectorOAuthRegistry.readConnectorRegistryEntry(
            root: root,
            provider: normalizedID
        ) else {
            throw NSError(domain: "NativeAgentConnectorMutation", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "Connector \(normalizedID) is not registered."
            ])
        }
        let registryToggleOwners: Set<String> = ["local_files", "slack"]
        guard registryToggleOwners.contains(normalizedID) else {
            throw NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(projection.defaultName(normalizedID)) is controlled by its canonical setup surface."
            ])
        }
        if enabled {
            let runtime = projection.overlay(currentEntry, root)
            let health = ConnectorOAuthRegistry.connectorString(runtime["healthStatus"])?.lowercased()
            let hasVerifiedReadiness = normalizedID == "local_files" || health == "ok"
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
            createIfMissing: false,
            publish: { _, write in
                if normalizedID == "slack" {
                    try await SlackCredentials.setSocketModeEnabled(enabled, dataRoot: root, publishRegistry: write)
                } else {
                    try await write()
                }
            }
        ) { entry in
            entry["enabled"] = .bool(enabled)
            entry["updatedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(Date()))
        }
        let overlay = projection.overlay(resultEntry, root)
        return .object(overlay)
    }

    public static func addWorkspace(name: String, path: String, permissions: [String], root: URL) async throws -> (added: WorkspaceRecord, refreshed: [WorkspaceRecord], verified: Bool) {
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
        let now = ISO8601DateFormatter().string(from: Date())
        let record = WorkspaceRecord(
            id: UUID().uuidString,
            name: cleanedName,
            path: requestedURL.path,
            permissions: permissions,
            createdAt: now
        )
        let added = try await SwiftNativePersistenceCore.withFileLock(wsPath) {
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
                let tail = NativeAgentWorkspaceRoot.relativePath(candidate, under: prior)
                if tail == "" {
                    throw workspaceValidationError("That workspace is already registered.")
                }
                if tail != nil || NativeAgentWorkspaceRoot.relativePath(prior, under: candidate) != nil {
                    throw workspaceValidationError("Workspace folders cannot overlap.")
                }
            }
            let rowData = try JSONEncoder().encode(record)
            let row = try JSONSerialization.jsonObject(with: rowData, options: []) as? [String: Any] ?? [:]
            rows.append(row)
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try SwiftNativePersistenceCore.writeDataAtomicDurable(out, to: wsPath)
            return record
        }
        let refreshed = try await listWorkspaces(root: root)
        return (added, refreshed, refreshed.contains { $0.id == added.id })
    }

    private static func workspaceValidationError(_ message: String) -> NSError {
        NSError(domain: "NativeAgentWorkspace", code: 422, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public static func listWorkspaces(root: URL) async throws -> [WorkspaceRecord] {
        let rows = try await SwiftNativeConnectorsClient(root: root).listWorkspaces()
        return try JSONDecoder().decode([WorkspaceRecord].self, from: JSONValue.array(rows).serializedData(pretty: false))
    }

    public static func searchWorkspace(query: String, root: URL) async throws -> WorkspaceSearchResponse {
        try await SwiftNativeConnectorsClient(root: root).searchWorkspaces(query: query)
    }
}

public struct WorkspaceSearchResult: Identifiable, Codable, Hashable, Sendable {
    public var workspaceId: String?
    public var workspaceName: String?
    public var path: String
    public var relativePath: String
    public var reason: String

    public var id: String { path }
}

public struct WorkspaceSearchResponse: Codable, Hashable, Sendable {
    public var query: String
    public var results: [WorkspaceSearchResult]
    /// Scope the search could not examine, "path: why"; absent when it saw all of it.
    public var unexamined: [String]?
}

public struct WorkspaceRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var permissions: [String]
    public var createdAt: String
    public init(id: String, name: String, path: String, permissions: [String], createdAt: String) {
        self.id = id; self.name = name; self.path = path; self.permissions = permissions
        self.createdAt = createdAt
    }
}
