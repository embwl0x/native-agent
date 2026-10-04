import Foundation
import PersistenceCore
import MacIntegration

/// Synchronous projections over the existing conversation owner. The lower
/// target shares values, never the store, settlement, or send authority.
package protocol AgentWorkspaceConversationPort: Sendable {
    func refreshHealth(dataRoot: URL)
    func records(dataRoot: URL, locked: Bool) throws -> [AgentConversationRecord]
    func find(dataRoot: URL, scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord?
    func peers(dataRoot: URL) throws -> [AgentWorkspacePeer]
    func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue
    func presentation(_ row: AgentConversationRecord) -> JSONValue
    func liveHandOff(_ row: AgentConversationRecord) -> Bool
    func unsettledAttention(_ row: AgentConversationRecord) -> Bool
}

package struct AgentWorkspacePeer: Sendable {
    package let id: String
    package let name: String
    package let elevationAllowed: Bool
    package let canAnswerBack: Bool

    package init(id: String, name: String, elevationAllowed: Bool, canAnswerBack: Bool) {
        self.id = id
        self.name = name
        self.elevationAllowed = elevationAllowed
        self.canAnswerBack = canAnswerBack
    }
}

/// Chat-owned catalog and provenance decisions remain at the dispatch boundary.
package protocol AgentWorkspaceToolPort: Sendable {
    func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String>
    /// The `app` action a tool folded into, nil for a tool of its own.
    func appAction(_ tool: String) -> String?
    func macIntegrationGate(_ name: String) -> (integration: String, mode: MacIntegrationPermissionMode)?
    func markConsumed(peer: String)
    func normalizeWorkspaceAlias(_ path: String, workspaceRoot: URL) -> String
    func withWebScheme(_ value: String) -> String
    func builderSourceRepoRoot(dataRoot: URL) -> URL?
    var listedPeerState: String { get }
}

/// Bound by the chat entry points for the whole structured workspace operation.
/// A nested gated dispatch inherits the same owners; nothing is cached here.
package enum AgentWorkspacePorts {
    package struct Binding: Sendable {
        package let conversations: any AgentWorkspaceConversationPort
        package let tools: any AgentWorkspaceToolPort

        package init(conversations: any AgentWorkspaceConversationPort, tools: any AgentWorkspaceToolPort) {
            self.conversations = conversations
            self.tools = tools
        }
    }
    @TaskLocal package static var binding: Binding?
    package static var current: Binding {
        guard let binding else { preconditionFailure("Workspace entry point requires its owner ports") }
        return binding
    }
}

struct AgentWorkspaceConversationReader {
    let dataRoot: URL
    func records() throws -> [AgentConversationRecord] {
        try AgentWorkspacePorts.current.conversations.records(dataRoot: dataRoot, locked: true)
    }
    func recordsUnlocked() throws -> [AgentConversationRecord] {
        try AgentWorkspacePorts.current.conversations.records(dataRoot: dataRoot, locked: false)
    }
    func find(scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        try AgentWorkspacePorts.current.conversations.find(dataRoot: dataRoot, scopeSessionID: scopeSessionID, agent: agent, label: label)
    }
}

struct AgentWorkspacePeerReader {
    let dataRoot: URL
    func list() throws -> [AgentWorkspacePeer] {
        try AgentWorkspacePorts.current.conversations.peers(dataRoot: dataRoot)
    }
}

enum AgentWorkspaceConversationProjection {
    static func liveHandOff(_ row: AgentConversationRecord) -> Bool {
        AgentWorkspacePorts.current.conversations.liveHandOff(row)
    }
    static func unsettledAttention(_ row: AgentConversationRecord) -> Bool {
        AgentWorkspacePorts.current.conversations.unsettledAttention(row)
    }
    static func workspaceChangeObservation(_ row: AgentConversationRecord,
                                          location: AgentWorkspaceLocation,
                                          previous: AgentWorkspaceChanges.Stamp?) -> AgentWorkspaceChanges.Observation? {
        AgentWorkspaceChanges.evaluate(location: location,
            result: AgentWorkspacePorts.current.conversations.presentation(row), previous: previous)
    }
}
