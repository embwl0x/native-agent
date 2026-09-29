import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// Local connector credential revocation and registry updates. OAuth token
/// exchange and sign-in persistence belong to the app's NativeOAuthFlow.
public protocol ConnectorAuthClient: Sendable {
    /// Mark the registry entry disabled before unlinking credentials under their
    /// path locks. Registry write failure leaves credentials untouched.
    func revokeConnector(provider: String) async throws -> JSONValue

    /// Mark an existing provider connected only after a usable token is saved.
    func connectConnector(provider: String) async throws -> JSONValue
}

public final class SwiftNativeConnectorAuthClient: ConnectorAuthClient {
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
        let canonical: String = switch provider.lowercased() {
        case "email", "gmail": "gmail"
        case "calendar", "gcal", "google_calendar": "calendar"
        case "twitter": "x"
        default: provider.lowercased()
        }
        return [
            tokenPath(provider),
            tokenPath(canonical),
            root.appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent(canonical, isDirectory: true)
                .appendingPathComponent("auth.json"),
        ]
    }

    private func hasUsableToken(_ provider: String) -> Bool {
        tokenPaths(provider).contains { path in
            guard let data = try? Data(contentsOf: path),
                  case .object(let object) = try? JSONValue.parse(data) else {
                return false
            }
            return ["access_token", "oauth_token", "token"].contains { key in
                guard case .string(let value)? = object[key] else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
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
        try await updateRegistry(provider: provider, connected: false)

        return .object([
            "ok": .bool(true),
            "provider": .string(provider),
            "revoked": .bool(true),
        ])
    }

    public func connectConnector(provider: String) async throws -> JSONValue {
        guard Self.knownProviders.contains(provider) else {
            throw ConnectorAuthError.unknownProvider(provider)
        }

        guard hasUsableToken(provider) else {
            throw ConnectorAuthError.tokenNotSaved(provider)
        }

        try await updateRegistry(provider: provider, connected: true)

        return .object([
            "provider": .string(provider),
            "authorized": .bool(true),
            "message": .string("\(provider) connected successfully."),
        ])
    }

    private func updateRegistry(provider: String, connected: Bool) async throws {
        // A credential effect alone is not confirmation of the registry change.
        try await persistence.withFileLock(connectorsPath) { [self] in
            // 2026-09-06: this operation only updates an existing registry.
            // Missing or damaged bytes are never permission to replace it with an empty array.
            let raw = try JSONValue.parse(Data(contentsOf: connectorsPath))
            let rows = try ConnectorOAuthRegistry.checkedConnectorRows(from: raw)
            guard rows.contains(where: { Self.providerID(Self.idString($0["id"])) == Self.providerID(provider) }) else {
                throw ConnectorAuthError.unknownProvider(provider)
            }
            func updatedEntry(_ entry: JSONValue, keyedBy key: String? = nil) throws -> JSONValue {
                guard case .object(var obj) = entry else {
                    throw PersistenceCoreError.ioFailure("Connector registry contains a non-object entry")
                }
                if Self.providerID(key ?? Self.idString(obj["id"])) == Self.providerID(provider) {
                    obj["enabled"] = .bool(connected)
                    obj["authState"] = .string(connected ? "connected" : "not_connected")
                    obj["healthStatus"] = .string(connected ? "ok" : "planned")
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
                    _ = try ConnectorOAuthRegistry.checkedCredentialObject(at: path)
                }
                try await self.persistence.writeJSON(updated, to: self.connectorsPath)
                if !connected {
                    // All saved inputs have passed validation and the durable
                    // disabled row exists before the first destructive step.
                    for path in paths where FileManager.default.fileExists(atPath: path.path) {
                        try FileManager.default.removeItem(at: path)
                    }
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

    private static func providerID(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "email", "gmail": "gmail"
        case "calendar", "gcal", "google_calendar": "calendar"
        case "twitter": "x"
        default: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

public enum ConnectorAuthError: Error, Sendable, Equatable {
    /// The provider is not recognized by the registry mutation boundary.
    case unknownProvider(String)
    /// No usable credential was saved before the connect-success request.
    case tokenNotSaved(String)
}

/// The root contains the connectors and oauth_tokens directories.
public func makeConnectorAuthClient(
    root: URL
) -> any ConnectorAuthClient {
    return SwiftNativeConnectorAuthClient(root: root)
}
