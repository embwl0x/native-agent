import AgentWorkspace
import Foundation
import PersistenceCore
import MacIntegration
import ToolRegistry
import TrustCenter
import XConnector
import SlackConnector

package enum ChatWorkspaceBinding {
    package static let ports = AgentWorkspacePorts.Binding(conversations: Conversations(), tools: Tools())

    package static func pending(dataRoot: URL?, scope: String?) async -> JSONValue? {
        await AgentWorkspacePorts.$binding.withValue(ports) {
            await AgentWorkspaceArrivals.pending(dataRoot: dataRoot, scope: scope)
        }
    }

    package static func currentPlace(dataRoot: URL, scope: String) async -> String? {
        await AgentWorkspaceNavigation.shared.currentPlace(dataRoot: dataRoot, scope: scope)
    }

    package static func glance(dataRoot: URL, scope: String, turn: Date?, includingMoments: Bool = true) async -> String? {
        await AgentWorkspacePorts.$binding.withValue(ports) {
            await HerScreen.glance(dataRoot: dataRoot, scope: scope, turn: turn, includingMoments: includingMoments)
        }
    }

    private struct Conversations: AgentWorkspaceConversationPort {
        func refreshHealth(dataRoot: URL) {
            Task.detached(priority: .utility) { await AgentContactHealth.shared.refresh(dataRoot: dataRoot) }
        }
        func records(dataRoot: URL, locked: Bool) throws -> [AgentConversationRecord] {
            let store = AgentConversationStore(dataRoot: dataRoot)
            return try locked ? store.records() : store.recordsUnlocked()
        }
        func find(dataRoot: URL, scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord? {
            try AgentConversationStore(dataRoot: dataRoot).find(scopeSessionID: scopeSessionID, agent: agent, label: label)
        }
        func peers(dataRoot: URL) throws -> [AgentWorkspacePeer] {
            try AgentPeerStore(dataRoot: dataRoot).list().map {
                .init(id: $0.id, name: $0.name, elevationAllowed: $0.elevationAllowed, canAnswerBack: $0.canAnswerBack)
            }
        }
        func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue {
            let snapshot = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            guard !SwiftNativeTrustCenter.hasExplicitBlockOverride("chat_conversations", overrides: snapshot.userConfiguredAutonomyOverrides) else {
                throw AutonomyGateError.toolDenied(reason: "Conversation access is blocked in Trust. Nothing was read.")
            }
            let result = await HumanConversationReader.open(sessionID: sessionID, limit: limit, dataRoot: dataRoot)
            if case .object(let row) = result, row["untrusted_remote_data"] == .bool(true), case .string(let peer)? = row["agent"] {
                PeerDataTaint.markConsumed(peer: peer)
            }
            return result
        }
        func presentation(_ row: AgentConversationRecord) -> JSONValue {
            AgentConversationSession.conversationPresentation(row)
        }
        func liveHandOff(_ row: AgentConversationRecord) -> Bool { AgentConversationSession.liveHandOff(row) }
        func unsettledAttention(_ row: AgentConversationRecord) -> Bool { AgentConversationSession.unsettledAttention(row) }
    }

    private struct Tools: AgentWorkspaceToolPort {
        func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String> {
            SwiftToolDispatcher.modelVisibleCatalogToolNames(names)
        }
        func appAction(_ tool: String) -> String? { ToolNameAliases.appAction(tool) }
        func macIntegrationGate(_ name: String) -> (integration: String, mode: MacIntegrationPermissionMode)? {
            ToolPreloadHeuristics.macIntegrationGates[name]
        }
        func markConsumed(peer: String) { PeerDataTaint.markConsumed(peer: peer) }
        func normalizeWorkspaceAlias(_ path: String, workspaceRoot: URL) -> String {
            SwiftToolDispatcher.normalizeWorkspaceAlias(path, workspaceRoot: workspaceRoot)
        }
        func withWebScheme(_ value: String) -> String { SwiftToolDispatcher.withWebScheme(value) }
        func builderSourceRepoRoot(dataRoot: URL) -> URL? { SwiftToolDispatcher.builderSourceRepoRoot(dataRoot: dataRoot) }
        var listedPeerState: String { AgentPeerContactState.listed.rawValue }
        func unreadyTools(dataRoot: URL) -> [String: String] {
            var tools: [String: String] = [:]
            for (id, label, names) in [
                ("gmail", "Gmail", ["gmail_search", "gmail_read"]),
                ("calendar", "Google Calendar", ["google_calendar_calendars", "google_calendar_list",
                    "google_calendar_read", "google_calendar_free_busy", "google_calendar_send_invitations"]),
                ("notion", "Notion", ["notion_search", "notion_read_page"])
            ] where !SwiftToolDispatcher.cloudConnectorConnected(id, root: dataRoot) {
                // Apple Mail already reads Gmail accounts added to Mail; only this API route is off (10-09).
                let note = id == "gmail" ? "Gmail API connector not signed in (Settings > Connectors); Gmail accounts in Apple Mail are read by mail.* already."
                    : "The owner must sign in to \(label) in Settings > Connectors."
                for name in names { tools[name] = note }
            }
            if (try? XConnectorActions.credentialStatus(dataRoot: dataRoot))?.configured != true {
                for name in ["x_status", "x_me", "x_search", "x_timeline", "x_user_tweets"] {
                    tools[name] = "The owner must sign in to X in Settings > Connectors."
                }
            }
            if !SlackConnectorActions.canSearch(dataRoot: dataRoot) {
                tools["slack_search_messages"] = "Slack search needs a user token with search:read. The owner must sign in to Slack in Settings > Connectors."
            }
            return tools
        }
    }
}
