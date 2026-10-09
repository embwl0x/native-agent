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
                guard contact.grokSetup != "disconnected" else { return result("disconnected", "Finish disconnecting before creating a new connection.") }
                let requests = GrokRequestStore(dataRoot: dataRoot)
                let expired = try requests.expiredUnanswered(peer: peerID)
                do {
                    try await port.importGrokRoutine(peer: peerID, dataRoot: dataRoot, waitForCreation: false)
                    // Fresh credentials repair the path; an old unanswered request is never resent.
                    if let expired {
                        try requests.update(expired.messageID, peer: peerID) {
                            if $0.reply == nil { $0.handOver = "connection repaired; no resend" }
                        }
                    }
                    return result("set up", "Routine found in Grok Bot's Routines panel; credentials refreshed. Send one message to verify an actual reply.")
                } catch let blocker as GrokRoutineAccessibility.Blocker {
                    guard blocker == .missingRoutine else { throw blocker }
                }
                var saved = try store.updateGrok(peerID) {
                    var credential = try GrokLinkCredential.read(peer: peerID)
                    credential.webhookURL = nil; credential.webhookKey = nil
                    try credential.write(peer: peerID)
                    $0.grokSetup = "creating"
                    $0.grokBootstrapConfirmed = false
                }
                guard let command = saved.approvedExecutablePath, let conversation = saved.grokConversation else { throw GrokLinkCredential.Failure.invalid }
                let message = "Create one Active webhook routine named \(GrokBotRoute.routineName(peerID)) for NativeAgent. Use the exact instruction below. If it already exists, do not create another. Never print the webhook URL or key in chat or command output; NativeAgent reads them from the Routines panel itself. Do not change local execution policy or any other routine.\n\n" + GrokBotRoute.instruction(peer: peerID, command: command)
                try await port.grokBootstrap(message, bot: conversation)
                saved = try store.updateGrok(peerID) { $0.grokBootstrapConfirmed = true }
                if let expired {
                    try requests.update(expired.messageID, peer: peerID) {
                        if $0.reply == nil { $0.handOver = "connection bootstrap requested; no resend" }
                    }
                }
                let approval = "Asked Grok Bot to create or finish the one NativeAgent reply routine. The owner must approve routine creation inside Grok Bot if asked. "
                var blocker: String?
                do {
                    try await port.importGrokRoutine(peer: peerID, dataRoot: dataRoot, waitForCreation: true)
                    saved.grokSetup = "set up"
                } catch let error as GrokRoutineAccessibility.Blocker {
                    saved.grokSetup = "secure-paste"
                    blocker = error.rawValue
                }
                _ = try store.updateGrok(peerID) { $0.grokSetup = saved.grokSetup }
                return result(saved.grokSetup == "set up" ? "set up" : "needs_secure_setup",
                    approval + (saved.grokSetup == "set up" ? "Routine credentials saved in Keychain. Set up; no answer checked yet."
                        : (blocker.map { $0 + " " } ?? "") + GrokBotRoute.securePasteBlocker))
            }
        } catch let blocker as GrokRoutineAccessibility.Blocker {
            return result("needs_attention", blocker.rawValue + (contact.grokSetup == "disconnected" ? " Local keys are already revoked; only routine cleanup remains." : " Check Agents → Grok Bot → Routine credentials."))
        } catch { return result("needs_attention", "Grok Bot setup or delivery could not be confirmed: \(error.localizedDescription) No automatic resend. Check Agents → Grok Bot → Routine credentials.") }
    }
    static func result(_ state: String, _ detail: String) -> JSONValue {
        .object(["status": .string(state), "detail": .string(detail), "completed": .bool(false), "automatic_resend": .bool(false)])
    }
}
