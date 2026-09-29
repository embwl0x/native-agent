import Agents
import ChatOrchestration
import Foundation
import GrokLink
import PersistenceCore

struct AppGrokBotConnectionPort: GrokBotConnectionPort {
    func ensureRunning() async -> Bool {
        await GrokRoutineAccessibility.ensureRunning()
    }

    func send(peer: AgentPeerContact, text: String, conversation: String,
              messageID: String, dataRoot: URL, quiet: Bool) async throws -> JSONValue {
        try await GrokBotRoute.send(
            peer: peer, text: text, conversation: conversation,
            messageID: messageID, dataRoot: dataRoot,
            credential: GrokLinkCredential.read(peer: peer.id), quiet: quiet
        )
    }

    func grokBootstrap(_ text: String, bot: String) async throws {
        try await NativeAgentEngine.live.agents.desktop.grokBootstrap(text, bot: bot)
    }

    func importGrokRoutine(peer: String, dataRoot: URL) async throws {
        try await NativeAgentEngine.live.agents.desktop.importGrokRoutine(peer: peer, dataRoot: dataRoot)
    }
}
