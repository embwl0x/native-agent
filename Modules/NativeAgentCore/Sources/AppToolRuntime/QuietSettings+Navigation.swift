import AgentConversations
import Foundation
import PersistenceCore
import StandingBots
// Blueprint: | `QuietSettings+Navigation.swift` | Settings navigation labels from the canonical registry with off-main discovery |

extension QuietSettings {
    public struct Navigation: Sendable {
        public let id: String
        public let label: String
        public let page: String
        public let tab: String?
    }

    /// Discovery reads identities, never credentials or control values.
    @MainActor public static func navigation(host: any QuietLowerOnlySettingsHost) async throws -> [Navigation] {
        let root = host.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let (bots, peers) = try await navigationIdentities(root)
        let rows = try staticRows + botRows(bots) + host.lowerOnlyRows(forPage: nil, connectedPeers: peers) + host.platformSettings
        return rows.map { Navigation(id: $0.id, label: $0.label, page: $0.page, tab: $0.tab) }
    }

    @concurrent private static func navigationIdentities(_ root: URL) async throws -> ([BotDefinition], [AgentPeerContact]) {
        (try BotDefinitionStore(dataRoot: root).list(), try AgentPeerStore(dataRoot: root).list())
    }
}
