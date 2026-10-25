import Foundation
import AgentConversations
import NativeAgentCore
import PersistenceCore
// Blueprint: | `GrokBotConnectionPort.swift` | `GrokBotConnectionPort` protocol; throwing `ensureRunning`, `send`, a bootstrap pre-submission callback and native import returning that operation's value-free field exposure receipt |

/// Concrete desktop, credential and send effects used by connection coordination.
public protocol GrokBotConnectionPort: Sendable {
    func ensureRunning() async throws
    func send(peer: AgentPeerContact, text: String, conversation: String, route: AgentBridgeCompletionRoute,
              messageID: String, dataRoot: URL, quiet: Bool) async throws -> JSONValue
    func grokBootstrap(_ text: String, bot: String, beforeSubmission: @Sendable () throws -> Void) async throws
    func importGrokRoutine(peer: String, dataRoot: URL, waitForCreation: Bool) async throws -> String
}
