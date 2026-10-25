import Foundation
import PersistenceCore
import MacIntegration
import Synchronization
import NativeAgentShared
// Blueprint: | `AgentWorkspacePorts.swift` | `AgentWorkspacePorts` enum; the parts ranking the app door registers, read by the turn glance; workspace row decisions and pure helper faces enter L0 through the caller's native tool port |

/// Synchronous projections over the existing conversation owner. The lower
/// target shares values, never the store, settlement, or send authority.
package protocol AgentWorkspaceConversationPort: Sendable {
    func liveHealth(dataRoot: URL) -> [String: AgentLocalHealth]
    func records(dataRoot: URL, locked: Bool) throws -> [AgentConversationRecord]
    func find(dataRoot: URL, scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord?
    func peers(dataRoot: URL) throws -> [AgentWorkspacePeer]
    func identity(dataRoot: URL) -> AgentContactIdentity
    func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue
    func presentation(_ row: AgentConversationRecord) -> JSONValue
    func liveHandOff(_ row: AgentConversationRecord) -> Bool
    func unsettledAttention(_ row: AgentConversationRecord) -> Bool
    /// A room in chat `scope` showed her these replies of a contact's (send
    /// id: the words shown); the ones that chat asked for, shown exactly as
    /// saved, are hers there and not handed over again.
    func shown(answers: [String: String], peer: String, scope: String, dataRoot: URL)
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
    func readout(_ input: JSONValue, dataRoot: URL) async throws -> JSONValue
    func readoutFace(_ input: JSONValue, dataRoot: URL) async -> PartCallResult<PartFace>
    func usableAgentLanes(dataRoot: URL) -> Set<String>
    func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String>
    /// The `app` action a tool folded into, nil for a tool of its own.
    func appAction(_ tool: String) -> String?
    func macIntegrationGate(_ name: String) -> (integration: String, mode: MacIntegrationPermissionMode)?
    func markConsumed(peer: String)
    func normalizeWorkspaceAlias(_ path: String, workspaceRoot: URL) -> String
    func withWebScheme(_ value: String) -> String
    func builderSourceRepoRoot(dataRoot: URL) -> URL?
    var listedPeerState: String { get }
    func builtAbilities(dataRoot: URL, now: Date) async -> String
}

/// Bound by the chat entry points for the whole structured workspace operation.
/// A nested gated dispatch inherits the same owners; nothing is cached here.
package enum AgentWorkspacePorts {
    /// The existing workspace failure face, with the owner's evidence and remedy.
    package static func readFailure(_ error: any Error, reason: String, remedy: JSONValue) -> String {
        HerScreen.readFailure(error, reason: reason, remedy: remedy)
    }

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

    /// Her own parts against a message, ranked the way find ranks: the app
    /// door registers its ranking when it starts (`AppToolExecutor`).
    private static let partsRanking = Mutex<(@Sendable (String, URL) async -> String)?>(nil)
    package static func rankParts(_ rank: @escaping @Sendable (String, URL) async -> String) {
        partsRanking.withLock { $0 = rank }
    }
    package static func parts(for message: String, dataRoot: URL) async -> String {
        guard let rank = partsRanking.withLock({ $0 }) else { return "Your own parts could not be read: the app door has not started." }
        return await rank(message, dataRoot)
    }
}
