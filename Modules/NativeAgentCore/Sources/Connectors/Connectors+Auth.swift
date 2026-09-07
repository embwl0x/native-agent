import Foundation
import NativeAgentCore
import PersistenceCore

/// Local connector credential revocation and registry updates. OAuth token
/// exchange and sign-in persistence belong to the app's NativeOAuthFlow.
public protocol ConnectorAuthClient: Sendable {
    /// Unlink credentials under their path locks, then mark the registry entry
    /// disabled. Registry write failure does not undo a successful unlink.
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
        // Unlink failures propagate. These locks also exclude refresh and sign-in
        // publication; the registry lock is acquired separately afterward.
        for tok in Set(tokenPaths(provider)) {
            try await persistence.withFileLock(tok) {
                if FileManager.default.fileExists(atPath: tok.path) {
                    try FileManager.default.removeItem(at: tok)
                }
            }
        }

        await updateRegistry(provider: provider, connected: false)

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

        await updateRegistry(provider: provider, connected: true)

        return .object([
            "provider": .string(provider),
            "authorized": .bool(true),
            "message": .string("\(provider) connected successfully."),
        ])
    }

    private func updateRegistry(provider: String, connected: Bool) async {
        // Registry updates are best effort; token presence remains the readiness
        // source. Preserve the successful credential operation if this write fails.
        do {
            try await persistence.withFileLock(connectorsPath) { [persistence, connectorsPath] in
                // 2026-09-06: this operation only updates an existing registry.
                // Missing or damaged bytes are never permission to replace it with an empty array.
                let raw = try JSONValue.parse(Data(contentsOf: connectorsPath))
                guard case .array(var connectors) = raw,
                      connectors.allSatisfy({ if case .object = $0 { return true }; return false }) else {
                    throw PersistenceCoreError.ioFailure("Connector registry is not an array of objects")
                }
                for (idx, entry) in connectors.enumerated() {
                    guard case .object(var obj) = entry else { continue }
                    if Self.providerID(Self.idString(obj["id"]))
                        == Self.providerID(provider) {
                        obj["enabled"] = .bool(connected)
                        obj["authState"] = .string(connected ? "connected" : "not_connected")
                        obj["healthStatus"] = .string(connected ? "ok" : "planned")
                        connectors[idx] = .object(obj)
                    }
                }
                try await persistence.writeJSON(.array(connectors), to: connectorsPath)
            }
        } catch {
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
