import Foundation
import ProviderRouting
import PersistenceCore
import TrustCenter
import ChatToolRuntime
// Blueprint: | `ConnectorWizardActions.swift` | `ConnectorWizardSetupRoute`: the wizard's token route, read from the inline card registry; registry row read |

public enum ConnectorWizardSetupRoute: Equatable, Sendable {
    case manualToken
    case unavailable

    /// One table, in `InlineInteractionRegistry`. The wizard and the inline
    /// card must never disagree about how an account is connected: a card that
    /// offers a sign-in while the wizard wants a pasted token is a lie the
    /// person only discovers after tapping. The registry answers which route
    /// applies.
    public static func resolve(provider: String) -> Self {
        let canonical = InlineInteractionRegistry.canonicalConnectorID(provider)
        switch InlineInteractionRegistry.connectorSetup(for: canonical) {
        // Telegram has no wizard page; only Slack's token paste.
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
