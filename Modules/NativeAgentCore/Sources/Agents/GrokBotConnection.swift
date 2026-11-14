import AppKit
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolExecution
// Blueprint: | `GrokBotConnection.swift` | `Resources/abilities/grok-bot-setup.js`, `Parts.call`; Uncertain setup never authorizes resend. |

/// The compiled part of a Grok Bot contact: its record, its Keychain entry, the clipboard's native take into Keychain and the webhook send. How
/// the agent works Grok Bot's window (setup's message and steps, disconnect's cleanup request) is the agent's own ability, `grok-bot-setup`, which
/// the agent revises when Grok Bot changes; connect and disconnect answer `needs_agent_steps` with its words.
public enum GrokBotConnection {
    /// A connect that did not finish names the one next call: the same connect, which answers at once with the setup message and its next step.
    public static func perform(turn: Turn, plan: [String: JSONValue], dataRoot: URL, surface: String, parts: Parts.Invocation) async -> JSONValue {
        let answer = await attempt(turn: turn, plan: plan, dataRoot: dataRoot, surface: surface, parts: parts)
        guard case .object(var fields) = answer, case .string(let state)? = fields["status"],
              ["needs_attention", "stopped"].contains(state), plan["status"] != .string("grok_disconnect"),
              case .string(let peerID)? = plan["peer_id"],
              let contact = try? AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peerID && $0.transport == .grokBot }) else { return answer }
        fields["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string("agent.connect"),
            "args": .object(["agent": .string(contact.name)])])])
        return .object(fields)
    }

    private static func attempt(turn: Turn, plan: [String: JSONValue], dataRoot: URL, surface: String, parts: Parts.Invocation) async -> JSONValue {
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
        let routine = GrokBotRoute.routineName(peerID)
        do {
            switch plan["status"] {
            case .string("grok_send"):
                if contact.grokSetup != "set up" { return GrokBotRoute.setupRequired(contact) }
                guard case .string(let text)? = plan["text"], case .string(let id)? = plan["message_id"],
                      case .string(let askedIn)? = plan["asking_session"] else { return result("invalid", "Missing message.") }
                guard openApp() else {
                    return result("unavailable", "Grok Bot's Mac app is not installed, and its routine answers through it. Nothing was sent.")
                }
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
                // The local part settles first: keys are already revoked, and the contact goes whatever the words say.
                _ = try store.remove(peerID)
                guard let conversation = contact.grokConversation else {
                    return result("disconnected", "Local keys revoked and contact removed. Setup never sent its message, so no routine waits in Grok Bot.")
                }
                let input: [String: JSONValue] = ["operation": .string("disconnect"), "contact": .string(peerID), "chat": .string(conversation),
                    "routine": .string(routine)]
                switch await words(input, dataRoot: dataRoot, parts: parts) {
                case .failure(let error):
                    return result("disconnected", "Local keys revoked and contact removed. The ability grok-bot-setup gave no cleanup steps ("
                        + error.message + "). Delete only \(routine) in Grok Bot's Routines if it exists.")
                case .success(let words):
                    return steps(words, chat: conversation, routine: routine, extra: ["disconnected": .bool(true)])
                }
            default:
                guard contact.grokSetup != "disconnected" else { return result("disconnected", "Finish disconnecting before creating a new connection.") }
                let credential = try GrokLinkCredential.read(peer: peerID)
                if contact.grokSetup == "set up", credential.webhookURL != nil, credential.webhookKey != nil {
                    return result("set up", "Grok Bot is connected: its routine's webhook is in Keychain. Send one message to verify an actual reply.")
                }
                guard let command = contact.approvedExecutablePath else { throw GrokLinkCredential.Failure.invalid }
                // Setup drives nothing here. The agent does what a person would, in the words of the agent's own ability; old webhook values and any
                // submission record from earlier builds are cleared, so neither can leave this contact waiting.
                let conversation = chat(for: contact, dataRoot: dataRoot)
                let input: [String: JSONValue] = ["operation": .string("connect"), "contact": .string(peerID), "chat": .string(conversation),
                    "routine": .string(routine), "instruction": .string(GrokBotRoute.instruction(peer: peerID, command: command))]
                let said: SetupWords
                switch await words(input, dataRoot: dataRoot, parts: parts) {
                case .failure(let error):
                    return result("needs_attention", """
                        The ability grok-bot-setup gave no setup steps: \(error.message) Read it with ability.read {id:"grok-bot-setup"} and \
                        repair it with ability.save; nothing was changed on this contact.
                        """)
                case .success(let words): said = words
                }
                // One owner write, read after the ability's await: a paste that landed meanwhile is the contact's newer state and stays; only a
                // setup still where this connect found it is reset.
                var moved: String?
                _ = try store.updateGrok(peerID) { current in
                    guard current.grokSetup == contact.grokSetup else {
                        moved = current.grokSetup
                        if current.grokConversation == nil { current.grokConversation = conversation }
                        return
                    }
                    var credential = try GrokLinkCredential.read(peer: peerID)
                    credential.webhookURL = nil; credential.webhookKey = nil
                    try credential.write(peer: peerID)
                    current.grokSetup = "creating"
                    current.grokConversation = conversation
                    current.grokBootstrapConfirmed = nil
                }
                if moved == "set up" {
                    return result("set up", "Grok Bot is connected: its routine's webhook is in Keychain. Send one message to verify an actual reply.")
                }
                return steps(said, chat: conversation, routine: routine, extra: [
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("agent.grok_paste"),
                        "args": .object(["agent": .string(peerID)])])])])
            }
        } catch is CancellationError {
            return result("stopped",
                "Grok Bot setup or delivery stopped. Connect again to continue this contact's setup; an uncertain submission is never resent.")
        } catch { return result("needs_attention",
            "Grok Bot setup or delivery stopped: \(error.localizedDescription) Connect again to continue this contact's setup. No automatic resend.") }
    }
    static func result(_ state: String, _ detail: String) -> JSONValue {
        .object(["status": .string(state), "detail": .string(detail), "completed": .bool(false), "automatic_resend": .bool(false)])
    }

    /// The ability's answer: the one message to type into Grok Bot's chat, the steps around it, and a line on what is left.
    private struct SetupWords: Codable, Sendable {
        let message: String
        let steps: [String]
        let detail: String
    }
    private static func words(_ input: [String: JSONValue], dataRoot: URL, parts: Parts.Invocation) async -> Result<SetupWords, PartCallError> {
        let said = await Parts(root: dataRoot).call(id: "grok-bot-setup", input: .object(input), invocation: parts, as: SetupWords.self)
        switch said {
        case .success(let words): return .success(words)
        case .failure(let error): return .failure(error)
        }
    }
    private static func steps(_ words: SetupWords, chat: String, routine: String, extra: [String: JSONValue]) -> JSONValue {
        var fields: [String: JSONValue] = ["status": .string("needs_agent_steps"), "completed": .bool(false), "automatic_resend": .bool(false),
            "chat": .string(chat), "routine": .string(routine), "message": .string(words.message),
            "steps": .array(words.steps.map(JSONValue.string)), "detail": .string(words.detail)]
        fields.merge(extra) { _, new in new }
        return .object(fields)
    }

    /// The routine's reply command runs through Grok Bot's Mac app, so a send opens the app by bundle id when it is not running. Launch only:
    /// nothing of its window is read or typed, and the send does not wait on the launch; a launch macOS refuses is logged. False: not installed.
    private static func openApp() -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).isEmpty else { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { nativeLog("%@", "Grok Bot's Mac app could not be opened for a send: " + error.localizedDescription) }
        }
        return true
    }

    /// The chat setup talks in: the one saved for the contact, else the recipe's main chat.
    private static func chat(for contact: AgentPeerContact, dataRoot: URL) -> String {
        contact.grokConversation ?? contact.conversationLabel ?? (try? AgentRecipeStore.grokRoutine(dataRoot: dataRoot).mainChat) ?? "Grok Bot"
    }
}

