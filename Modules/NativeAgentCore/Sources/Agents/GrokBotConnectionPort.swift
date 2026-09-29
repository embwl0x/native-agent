import Foundation
import ChatOrchestration
import PersistenceCore

/// Concrete desktop, credential and send effects used by connection coordination.
public protocol GrokBotConnectionPort: Sendable {
    func ensureRunning() async -> Bool
    func send(peer: AgentPeerContact, text: String, conversation: String,
              messageID: String, dataRoot: URL, quiet: Bool) async throws -> JSONValue
    func grokBootstrap(_ text: String, bot: String) async throws
    func importGrokRoutine(peer: String, dataRoot: URL) async throws
}
