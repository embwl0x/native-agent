import GrokLink
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import NativeAgentCore
import PersistenceCore
import MacControl
// Blueprint: | `GrokBotConnection.swift` | Grok connection coordination and secure Bot selection/credential transactions; unfinished contacts resume from the durable pre-submission boundary without resending an uncertain request; setup blockers retain their own remedy |

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
                if contact.grokSetup != "set up" { return GrokBotRoute.setupRequired(contact) }
                try await port.ensureRunning()
                guard case .string(let text)? = plan["text"], case .string(let id)? = plan["message_id"],
                      case .string(let conversation)? = plan["conversation_id"] else { return result("invalid", "Missing message.") }
                // The asking turn's door, as its conversation row keeps it.
                let asked = ChatToolSessionContext.replyRoute
                let route = AgentBridgeCompletionRoute(surface: asked?.surface ?? surface, sessionId: conversation,
                    destinationId: asked?.destinationId, threadId: asked?.threadId, sourceKey: asked?.sourceKey,
                    replyTo: asked?.replyTo, correlationId: asked?.correlationId, requesterUserId: asked?.requesterUserId)
                return try await port.send(peer: contact, text: text, conversation: conversation, route: route,
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
                    bot: contact.grokConversation ?? "grok", beforeSubmission: {})) != nil
                _ = try store.remove(peerID)
                return result("disconnected", asked
                    ? "Local keys revoked. Asked Grok Bot to delete only this app's routine; deletion is not yet confirmed. Approve it in Grok Bot if asked."
                    : "Local keys revoked and contact removed. I could not ask Grok Bot to delete the routine named \(GrokBotRoute.routineName(peerID)); delete it in Grok Bot's Routines if it exists.")
            default:
                guard contact.grokSetup != "disconnected" else { return result("disconnected", "Finish disconnecting before creating a new connection.") }
                let requests = GrokRequestStore(dataRoot: dataRoot)
                let expired = try requests.expiredUnanswered(peer: peerID)
                // nil: no Return was issued; false: submission is unconfirmed;
                // true: request/routine confirmed. An uncertain request is never sent again.
                let requestStarted = contact.grokBootstrapConfirmed != nil
                do {
                    let exposure = try await port.importGrokRoutine(peer: peerID, dataRoot: dataRoot, waitForCreation: requestStarted)
                    // Fresh credentials repair the path; an old unanswered request is never resent.
                    if let expired {
                        try requests.update(expired.messageID, peer: peerID) {
                            if $0.reply == nil { $0.handOver = "connection repaired; no resend" }
                        }
                    }
                    return result("set up", "Routine credentials refreshed from Grok Bot's native view. "
                        + exposure + " Send one message to verify an actual reply.")
                } catch let blocker as GrokRoutineAccessibility.Blocker {
                    guard blocker == .missingRoutine else { throw blocker }
                    if requestStarted {
                        return result("needs_attention", blocker.rawValue + " "
                            + (contact.grokBootstrapConfirmed == true
                                ? "A setup request or routine was previously confirmed for this contact."
                                : "The routine request's submission is unconfirmed.")
                            + " No request was resent.")
                    }
                }
                let saved = try store.updateGrok(peerID) {
                    var credential = try GrokLinkCredential.read(peer: peerID)
                    credential.webhookURL = nil; credential.webhookKey = nil
                    try credential.write(peer: peerID)
                    $0.grokSetup = "creating"
                }
                guard let command = saved.approvedExecutablePath, let conversation = saved.grokConversation else { throw GrokLinkCredential.Failure.invalid }
                let message = "Create one Active webhook routine named \(GrokBotRoute.routineName(peerID)) for NativeAgent. Use the exact instruction below. If it already exists, do not create another. Never print the webhook URL or key in chat or command output; NativeAgent reads them from the Routines panel itself. Do not change local execution policy or any other routine.\n\n" + GrokBotRoute.instruction(peer: peerID, command: command)
                try await port.grokBootstrap(message, bot: conversation, beforeSubmission: {
                    _ = try store.updateGrok(peerID) {
                        guard $0.grokBootstrapConfirmed == nil else {
                            throw GrokRoutineAccessibility.Failure(detail: "Grok Bot setup changed while this request was being prepared. Connect again to continue its saved setup; no additional request was submitted.")
                        }
                        $0.grokBootstrapConfirmed = false
                    }
                })
                _ = try store.updateGrok(peerID) { $0.grokBootstrapConfirmed = true }
                if let expired {
                    try requests.update(expired.messageID, peer: peerID) {
                        if $0.reply == nil { $0.handOver = "connection bootstrap requested; no resend" }
                    }
                }
                let approval = "Asked Grok Bot to create or finish the one NativeAgent reply routine. The owner must approve routine creation inside Grok Bot if asked. "
                let exposure = try await port.importGrokRoutine(peer: peerID, dataRoot: dataRoot, waitForCreation: true)
                return result("set up", approval + "Routine credentials saved in Keychain. "
                    + exposure + " Set up; no answer checked yet.")
            }
        } catch is CancellationError {
            return result("stopped", "Grok Bot setup or delivery stopped. Connect again to continue this contact's setup; an uncertain submission is never resent.")
        } catch let failure as GrokRoutineAccessibility.Failure {
            return result(failure.stopped ? "stopped" : "needs_attention", failure.detail)
        } catch let covered as MacScreenLock.Covered {
            return result("needs_attention", covered.detail)
        } catch let blocker as GrokRoutineAccessibility.Blocker {
            return result("needs_attention", blocker.rawValue + (contact.grokSetup == "disconnected" ? " Local keys are already revoked; only routine cleanup remains." : ""))
        } catch { return result("needs_attention", "Grok Bot setup or delivery stopped: \(error.localizedDescription) Connect again to continue this contact's setup. No automatic resend.") }
    }
    static func result(_ state: String, _ detail: String) -> JSONValue {
        .object(["status": .string(state), "detail": .string(detail), "completed": .bool(false), "automatic_resend": .bool(false)])
    }
}

extension GrokBotConnection {
    public static func selectBot(peer: String, name: String, dataRoot: URL) throws {
        try AgentPeerStore(dataRoot: dataRoot).updateGrok(peer) { current in
            guard current.grokConversation == nil else { throw GrokLinkCredential.Failure.invalid }
            current.conversationLabel = name
        }
    }

    public static func saveSecureCredentials(peer: String, paste: String, dataRoot: URL) throws -> Bool {
        guard paste.utf8.count <= 16_384, let data = paste.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == ["url", "key"], let url = object["url"], let key = object["key"] else { return false }
        let store = AgentPeerStore(dataRoot: dataRoot)
        try store.updateGrok(peer) { current in
            guard ["creating", "secure-paste"].contains(current.grokSetup ?? "") else { throw GrokLinkCredential.Failure.invalid }
            var credential = try GrokLinkCredential.read(peer: peer)
            try credential.importWebhook(url: url, key: key)
            try credential.write(peer: peer)
            current.grokSetup = "set up"
            current.grokBootstrapConfirmed = true
        }
        return true
    }

    public static func importSecureCredentials(peer: String, dataRoot: URL,
                                                desktop: DesktopAgentConversationRoute) async throws -> Bool {
        guard let current = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peer }),
              ["creating", "secure-paste"].contains(current.grokSetup ?? "") else { return false }
        try await desktop.importGrokRoutine(peer: peer, dataRoot: dataRoot, waitForCreation: true)
        return true
    }
}
