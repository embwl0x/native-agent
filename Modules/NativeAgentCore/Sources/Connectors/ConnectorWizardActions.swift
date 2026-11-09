import Foundation
import NativeAgentShared
import ProviderRouting
import PersistenceCore
import TrustCenter
import ChatToolRuntime
// Blueprint: | `ConnectorWizardActions.swift` | Connector registry entry reads under the persistence lock |

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
