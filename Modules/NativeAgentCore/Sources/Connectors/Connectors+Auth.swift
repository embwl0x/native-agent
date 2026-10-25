import Foundation
import NativeAgentCore
import PersistenceCore
import SlackBot
import TrustCenter
// Blueprint: | `Connectors+Auth.swift` | `revokeConnector` records the person's disconnected decision in the canonical registry and delegates credential disable/removal to SlackCredentials |

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

    /// Providers recognized by this registry mutation boundary.
    private static let knownProviders: Set<String> = ["slack"]

    public func revokeConnector(provider: String) async throws -> JSONValue {
        guard Self.knownProviders.contains(provider) else {
            throw ConnectorAuthError.unknownProvider(provider)
        }
        try SlackCredentials.recoverPendingSave(dataRoot: root)
        try await updateRegistry(provider: provider)

        return .object([
            "ok": .bool(true),
            "provider": .string(provider),
            "revoked": .bool(true),
        ])
    }

    private func updateRegistry(provider: String) async throws {
        // A credential effect alone is not confirmation of the registry change.
        _ = try await ConnectorOAuthRegistry.mutateConnectorRegistryEntry(
            root: root, provider: provider, createIfMissing: false,
            publish: { [self] _, write in
                try await SlackCredentials.revoke(dataRoot: root, persistence: persistence, publishRegistry: write)
            }) { entry in
            entry[ConnectorOAuthRegistry.decisionField] = ConnectorOAuthRegistry.ConnectionDecision.disconnected.value
            entry["enabled"] = .bool(false)
            entry["authState"] = .string("not_connected")
            entry[SlackCredentials.generationField] = .string(UUID().uuidString)
            entry["healthStatus"] = .string("planned")
            entry["updatedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(Date()))
        }
    }

}

public enum ConnectorAuthError: Error, Sendable, Equatable {
    /// The provider is not recognized by the registry mutation boundary.
    case unknownProvider(String)
}
