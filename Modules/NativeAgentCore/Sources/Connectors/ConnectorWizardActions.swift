import Foundation
import ProviderRouting
import PersistenceCore
import TrustCenter
import ChatToolRuntime
// Blueprint: | `ConnectorWizardActions.swift` | `ConnectorWizardSetupRoute`: wizard and inline cards share the setup registry |

public enum ConnectorWizardSetupRoute: Equatable, Sendable {
    case manualToken
    case unavailable

    /// The inline registry also owns wizard routing so both surfaces offer the same way to connect.
    public static func resolve(provider: String) -> Self {
        let canonical = InlineInteractionRegistry.canonicalConnectorID(provider)
        switch InlineInteractionRegistry.connectorSetup(for: canonical) {
        case .manualToken where canonical == "slack": return .manualToken
        case .manualToken, .unavailable: return .unavailable
        }
    }
}

extension ConnectorOAuthRegistry {
    public static func readConnectorRegistryEntry(
        root: URL,
        provider: String
    ) async throws -> [String: JSONValue]? {
        let providerID = normalizedConnectorID(provider)
        guard !providerID.isEmpty else { return nil }
        let path = connectorRegistryPath(root: root)
        let current = try await SwiftNativePersistenceCore.withFileLock(path) {
            try readRegistry(at: path)
        }
        return current.first { connectorRow($0, matches: providerID) }
    }
}
