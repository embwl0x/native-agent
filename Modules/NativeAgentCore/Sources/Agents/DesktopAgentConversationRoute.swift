import AppKit
import Foundation
import GrokLink
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import NativeAgentCore
import MacControl
import PersistenceCore
import ApplicationServices
import ToolExecution
// Blueprint: | `DesktopAgentConversationRoute.swift` | The originating app door calls `Resources/abilities/desktop-courier.js` through L0 `Parts.call` for reply-address wording and the courier's constrained tool-turn procedure. Native code serializes exact recipient/message data and retains the tool-turn owner, exact-recipient/send-evidence fence, screen/input ownership, uncertain outcomes and settlement. Grok's direct native send/reply watch remains separate; part failure stops before courier typing, with no compiled procedure fallback |

/// Executes the SEND half of a desktop adapter beneath the conversation API.
/// The short-lived operator uses the ordinary gated Mac tools; it owns no agent
/// or transcript. A desktop contact is send-only: its reply comes back through
/// this app's own inbound agent door, never by reading its screen.
public actor DesktopAgentConversationRoute {
    let clients: any AgentContactClients
    private let dataRoot: URL
    private var busy = false

    init(clients: any AgentContactClients, dataRoot: URL) { self.clients = clients; self.dataRoot = dataRoot }

    public func grokBootstrap(_ text: String, bot: String, beforeSubmission: @Sendable () throws -> Void) async throws {
        guard !busy else { throw GrokRoutineAccessibility.Blocker.busy }
        busy = true
        defer { busy = false }
        try await GrokRoutineAccessibility.send(text, bot: bot, beforeSubmission: beforeSubmission)
    }

    @discardableResult public func importGrokRoutine(peer: String, dataRoot: URL, waitForCreation: Bool) async throws -> String {
        guard !busy else { throw GrokRoutineAccessibility.Blocker.busy }
        busy = true
        defer { busy = false }
        return try await GrokRoutineAccessibility.importRoutine(peer: peer, dataRoot: dataRoot, waitForCreation: waitForCreation)
    }

    private struct CourierInstructions: Codable, Sendable {
        let replyInstruction: String
        let procedure: String
    }

    public func run(plan: [String: JSONValue], inner: any ToolDispatchClient, surface: String, appendReplyInstruction: Bool = true) async -> JSONValue {
        let agent = string(plan["agent"]) ?? "unknown"
        guard !busy else { return result(agent, "busy", "The desktop is handling another conversation. Send again when it finishes.") }
        busy = true
        let output = await operate(plan: plan, inner: inner, surface: surface, appendReplyInstruction: appendReplyInstruction)
        return await settle { await self.release(output) }
    }
    private func release(_ output: JSONValue) -> JSONValue { busy = false; return output }

    private func operate(plan: [String: JSONValue], inner: any ToolDispatchClient, surface: String, appendReplyInstruction: Bool) async -> JSONValue {
        let agent = string(plan["agent"]) ?? "unknown"
        guard case .object(let target)? = plan["target"], let bundle = string(target["app_bundle_id"]),
              let label = string(target["conversation_label"]), !label.isEmpty else {
            return result(agent, "needs_setup", "This desktop contact needs an exact conversation label before it can be operated automatically.")
        }
        guard let requested = string(plan["requested_text"]), !requested.isEmpty else {
            return result(agent, "needs_setup", "A desktop contact is send-only; this route carries a message or nothing at all.")
        }
        // Grok's answer is read from its own chat, so it is not asked to answer
        // through an agent door as well: an inbound message there carries
        // nothing that ties it to this send, and two answers would be recorded.
        // The screensaver hides every window and refuses activation (walk 2:
        // "Grok Bot never came to the front"); wake it before touching the app.
        do { try await MacScreenLock.wakeIfCovered() } catch {
            return Self.stopped(agent, app: "the app", stage: "waking the screen", typed: false, submitted: false,
                                why: (error as? MacScreenLock.Covered)?.detail ?? "\(error)")
        }
        // Grok Bot has a proven native send (select chat, empty box, paste,
        // Return, see it in the chat) that knows exactly how far it got; a
        // model driving the screen could not find its composer (walk 09-25).
        if bundle == GrokBotRoute.bundleID {
            do {
                try await GrokRoutineAccessibility.send(requested, bot: label, watchReply: true)
                // The reply watch runs after this returns, outside `busy`
                // (GrokDesktopReply.follow), so other desktop sends aren't held.
                guard case .object(var fields) = Self.delivered(agent) else { return Self.delivered(agent) }
                fields["submission_observation"] = await GrokRoutineAccessibility.submissionObservation
                guard let sent = await GrokRoutineAccessibility.sentLayout else {
                    fields["detail"] = .string("Pasted into chat \u{201C}\(label)\u{201D} in the Grok Bot app and seen there, but that chat's transcript could not be read to watch for the answer; it stays in that chat.")
                    fields.removeValue(forKey: "reply_with")
                    return .object(fields)
                }
                fields["_grok_watch"] = .object(["chat": .string(label),
                    "peer": .string(agent.hasPrefix("peer:") ? String(agent.dropFirst(5)) : agent),
                    "watch_id": sent.watchID.map(JSONValue.string) ?? .null])
                return .object(fields)
            } catch {
                let reached = await GrokRoutineAccessibility.reached
                let why = (error as? MacScreenLock.Covered)?.detail ?? error.localizedDescription
                let stage = reached == .opening ? "opening Grok Bot" : "opening chat \u{201C}\(label)\u{201D} and checking its message box"
                return Self.stopped(agent, app: "Grok Bot", stage: stage, typed: reached == .typing || reached == .submitted,
                                    submitted: reached == .submitted, why: why)
            }
        }
        let instructions: CourierInstructions
        switch await Parts(root: dataRoot).call(id: "desktop-courier",
            input: .object(["agentName": .string(PeerFacingIdentity.agentName)]), as: CourierInstructions.self) {
        case .success(let value): instructions = value
        case .failure(let error):
            return Self.stopped(agent, app: "the app", stage: "preparing the courier instructions",
                typed: false, submitted: false, why: error.localizedDescription)
        }
        let message = requested + (appendReplyInstruction ? "\n\n" + instructions.replyInstruction : "")
        let operatorTools = DesktopConversationTools(inner: inner, bundle: bundle, label: label, message: message)
        let client = clients.chatClient(tools: operatorTools)
        let task: JSONValue = .object([
            "app_bundle_id": .string(bundle), "conversation_label": .string(label),
            "operation": .string("send"), "message": .string(message)
        ])
        do {
            // Native serialization carries the exact recipient/message data;
            // the editable part owns the procedure, never delivery evidence.
            let prompt = instructions.procedure + "\n" + (try task.serialize(pretty: false))
            let response = try await client.runEphemeralToolTurn(message: prompt, fileAccess: "auto", requireCompleted: true, surface: surface)
            return await operatorTools.project(answer: Self.answer(response.output), agent: agent)
        } catch let incomplete as EphemeralToolTurnIncomplete {
            // A turn that stopped short still has an answer; it is judged only
            // against what this fence saw happen.
            return await operatorTools.project(answer: Self.answer(incomplete.output), agent: agent)
        } catch {
            return await operatorTools.stopped(agent, why: error.localizedDescription)
        }
    }
    private static func answer(_ output: String) -> [String: JSONValue] {
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              case .object(let answer)? = try? JSONValue.parse(data) else { return [:] }
        return answer
    }
    static func delivered(_ agent: String) -> JSONValue {
        .object([
            "agent": .string(agent), "view": .string("conversation"), "transport": .string("desktop"),
            "status": .string("sent"), "sent": .bool(true), "completed": .bool(false),
            "detail": .string("Delivered to the app's chat: the outgoing message is visible in the verified conversation. Its reply arrives as an inbound message through the agent door, not in this result."),
            "reply_with": .object(["tool": .string("agent_message"), "input": .object(["agent": .string(agent), "text": .string("<your next message>")])])
        ])
    }
    /// Every unfinished send says where it stopped and whether sending again
    /// could double-post: nothing typed is safe to resend; typed or submitted is not.
    static func stopped(_ agent: String, app: String, stage: String, typed: Bool, submitted: Bool, why: String) -> JSONValue {
        let reason = why.isEmpty ? "" : " (\(why))"
        let detail = !typed
            ? "Not sent: stopped while \(stage)\(reason). Nothing was typed into \(app), so sending again is safe."
            : !submitted
            ? "Stopped after typing, before submitting\(reason). The text may be sitting in \(app)'s message box; check it before sending again."
            : "Submitted, but the message was not seen in the conversation\(reason). It may have been delivered; do not resend automatically."
        return .object([
            "agent": .string(agent), "transport": .string("desktop"),
            "status": .string(typed ? "outcome_unknown" : "unavailable"),
            "stage": .string(!typed ? stage : submitted ? "verifying the sent message" : "submitting"),
            "sent": submitted ? .null : .bool(false), "safe_to_resend": .bool(!typed),
            "completed": .bool(false), "automatic_resend": .bool(false), "detail": .string(detail)
        ])
    }
    private func result(_ agent: String, _ status: String, _ detail: String) -> JSONValue {
        .object(["agent": .string(agent), "status": .string(status), "detail": .string(detail), "completed": .bool(false), "automatic_resend": .bool(false)])
    }
    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }; return text
    }
}

