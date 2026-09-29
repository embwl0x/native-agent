import GrokLink
import Foundation
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

public enum GrokBotConnection {
    public static func perform(plan: [String: JSONValue], dataRoot: URL, inner: any ToolDispatchClient, surface: String,
                               port: any GrokBotConnectionPort) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"],
              let contact = try? AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peerID && $0.transport == .grokBot }) else {
            return result("unavailable", "Grok Bot contact unavailable.")
        }
        let store = AgentPeerStore(dataRoot: dataRoot)
        do {
            switch plan["status"] {
            case .string("grok_send"):
                guard await port.ensureRunning() else { return result("desktop app not running", "Grok Bot desktop app not running. No message was sent.") }
                guard case .string(let text)? = plan["text"], case .string(let id)? = plan["message_id"],
                      case .string(let conversation)? = plan["conversation_id"] else { return result("invalid", "Missing message.") }
                return try await port.send(peer: contact, text: text, conversation: conversation,
                    messageID: id, dataRoot: dataRoot,
                    quiet: PersonInitiatedSend.current?.admitted == true)
            case .string("grok_disconnect"):
                guard contact.grokBootstrapConfirmed == true, contact.grokConversation != nil else {
                    _ = try store.remove(peerID)
                    return result("disconnected", "Local keys revoked and contact removed. Routine creation was never confirmed; no cleanup request was sent.")
                }
                // Disconnecting always finishes here; the cleanup ask is best effort.
                let asked = (try? await port.grokBootstrap(
                    "Delete only the routine named \(GrokBotRoute.routineName(peerID)) that NativeAgent asked you to create in this conversation. Do not delete or change any other routine. Never show its URL or key in chat.",
                    bot: contact.grokConversation ?? "grok")) != nil
                _ = try store.remove(peerID)
                return result("disconnected", asked
                    ? "Local keys revoked. Asked Grok Bot to delete only this app's routine; deletion is not yet confirmed. Approve it in Grok Bot if asked."
                    : "Local keys revoked and contact removed. I could not ask Grok Bot to delete the routine named \(GrokBotRoute.routineName(peerID)); delete it in Grok Bot's Routines if it exists.")
            default:
                if contact.grokSetup == "set up" { return result("set up", "Set up. Send a message to check the reply path.") }
                guard contact.grokSetup != "disconnected" else { return result("disconnected", "Finish disconnecting before creating a new connection.") }
                var saved = contact
                // An unconfirmed request is asked again: the request itself
                // tells the Bot not to create a second routine, so a repeat
                // can only finish the first one, never duplicate it.
                if contact.grokConversation == nil || contact.grokBootstrapConfirmed != true {
                    let conversation: String
                    // The Bot's own 1:1 chat; Grok Bot's built-in Bot is "grok".
                    if let chosen = contact.grokConversation ?? contact.conversationLabel, !chosen.isEmpty { conversation = chosen } else { conversation = "grok" }
                    saved = try store.updateGrok(peerID) {
                        guard $0.grokConversation == nil || $0.grokConversation == conversation else { throw GrokLinkCredential.Failure.invalid }
                        $0.grokConversation = conversation
                    }
                    guard let command = contact.approvedExecutablePath else { throw GrokLinkCredential.Failure.invalid }
                    let message = "Create one Active webhook routine named \(GrokBotRoute.routineName(peerID)) for NativeAgent. Use the exact instruction below. If it already exists, do not create another. Never print the webhook URL or key in chat or command output; NativeAgent reads them from the Routines panel itself. Do not change local execution policy or any other routine.\n\n" + GrokBotRoute.instruction(peer: peerID, command: command)
                    try await port.grokBootstrap(message, bot: conversation)
                    saved = try store.updateGrok(peerID) { $0.grokBootstrapConfirmed = true }
                }
                guard saved.grokBootstrapConfirmed == true else { throw GrokRoutineAccessibility.Blocker.submission }
                // Read the routine's address and key from Grok Bot's Routines panel;
                // the secure field is the fallback when that panel cannot be read.
                var blocker: String?
                do {
                    try await port.importGrokRoutine(peer: peerID, dataRoot: dataRoot)
                    saved.grokSetup = "set up"
                } catch {
                    saved.grokSetup = "secure-paste"
                    blocker = (error as? GrokRoutineAccessibility.Blocker)?.rawValue
                }
                _ = try store.updateGrok(peerID) { $0.grokSetup = saved.grokSetup }
                return result(saved.grokSetup == "set up" ? "set up" : "needs_secure_setup",
                    saved.grokSetup == "set up" ? "Routine credentials saved in Keychain. Set up; no answer checked yet."
                        : (blocker.map { $0 + " " } ?? "") + GrokBotRoute.securePasteBlocker)
            }
        } catch let blocker as GrokRoutineAccessibility.Blocker {
            return result("needs_attention", blocker.rawValue + (contact.grokSetup == "disconnected" ? " Local keys are already revoked; only routine cleanup remains." : ""))
        } catch { return result("needs_attention", "Grok Bot setup or delivery could not be confirmed. No automatic resend. Check the Connect card.") }
    }
    static func result(_ state: String, _ detail: String) -> JSONValue {
        .object(["status": .string(state), "detail": .string(detail), "completed": .bool(false), "automatic_resend": .bool(false)])
    }
}
