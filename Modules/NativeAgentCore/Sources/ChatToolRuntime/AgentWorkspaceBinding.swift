import AgentWorkspace
import Foundation
import PersistenceCore
import MacIntegration

package enum ChatWorkspaceBinding {
    package static let ports = AgentWorkspacePorts.Binding(conversations: Conversations(), tools: Tools())

    package static func pending(dataRoot: URL?, scope: String?) async -> JSONValue? {
        await AgentWorkspacePorts.$binding.withValue(ports) {
            await AgentWorkspaceArrivals.pending(dataRoot: dataRoot, scope: scope)
        }
    }

    package static func glance(dataRoot: URL, scope: String, turn: Date?) async -> String? {
        await AgentWorkspacePorts.$binding.withValue(ports) {
            await HerScreen.glance(dataRoot: dataRoot, scope: scope, turn: turn)
        }
    }

    private struct Conversations: AgentWorkspaceConversationPort {
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
    }
}