/// Request-scoped evidence fence over the transport's own verbs (screen, go,
/// read, its result pages and act); every call still enters the app's file,
/// Trust and Mac Control gates, and any other tool is hers here as anywhere.
package actor DesktopConversationTools: ToolDispatchClient {
    let inner: any ToolDispatchClient
    let bundle: String
    let label: String
    let message: String
    let frontmostBundle: @Sendable () async -> String?
    private var calls = 0
    private var typed = false
    private var submitted = false
    /// The submit action itself reported success (an attempt alone is `submitted`).
    private var submitConfirmed = false
    private var selectionSucceeded = false
    /// Times the message was already visible before it was typed; delivery
    /// needs a post-submission read showing it more often than that.
    private var baseline = 0
    private var observed = ""
    private var goReport = ""
    /// Where the route is and the last thing that went wrong, for a stop to name.
    private var stage = "opening the app"
    private var problem = ""

    package init(inner: any ToolDispatchClient, bundle: String, label: String, message: String,
         frontmostBundle: @escaping @Sendable () async -> String? = {
             await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
         }) {
        self.inner = inner; self.bundle = bundle; self.label = label; self.message = message
        self.frontmostBundle = frontmostBundle
    }
    package func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }
    package func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
    package func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if bundle == GrokBotRoute.bundleID { try await GrokRoutineAccessibility.requireChatOnly() }
        calls += 1
        guard calls <= 24 else { throw refusal("Desktop conversation tool budget exceeded.") }
        var args = input.filter { $0.value != .null }
        var typing = false, submitting = false, selecting = false
        if tool == "screen" {
            args["app"] = .string(bundle); args["pixels"] = .bool(false)
        } else if tool == "go" {
            selectionSucceeded = false
            if await frontmostBundle() != bundle {
                // go reads a dotted bundle id as a web address; hand it the app's name.
                let appName = await MainActor.run {
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
                        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent
                }
                let went = try await inner.dispatch(tool: "go", input: ["name": .string(appName ?? bundle)], surface: surface)
                goReport = String(flatten(went).prefix(300))
            }
            guard await frontmostBundle() == bundle else { throw refusal("The exact target app could not be brought forward. \(goReport)") }
            stage = "selecting the conversation"
            // MacFourVerbs' destination wording compares display names. Verify
            // the bundle identity ourselves, then return a fresh scoped read.
            let screen = try await inner.dispatch(tool: "screen", input: ["app": .string(bundle), "pixels": .bool(false)], surface: surface)
            observed = String(flatten(screen).prefix(120_000))
            return screen
        } else if ["read", "tool_result_page", "act"].contains(tool) {
            let front = await frontmostBundle()
            guard front == bundle else { throw refusal("The target app is no longer in front; no action performed.") }
            if tool == "read" {
                guard args["path"] == nil || args["path"] == .string("") else { throw refusal("This route only reads the on-screen conversation, not files.") }
                args = [:]
            } else if tool == "tool_result_page" {
                // The existing turn-result owner validates handle scope and
                // bounds; no new file reader or persistence is introduced.
            } else {
                // The app is pinned and verified in front above; act needs no name for it.
                args.removeValue(forKey: "app")
                let target = string(args["target"])
                // "press" is a key for a key name, else a click (as MacControl reads it).
                let verb = string(args["verb"]) == "press" ? (["return", "enter"].contains(target.lowercased()) ? "key" : "click") : string(args["verb"])
                for key in ["holding", "to", "to_app"] where args[key] == .string("") { args.removeValue(forKey: key) }
                for key in ["seconds", "interval"] where args[key] == .int(0) || args[key] == .double(0) { args.removeValue(forKey: key) }
                if args["repeat"] == .int(1) { args.removeValue(forKey: "repeat") }
                if args["button"] == .string("auto") { args.removeValue(forKey: "button") }
                guard Set(args.keys).isSubset(of: ["verb", "target", "text", "direction", "scroll_amount", "session_id", "__session_id"]) else { throw refusal("Unsupported desktop action fields.") }
                if submitted {
                    return .object([
                        "ok": .bool(true), "status": .string("already_submitted"),
                        "sent": .bool(false), "automatic_resend": .bool(false),
                        "text": .string("Submission was already attempted. No additional action was performed. Use read with {} to verify the outgoing message."),
                        "next_action": .object(["tool": .string("read"), "input": .object([:])]),
                    ])
                }
                switch verb {
                case "type":
                    guard !typed, string(args["text"]) == message else { throw refusal("Only the exact requested message may be typed once.") }
                    guard selectionSucceeded, let composer = try await Self.verifiedComposerTarget(bundle: bundle, label: label, content: "") else {
                        throw refusal("The exact conversation and an empty message box could not be verified. Nothing was typed.")
                    }
                    args["target"] = .string(composer)
                    typed = true // before dispatch: uncertain attempts are never replayed
                    stage = "typing the message"; typing = true
                    baseline = occurrences(observed)
                case "key":
                    guard typed, ["return", "enter"].contains(target.lowercased()) else { throw refusal("Only one message submission key is permitted.") }
                    guard try await Self.verifiedComposerTarget(bundle: bundle, label: label, content: message) != nil else {
                        throw refusal("The conversation or composed message changed. Submission stopped.")
                    }
                    submitted = true; stage = "verifying the sent message"; submitting = true
                case "click":
                    if typed {
                        guard ["send", "send message"].contains(target.lowercased()) else { throw refusal("Only the send control may be clicked after composing.") }
                        guard try await Self.verifiedComposerTarget(bundle: bundle, label: label, content: message) != nil else {
                            throw refusal("The conversation or composed message changed. Submission stopped.")
                        }
                        submitted = true; stage = "verifying the sent message"; submitting = true
                    } else {
                        let decorated = target.hasPrefix(label + ", ") && observed.contains(target)
                        guard target == label || decorated else { throw refusal("Navigation may only select the exact saved conversation.") }
                        selectionSucceeded = false; selecting = true
                    }
                case "scroll": break
                default: throw refusal("This operation is outside desktop conversation scope.")
                }
            }
        } else {
            return try await inner.dispatch(tool: tool, input: input, surface: surface)
        }
        // Only a read taken after the submission counts as evidence of it.
        if submitting { observed = "" }
        let response: JSONValue
        do { response = try await inner.dispatch(tool: tool, input: args, surface: surface) }
        catch { problem = String(error.localizedDescription.prefix(240)); throw error }
        if ["screen", "read", "tool_result_page"].contains(tool) {
            observed = String(flatten(response).prefix(120_000))
        }
        if submitting, case .object(let reply) = response, reply["ok"] == .bool(true) { submitConfirmed = true }
        if selecting, case .object(let reply) = response, reply["ok"] == .bool(true) {
            selectionSucceeded = true
        }
        if case .object(let reply) = response, reply["ok"] == .bool(false) {
            if case .string(let text)? = reply["text"] { problem = String(text.prefix { $0 != "\n" }.prefix(240)) }
            // MacControl touched nothing (no such target, ambiguous, disabled,
            // the front moved): that typing attempt never happened, so it may be tried again.
            if typing, case .object(let detail)? = reply["detail"],
               case .string(let code)? = detail["error"],
               ["no_match", "ambiguous", "target_disabled", "front_window_changed", "owner_changed_apps"].contains(code) {
                typed = false; stage = "selecting the conversation"
            }
        }
        return response
    }

    @MainActor private static func verifiedComposerTarget(bundle: String, label: String, content: String) throws -> String? {
        let source = SystemMacAXElementSource()
        guard source.isTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundle else { return nil }
        let windows = try source.nativeWindows(pid: app.processIdentifier)
        guard let root = source.nativeApplication(pid: app.processIdentifier),
              let focused = MacAXAttributeRead.copyElement(root, kAXFocusedWindowAttribute),
              let window = windows.first(where: { CFEqual(focused, $0) }) else { return nil }
        let tree = try MacAccessibilityReader.elements(in: window, searching: "the exact desktop conversation and composer") {
            MacAXAttributeRead.text($0, kAXSubroleAttribute) != "AXApplicationLog"
        }
        func named(_ node: AXUIElement) -> Bool {
            MacAXAttributeRead.text(node, kAXTitleAttribute) == label || MacAXAttributeRead.text(node, kAXDescriptionAttribute) == label
        }
        guard !tree.contains(where: { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXSheetRole || MacAXAttributeRead.text($0, kAXSubroleAttribute) == kAXDialogSubrole }),
              named(window) || tree.contains(where: {
                  named($0) && (MacAXAttributeRead.text($0, kAXRoleAttribute) == "AXHeading"
                      || MacAXAttributeRead.copyRaw($0, kAXSelectedAttribute) as? Bool == true)
              }) else { return nil }
        let boxes = tree.filter {
            [kAXTextAreaRole, kAXTextFieldRole].contains(MacAXAttributeRead.text($0, kAXRoleAttribute))
                && MacAXAttributeRead.text($0, kAXSubroleAttribute) != kAXSearchFieldSubrole
                && MacAXAttributeRead.copyRaw($0, kAXEnabledAttribute) as? Bool != false
        }
        guard boxes.count == 1, let value = MacAXAttributeRead.copyRaw(boxes[0], kAXValueAttribute) as? String,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == content.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return MacAXAttributeRead.text(boxes[0], kAXRoleAttribute) == kAXTextAreaRole ? "text area" : "text"
    }
    /// Send-only: the answer is delivery evidence for the outgoing message.
    /// No reply is looked for here — the recipient answers through the app's
    /// own inbound agent door, which arrives as an ordinary inbound message.
    func project(answer: [String: JSONValue], agent: String) -> JSONValue {
        let state = string(answer["state"])
        if submitConfirmed && state == "sent" && occurrences(observed) > baseline {
            return DesktopAgentConversationRoute.delivered(agent)
        }
        // The operator's note is model-written: it rides inside the fixed
        // frame of what this fence itself saw happen.
        let note = String(string(answer["detail"]).prefix(300))
        return stopped(agent, why: note.isEmpty ? problem : "operator: " + note)
    }
    func stopped(_ agent: String, why: String) -> JSONValue {
        DesktopAgentConversationRoute.stopped(agent, app: "the app", stage: stage, typed: typed, submitted: submitted,
                                              why: why.isEmpty ? problem : why)
    }
    private func string(_ value: JSONValue?) -> String { if case .string(let s)? = value { return s }; return "" }
    private func normalize(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private func occurrences(_ text: String) -> Int { normalize(text).components(separatedBy: normalize(message)).count - 1 }
    private func flatten(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .array(let values): values.map(flatten).joined(separator: "\n")
        case .object(let values): values.values.map(flatten).joined(separator: "\n")
        default: ""
        }
    }
    private func refusal(_ reason: String) -> NSError {
        problem = reason
        return NSError(domain: "DesktopConversation", code: 403, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

extension DesktopAgentConversationRoute: GrokBotConnectionPort {
    public nonisolated func ensureRunning() async throws {
        try await GrokRoutineAccessibility.ensureRunning()
    }

    public nonisolated func send(peer: AgentPeerContact, text: String, conversation: String, route: AgentBridgeCompletionRoute,
              messageID: String, dataRoot: URL, quiet: Bool) async throws -> JSONValue {
        if peer.grokSetup != "set up" { return GrokBotRoute.setupRequired(peer) }
        return try await GrokBotRoute.send(
            peer: peer, text: text, conversation: conversation, route: route,
            messageID: messageID, dataRoot: dataRoot,
            credential: GrokLinkCredential.read(peer: peer.id), quiet: quiet
        )
    }

}
