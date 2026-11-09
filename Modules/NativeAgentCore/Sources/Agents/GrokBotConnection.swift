import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import NativeAgentCore
import PersistenceCore
import MacControl
// Blueprint: | `GrokBotConnection.swift` | Uncertain setup never authorizes resend. |

public enum GrokBotConnection {
    public static func perform(turn: Turn, mac: MacOperationContext, plan: [String: JSONValue], dataRoot: URL, inner: any ToolDispatchClient, surface: String,
                               port: DesktopAgentConversationRoute) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"] else {
            return result("unavailable", "Grok Bot contact unavailable.")
        }
        let store = AgentPeerStore(dataRoot: dataRoot)
        let contact: AgentPeerContact
        do {
            guard let saved = try store.list().first(where: { $0.id == peerID && $0.transport == .grokBot }) else {
                return result("unavailable", "Grok Bot contact unavailable.")
            }
            contact = saved
        } catch { return result("unavailable", "Grok Bot contact cannot be read: " + error.localizedDescription) }
        do {
            switch plan["status"] {
            case .string("grok_send"):
                if contact.grokSetup != "set up" { return GrokBotRoute.setupRequired(contact) }
                try await GrokRoutineAccessibility.ensureRunning(mac: mac)
                guard case .string(let text)? = plan["text"], case .string(let id)? = plan["message_id"],
                      case .string(let askedIn)? = plan["asking_session"] else { return result("invalid", "Missing message.") }
                // Keep the asking door from the durable conversation row.
                let asked = turn.replyRoute
                let route = AgentBridgeCompletionRoute(surface: asked?.surface ?? surface, sessionId: askedIn,
                    destinationId: asked?.destinationId, threadId: asked?.threadId, sourceKey: asked?.sourceKey,
                    replyTo: asked?.replyTo, correlationId: asked?.correlationId, requesterUserId: asked?.requesterUserId)
                return try await GrokBotRoute.send(peer: contact, text: text, askedIn: askedIn, route: route,
                    messageID: id, dataRoot: dataRoot,
                    credential: GrokLinkCredential.read(peer: contact.id),
                    quiet: turn.personInitiatedSend?.admitted == true)
            case .string("grok_disconnect"):
                guard contact.grokBootstrapConfirmed == true, let conversation = contact.grokConversation else {
                    _ = try store.remove(peerID)
                    return result("disconnected", "Local keys revoked and contact removed. Routine creation was never confirmed; no cleanup request was sent.")
                }
                // Disconnect must settle even when its remote cleanup ask fails.
                let cleanupError: Error?
                do {
                    try await port.grokBootstrap(turn: turn, mac: mac, """
                        Delete only the routine named \(GrokBotRoute.routineName(peerID)) that NativeAgent asked you to create in this \
                        conversation. Do not delete or change any other routine. Never show its URL or key in chat.
                        """,
                        bot: conversation, beforeSubmission: {})
                    cleanupError = nil
                } catch { cleanupError = error }
                _ = try store.remove(peerID)
                if let cleanupError {
                    return result("disconnected", "Local keys revoked and contact removed. Routine cleanup failed: "
                        + cleanupError.localizedDescription + ". Delete only \(GrokBotRoute.routineName(peerID)) in Grok Bot's Routines if it exists.")
                }
                return result("disconnected",
                    "Local keys revoked. Asked Grok Bot to delete this app's routine; deletion is unconfirmed. Approve it in Grok Bot if asked.")
            default:
                guard contact.grokSetup != "disconnected" else { return result("disconnected", "Finish disconnecting before creating a new connection.") }
                // Nil means no Return; false means uncertain submission, which must never authorize resend.
                let requestStarted = contact.grokBootstrapConfirmed != nil
                do {
                    let exposure = try await port.importGrokRoutine(turn: turn, mac: mac, peer: peerID, dataRoot: dataRoot, waitForCreation: requestStarted)
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
                let message = """
                    Create one Active webhook routine named \(GrokBotRoute.routineName(peerID)) for NativeAgent. Use the exact instruction below. \
                    If it already exists, do not create another. Never print the webhook URL or key in chat or command output; NativeAgent reads \
                    them from the Routines panel itself. Do not change local execution policy or any other routine.\n\n
                    """ + GrokBotRoute.instruction(peer: peerID, command: command)
                try await port.grokBootstrap(turn: turn, mac: mac, message, bot: conversation, beforeSubmission: {
                    _ = try store.updateGrok(peerID) {
                        guard $0.grokBootstrapConfirmed == nil else {
                            throw GrokRoutineAccessibility.Failure(detail: """
                                Grok Bot setup changed while this request was being prepared. Connect again to continue its saved setup; no \
                                additional request was submitted.
                                """)
                        }
                        $0.grokBootstrapConfirmed = false
                    }
                })
                _ = try store.updateGrok(peerID) { $0.grokBootstrapConfirmed = true }
                let approval = """
                    Asked Grok Bot to create or finish the one NativeAgent reply routine. The owner must approve routine creation inside Grok Bot \
                    if asked.\u{20}
                    """
                let exposure = try await port.importGrokRoutine(turn: turn, mac: mac, peer: peerID, dataRoot: dataRoot, waitForCreation: true)
                return result("set up", approval + "Routine credentials saved in Keychain. "
                    + exposure + " Set up; no answer checked yet.")
            }
        } catch is CancellationError {
            return result("stopped",
                "Grok Bot setup or delivery stopped. Connect again to continue this contact's setup; an uncertain submission is never resent.")
        } catch let failure as GrokRoutineAccessibility.Failure {
            return result(failure.stopped ? "stopped" : "needs_attention", failure.detail)
        } catch let covered as MacScreenLock.Covered {
            return result("needs_attention", covered.detail)
        } catch let blocker as GrokRoutineAccessibility.Blocker {
            return result("needs_attention", blocker.rawValue + (contact.grokSetup == "disconnected"
                ? " Local keys are already revoked; only routine cleanup remains." : ""))
        } catch { return result("needs_attention",
            "Grok Bot setup or delivery stopped: \(error.localizedDescription) Connect again to continue this contact's setup. No automatic resend.") }
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
            let saved = try GrokLinkCredential.read(peer: peer)
            guard saved.webhookURL == credential.webhookURL, saved.webhookKey == credential.webhookKey,
                  saved.descriptorPath == credential.descriptorPath, saved.replyToken == credential.replyToken else {
                throw ToolFailureError("The credential write completed, but its Keychain readback did not match. Read the connection before changing it again.",
                    effects: .unknown)
            }
            current.grokSetup = "set up"
            current.grokBootstrapConfirmed = true
        }
        guard let saved = try store.list().first(where: { $0.id == peer }), saved.transport == .grokBot,
              saved.grokSetup == "set up", saved.grokBootstrapConfirmed == true else {
            throw ToolFailureError("Credentials were saved, but the contact's setup state could not be confirmed. Refresh Connectors.", effects: .occurred)
        }
        return true
    }

    public static func importSecureCredentials(turn: Turn, mac: MacOperationContext, peer: String, dataRoot: URL,
                                                desktop: DesktopAgentConversationRoute) async throws -> Bool {
        guard let current = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peer }),
              ["creating", "secure-paste"].contains(current.grokSetup ?? "") else { return false }
        try await desktop.importGrokRoutine(turn: turn, mac: mac, peer: peer, dataRoot: dataRoot, waitForCreation: true)
        return true
    }
}