extension GrokBotConnection {
    public static func selectBot(peer: String, name: String, dataRoot: URL) throws {
        try AgentPeerStore(dataRoot: dataRoot).updateGrok(peer) { current in
            guard current.grokConversation == nil else { throw GrokLinkCredential.Failure.invalid }
            current.conversationLabel = name
        }
    }

    /// The person's secure field: one paste with both the webhook address and key (`GrokLinkCredential.pasted` names the accepted forms).
    public static func saveSecureCredentials(peer: String, paste: String, dataRoot: URL) throws -> Bool {
        try takePaste(peer: peer, text: paste, dataRoot: dataRoot, oneAtATime: false)?.complete == true
    }

    /// One paste into the secure Grok sink, straight to Keychain. `oneAtATime` (the agent's clipboard paste after each of Grok's Copy buttons) keeps an
    /// address or a key alone until the other comes; the contact is set up once both are saved. Nil: the paste is not one of the accepted forms.
    static func takePaste(peer: String, text: String, dataRoot: URL, oneAtATime: Bool) throws -> (complete: Bool, took: String)? {
        guard let pasted = GrokLinkCredential.pasted(text), pasted.url != nil || pasted.key != nil else { return nil }
        if !oneAtATime, pasted.url == nil || pasted.key == nil { return nil }
        let store = AgentPeerStore(dataRoot: dataRoot)
        let updated = try store.updateGrok(peer) { current in
            guard ["creating", "secure-paste"].contains(current.grokSetup ?? "") else { throw GrokLinkCredential.Failure.invalid }
            var credential = try GrokLinkCredential.read(peer: peer)
            try credential.takePasted(url: pasted.url, key: pasted.key)
            try credential.write(peer: peer)
            let saved = try GrokLinkCredential.read(peer: peer)
            guard saved.webhookURL == credential.webhookURL, saved.webhookKey == credential.webhookKey,
                  saved.descriptorPath == credential.descriptorPath, saved.replyToken == credential.replyToken else {
                throw ToolFailureError("The credential write completed, but its Keychain readback did not match. Read the connection before changing it again.",
                    effects: .unknown)
            }
            if credential.webhookComplete {
                current.grokSetup = "set up"
                current.grokBootstrapConfirmed = true
            } else { current.grokSetup = "secure-paste" }
        }
        let took = pasted.url != nil && pasted.key != nil ? "the webhook address and key" : pasted.url != nil ? "the webhook address" : "the webhook key"
        return (updated.grokSetup == "set up", took)
    }

