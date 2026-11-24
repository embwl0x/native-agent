import Foundation
import MindCore
import PersistenceCore
import MacNerves
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `WorkspaceOperation.swift` | Native owner ports, held reading context and glance delivery stamps |

package protocol AgentWorkspaceConversationPort: Sendable {
    func liveHealth(dataRoot: URL) throws -> [String: AgentLocalHealth]
    var healthNotifications: [Notification.Name] { get }
    func records(dataRoot: URL, locked: Bool) throws -> [AgentConversationRecord]
    func find(dataRoot: URL, scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord?
    func peers(dataRoot: URL) throws -> [AgentWorkspacePeer]
    func identity(dataRoot: URL) throws -> AgentContactIdentity
    func answeredRequests(dataRoot: URL) throws -> [(message: String?, run: String?, chat: String?, modified: Date)]
    func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue
    func presentation(_ row: AgentConversationRecord) -> JSONValue
    func unsettledAttention(_ row: AgentConversationRecord) -> Bool
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

package protocol AgentWorkspaceToolPort: Sendable {
    func readout(_ input: JSONValue, dataRoot: URL) async throws -> JSONValue
    func readoutFace(_ input: JSONValue, dataRoot: URL) async -> PartCallResult<PartFace>
    func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String>
    func appAction(_ tool: String) -> String?
    func macIntegrationAccess(_ name: String) -> MacIntegrationAccess?
    func readTrust(_ sources: [String], dataRoot: URL) -> PeerDataTaint.TrustRead
    func withWebScheme(_ value: String) -> String
    func builderSourceRepoRoot(dataRoot: URL) -> URL?
    var listedPeerState: String { get }
    func builtAbilities(dataRoot: URL, now: Date) async throws -> String
}

package struct PreparedWorkspaceGlance: Sendable {
    package let text: String
    package let delivered: (@Sendable (String) -> Void)?

    package init(_ text: String, delivered: (@Sendable (String) -> Void)? = nil) {
        self.text = text
        self.delivered = delivered
    }
}

package struct WorkspaceOperation: Sendable {
    package struct Binding: Sendable {
        package let conversations: any AgentWorkspaceConversationPort
        package let tools: any AgentWorkspaceToolPort

        package init(conversations: any AgentWorkspaceConversationPort, tools: any AgentWorkspaceToolPort) {
            self.conversations = conversations
            self.tools = tools
        }
    }

    package let ports: Binding
    let jobs: AgentJobStore
    let bodyField: BodyField?
    package let turn: Turn?
    package var previewing: Bool
    var readiness: AgentWorkspaceReadiness.Snapshot?

    package init(ports: Binding, jobs: AgentJobStore, bodyField: BodyField?, turn: Turn?, previewing: Bool = false) {
        self.jobs = jobs
        self.ports = ports
        self.bodyField = bodyField
        self.turn = turn
        self.previewing = previewing
    }

    package func preview() -> Self {
        var operation = self
        operation.previewing = true
        return operation
    }
}
