import Foundation
import PersistenceCore
import MacIntegration
import Synchronization
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `AgentWorkspacePorts.swift` | `AgentWorkspacePorts`: native ports retain authority and delivery stamps |

/// Synchronous projections over the existing conversation owner. The lower target shares values, never the store, settlement, or send authority.
package protocol AgentWorkspaceConversationPort: Sendable {
    func liveHealth(dataRoot: URL) throws -> [String: AgentLocalHealth]
    /// What announces a change in live health that no watched file carries.
    var healthNotifications: [Notification.Name] { get }
    func records(dataRoot: URL, locked: Bool) throws -> [AgentConversationRecord]
    func acceptedSends(dataRoot: URL) throws -> Set<String>
    func find(dataRoot: URL, scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord?
    func peers(dataRoot: URL) throws -> [AgentWorkspacePeer]
    func identity(dataRoot: URL) throws -> AgentContactIdentity
    func answeredRequests(dataRoot: URL) throws -> [(message: String?, run: String?, chat: String?, modified: Date)]
    func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue
    func presentation(_ row: AgentConversationRecord) -> JSONValue
    func unsettledAttention(_ row: AgentConversationRecord) -> Bool
    /// Only exact replies shown for this chat's own sends are acknowledged here, preventing duplicate delivery.
    func shown(answers: [String: String], peer: String, scope: String, dataRoot: URL) throws
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
    func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String>
    func appAction(_ tool: String) -> String?
    func macIntegrationAccess(_ name: String) -> MacIntegrationAccess?
    func markConsumed(peer: String)
    func withWebScheme(_ value: String) -> String
    func builderSourceRepoRoot(dataRoot: URL) -> URL?
    var listedPeerState: String { get }
    func builtAbilities(dataRoot: URL, now: Date) async throws -> String
}

/// Read-only words and their owner-stamp acknowledgement, carried with preparation.
package struct PreparedWorkspaceGlance: Sendable {
    package let text: String
    /// The captured owner stamps, acknowledged only if their text was delivered. Bookkeeping failures report repair without failing the accepted reply.
    package let delivered: (@Sendable (String) -> Void)?

    package init(_ text: String, delivered: (@Sendable (String) -> Void)? = nil) {
        self.text = text
        self.delivered = delivered
    }
}

/// Explicit dependencies of a workspace operation; no task supplies hidden owners.
package enum AgentWorkspacePorts {
    /// The existing workspace failure face, with the owner's evidence and remedy.
    package static func readFailure(_ error: any Error, reason: String, remedy: JSONValue) -> String {
        AgentScreen.readFailure(error, reason: reason, remedy: remedy)
    }

    package struct Binding: Sendable {
        package let conversations: any AgentWorkspaceConversationPort
        package let tools: any AgentWorkspaceToolPort

        package init(conversations: any AgentWorkspaceConversationPort, tools: any AgentWorkspaceToolPort) {
            self.conversations = conversations
            self.tools = tools
        }
    }

    /// Use the app door's registered ranking so part matches agree with Find.
    /// A person-facing preview has no turn and must not acknowledge delivery.
    private static let partsRanking = Mutex<(@Sendable (String, URL, Turn?) async -> PreparedWorkspaceGlance)?>(nil)
    package static func rankParts(_ rank: @escaping @Sendable (String, URL, Turn?) async -> PreparedWorkspaceGlance) {
        partsRanking.withLock { $0 = rank }
    }
    package static func parts(for message: String, dataRoot: URL, turn: Turn?) async -> PreparedWorkspaceGlance {
        guard let rank = partsRanking.withLock({ $0 }) else { return PreparedWorkspaceGlance("Your own parts could not be read: the app door has not started.")
            }
        return await rank(message, dataRoot, turn)
    }
}

/// One workspace read's dependencies, permission evidence and presentation mode.
/// Child tasks capture this value; each new action reads its own permissions.
package struct WorkspaceOperation: Sendable {
    package let ports: AgentWorkspacePorts.Binding
    package let turn: Turn?
    package var previewing: Bool
    /// The selected action is re-entering dispatch through this workspace operation.
    package var insideDispatch: Bool
    var readiness: AgentWorkspaceReadiness.Snapshot?

    package init(ports: AgentWorkspacePorts.Binding, turn: Turn?, previewing: Bool = false, insideDispatch: Bool = false) {
        self.ports = ports
        self.turn = turn
        self.previewing = previewing
        self.insideDispatch = insideDispatch
    }

    package func preview() -> Self {
        var operation = self
        operation.previewing = true
        return operation
    }
}
