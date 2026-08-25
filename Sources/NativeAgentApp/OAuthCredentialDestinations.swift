import Foundation
import PersistenceCore
import ProviderRouting

/// Provider OAuth and connector OAuth may share an account brand, but they do
/// not share authority or revocation lifecycle. Keep their file destinations
/// typed and centralized so an X connector write cannot replace the xAI Grok
/// provider credential used by model routing.
enum OAuthCredentialDestinations {
    static func xAIProvider(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        XAIOAuthDirectAdapter.tokenPath(dataRoot: dataRoot)
    }

    static func xConnector(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("x", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// The X action executor still consumes this daemon-compatible mirror.
    /// It belongs to the connector namespace, never the xAI provider one.
    static func xConnectorRuntimeMirror(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("oauth_tokens", isDirectory: true)
            .appendingPathComponent("x.json")
    }

    static func areDisjoint(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> Bool {
        let provider = xAIProvider(dataRoot: dataRoot).standardizedFileURL
        return provider != xConnector(dataRoot: dataRoot).standardizedFileURL
            && provider != xConnectorRuntimeMirror(dataRoot: dataRoot).standardizedFileURL
    }
}