    /// `agent.grok_paste` from the agent. The agent's own hands cannot reach the person-only secure window (its act on NativeAgent's own windows runs
    /// in process and never posts into a protected window), so the app makes the one paste that field allows the agent: the clipboard's text, read
    /// natively, straight into the secure field's sink and Keychain, never into a call, result, log or the model. The clipboard is then cleared unless
    /// something newer was copied. It drives nothing and waits on nothing; a paste it cannot take throws `grok_paste_not_taken`.
    public static func pasteClipboard(peer: String, dataRoot: URL) async throws -> (complete: Bool, words: String) {
        func notTaken(_ words: String) -> PartCallError { PartCallError(code: "grok_paste_not_taken", message: words) }
        let store = AgentPeerStore(dataRoot: dataRoot)
        let contacts = try await Task.detached { try store.list() }.value
        guard let contact = contacts.first(where: {
            $0.transport == .grokBot && ($0.id == peer || "peer:" + $0.id == peer || $0.name.caseInsensitiveCompare(peer) == .orderedSame)
        }) else { throw notTaken("No Grok Bot contact is called \(peer). Read agent.contacts for its name.") }
        guard ["creating", "secure-paste"].contains(contact.grokSetup ?? "") else {
            throw notTaken("\(contact.name) is not waiting for its webhook (setup is \(contact.grokSetup ?? "not started")). Connect it first.")
        }
        let (copied, generation) = await MainActor.run { (NSPasteboard.general.string(forType: .string), NSPasteboard.general.changeCount) }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw notTaken("The clipboard holds no text. Press the routine's own Copy in Grok Bot, then call agent.grok_paste again; nothing was saved.")
        }
        let id = contact.id
        let taken: (complete: Bool, took: String)?
        do { taken = try await Task.detached { try GrokBotConnection.takePaste(peer: id, text: copied, dataRoot: dataRoot, oneAtATime: true) }.value }
        catch GrokLinkCredential.Failure.invalid {
            throw notTaken("""
                The clipboard's text is not a usable webhook address (https) or key (no spaces). Press the routine's own Copy in Grok Bot, then call \
                agent.grok_paste again; nothing was saved.
                """)
        }
        await MainActor.run { if NSPasteboard.general.changeCount == generation { NSPasteboard.general.clearContents() } }
        guard let taken else {
            throw notTaken("""
                The clipboard does not hold a webhook address or key in a form the secure field takes ({"url":"…","key":"…"}, the address and key \
                separated by a space or new line, or either alone). Press the routine's own Copy in Grok Bot, then call agent.grok_paste again.
                """)
        }
        if taken.complete {
            return (true, "Set up: the webhook address and key are in Keychain (not shown). Send one message to verify an actual reply.")
        }
        let next = taken.took == "the webhook address" ? "key" : "address"
        return (false, "Took \(taken.took) from the clipboard into Keychain (not shown). Press the routine's Copy for the webhook \(next) in Grok "
            + "Bot, then call agent.grok_paste again.")
    }
}
