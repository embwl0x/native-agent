import Foundation
import GitHubConnector
import NativeAgentCore
import PersistenceCore
import SlackConnector
import TrustCenter

/// Local connector credential revocation and registry updates. OAuth token
/// exchange and sign-in persistence belong to the app's NativeOAuthFlow.
public final class SwiftNativeConnectorAuthClient: Sendable {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.root = root
        self.persistence = persistence
    }

    private var connectorsPath: URL {
        root.appendingPathComponent("connectors/registry.json")
    }

    private func tokenPath(_ provider: String) -> URL {
        root.appendingPathComponent("oauth_tokens").appendingPathComponent("\(provider).json")
    }

    private func tokenPaths(_ provider: String) -> [URL] {
        let canonical = ConnectorProofLedger.canonicalID(provider)
        return [
            tokenPath(provider),
            tokenPath(canonical),
            root.appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent(canonical, isDirectory: true)
                .appendingPathComponent("auth.json"),
        ]
    }

    /// Providers recognized by this registry mutation boundary.
    private static let knownProviders: Set<String> = [
        "github", "email", "gmail", "calendar", "gcal", "google_calendar",
        "notion", "slack", "x", "twitter",
    ]

    public func revokeConnector(provider: String) async throws -> JSONValue {
        guard Self.knownProviders.contains(provider) else {
            throw ConnectorAuthError.unknownProvider(provider)
        }
        if provider == "slack" { try SlackCredentials.recoverPendingSave(dataRoot: root) }
        try await updateRegistry(provider: provider)
        if provider == "github" { try await GitHubCredentialStore.shared.deleteCredential(dataRoot: root) }

        return .object([
            "ok": .bool(true),
            "provider": .string(provider),
            "revoked": .bool(true),
        ])
    }

    private func updateRegistry(provider: String) async throws {
        // A credential effect alone is not confirmation of the registry change.
        try await persistence.withFileLock(connectorsPath) { [self] in
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            // 2026-09-06: this operation only updates an existing registry.
            // Missing or damaged bytes are never permission to replace it with an empty array.
            let raw = try JSONValue.parse(Data(contentsOf: connectorsPath))
            let rows = try ConnectorOAuthRegistry.checkedConnectorRows(from: raw)
            guard rows.contains(where: { ConnectorProofLedger.canonicalID(Self.idString($0["id"])) == ConnectorProofLedger.canonicalID(provider) }) else {
                throw ConnectorAuthError.unknownProvider(provider)
            }
            func updatedEntry(_ entry: JSONValue, keyedBy key: String? = nil) throws -> JSONValue {
                guard case .object(var obj) = entry else {
                    throw PersistenceCoreError.ioFailure("Connector registry contains a non-object entry")
                }
                if ConnectorProofLedger.canonicalID(key ?? Self.idString(obj["id"])) == ConnectorProofLedger.canonicalID(provider) {
                    obj["enabled"] = .bool(false)
                    obj["authState"] = .string("not_connected")
                    obj["healthStatus"] = .string("planned")
                    obj["updatedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(Date()))
                }
                return .object(obj)
            }
            let updated: JSONValue
            switch raw {
            case .array(let connectors):
                updated = .array(try connectors.map { try updatedEntry($0) })
            case .object(var connectors):
                // Legacy registries identify rows by their keys, as the
                // canonical registry owner does. Preserve keys and shape.
                for (key, entry) in connectors {
                    connectors[key] = try updatedEntry(entry, keyedBy: key)
                }
                updated = .object(connectors)
            default:
                throw PersistenceCoreError.ioFailure("Connector registry is not an array or object")
            }
            let paths = Array(Set(tokenPaths(provider))).sorted { $0.path < $1.path }
            try await withCredentialLocks(paths[...]) {
                for path in paths {
                    _ = try ConnectorOAuthRegistry.checkedCredentialObject(at: path, resolveSecrets: false)
                }
                try await self.persistence.writeJSON(updated, to: self.connectorsPath)
                // Keep the reference file and registry locks until its
                // Keychain grant is removed; unlinking first loses the reference.
                if provider == "slack" { try SlackCredentials.delete(dataRoot: self.root) }
                // All saved inputs have passed validation and the durable
                // disabled row exists before the first destructive step.
                for path in paths where FileManager.default.fileExists(atPath: path.path) {
                    try ConnectorCredentialFile.remove(at: path)
                }
            }
        }
    }

    private func withCredentialLocks(
        _ paths: ArraySlice<URL>,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let path = paths.first else { return try await operation() }
        try await persistence.withFileLock(path) {
            try await self.withCredentialLocks(paths.dropFirst(), operation: operation)
        }
    }

    /// Preserve the stored scalar ID spelling, including Python-style booleans
    /// and null. Unknown shapes cannot match a provider.
    private static func idString(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        case .null: return "None"
        default: return ""
        }
    }
}

public enum ConnectorAuthError: Error, Sendable, Equatable {
    /// The provider is not recognized by the registry mutation boundary.
    case unknownProvider(String)
}
