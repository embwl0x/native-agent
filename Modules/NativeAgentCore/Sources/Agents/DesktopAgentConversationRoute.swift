import AppKit
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import NativeAgentCore
import MacControl
import PersistenceCore
import ApplicationServices
import ToolExecution
import NativeAgentShared
import Synchronization
// Blueprint: | `DesktopAgentConversationRoute.swift` | `Resources/abilities/desktop-courier.js`, `Parts.call` |

/// Desktop operators use ordinary gated Mac tools and own no transcript or agent. Send-only contacts answer through authenticated inbound messaging, never
/// screen scraping.
public actor DesktopAgentConversationRoute {
    let clients: any AgentContactClients
    private let dataRoot: URL

    init(clients: any AgentContactClients, dataRoot: URL) { self.clients = clients; self.dataRoot = dataRoot }

    private struct CourierInstructions: Codable, Sendable {
        let replyInstruction: String
        let procedure: String
    }

    /// The person's send goes now; the agent's own runs only while the person is away, otherwise (or when the person takes the desktop before anything
    /// was typed) it is held in its conversation's queue, holding nothing, and goes when the Mac is free.
    public func run(turn: Turn, work: ChatTurnWork, mac: MacOperationContext, plan: [String: JSONValue], inner: any ToolDispatchClient,
        surface: String, conversation: AgentConversationContext, parts: Parts.Invocation) async -> JSONValue {
        let agent = plan["agent"]?.stringValue ?? "unknown"
        let text = plan["requested_text"]?.stringValue ?? ""
        let person = DesktopLane.askedByPerson(turn)
        if !person, DesktopLane.personHere {
            return await Self.held(agent, text: text, conversation: conversation, detail: MacAttentionSessionStore.personUsingMac)
        }
        let ticket: DesktopLane.Ticket
        switch await DesktopLane.shared.admit(person: person) {
        case .admitted(let admitted): ticket = admitted
        case .cancelled: return Self.stopped(agent, app: "the app", stage: "waiting for the desktop", typed: false, submitted: false, why: "Stopped.")
        case .busy:
            return result(agent, "busy", "Another operation is driving the desktop right now; this message has not started. Send again when it finishes.")
        case .superseded: return Self.supersededSend(agent)
        }
        let output = await DesktopLane.shared.operate(ticket) {
            await self.operate(turn: turn, work: work, mac: mac, plan: plan, inner: inner, surface: surface, lane: ticket, parts: parts)
        }
        let yielded = ticket.yieldedUntyped
        if person { return yielded ? Self.supersededSend(agent) : output }
        let untouched: Bool = if case .object(let fields) = output { fields["safe_to_resend"] == .bool(true) } else { false }
        if yielded || (untouched && DesktopLane.personHere) {
            return await Self.held(agent, text: text, conversation: conversation, detail: yielded
                ? "The person asked for the desktop, so this message stepped aside before anything was typed."
                : MacAttentionSessionStore.personUsingMac)
        }
        return output
    }

    static func supersededSend(_ agent: String) -> JSONValue {
        .object(["agent": .string(agent), "transport": .string("desktop"), "status": .string("not_sent"), "sent": .bool(false),
            "completed": .bool(false), "safe_to_resend": .bool(true), "automatic_resend": .bool(false), "detail": .string("""
                Superseded by the person's newer desktop request before anything was typed; nothing was sent and nothing of it waits. Send it again \
                if it is still wanted.
                """)])
    }

    /// The conversation's existing Mac hold (as DesktopChat's): the full text stays queued under its send id and the release drain sends it when the person
    /// is away. A held send never holds the desktop.
    private static func held(_ agent: String, text: String, conversation: AgentConversationContext, detail: String) async -> JSONValue {
        guard !Task.isCancelled, !text.isEmpty, let live = conversation.liveTarget, let row = live.recordID, let operation = live.operationID else {
            return .object(["agent": .string(agent), "status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "safe_to_resend": .bool(true), "detail": .string(detail)])
        }
        do {
            try await Task.detached {
                try AgentConversationStore(dataRoot: live.dataRoot).holdForMac(id: row, operation: operation, text: text, conversation: nil, detail: detail)
            }.value
            return .object(["agent": .string(agent), "status": .string("held"), "reason": .string("mac_busy"), "sent": .bool(false),
                "completed": .bool(false), "detail": .string(detail + " Waiting for the Mac to be free; it will go then. Do not send it again.")])
        } catch {
            return .object(["agent": .string(agent), "status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "safe_to_resend": .bool(true), "detail": .string(detail + " Saving the waiting message failed: " + error.localizedDescription)])
        }
    }

    private func operate(turn: Turn, work: ChatTurnWork, mac: MacOperationContext, plan: [String: JSONValue], inner: any ToolDispatchClient,
        surface: String, lane: DesktopLane.Ticket, parts: Parts.Invocation) async -> JSONValue {
        let agent = plan["agent"]?.stringValue ?? "unknown"
        guard case .object(let target)? = plan["target"], let bundle = target["app_bundle_id"]?.stringValue,
              let label = target["conversation_label"]?.stringValue, !label.isEmpty else {
            return result(agent, "needs_setup", "This desktop contact needs an exact conversation label before it can be operated automatically.")
        }
        guard let requested = plan["requested_text"]?.stringValue, !requested.isEmpty else {
            return result(agent, "needs_setup", "A desktop contact is send-only; this route carries a message or nothing at all.")
        }
        // Wake covered screens before activation.
        do { try await MacScreenLock.wakeIfCovered(turn: turn, context: mac) } catch {
            return Self.stopped(agent, app: "the app", stage: "waking the screen", typed: false, submitted: false,
                                why: (error as? MacScreenLock.Covered)?.detail ?? "\(error)")
        }
        let instructions: CourierInstructions
        switch await Parts(root: dataRoot).call(id: "desktop-courier",
            input: .object(["agentName": .string(PeerFacingIdentity.agentName)]), invocation: parts, as: CourierInstructions.self) {
        case .success(let value): instructions = value
        case .failure(let error):
            await ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: "app", input: ["action": .string("authored.desktop-courier")],
                surface: surface, result: .object(["status": .string("refused"), "reason": .string(error.code),
                    "checker": .string("desktop_courier_entry"), "detail": .string(error.message), "effects": .string("none"),
                    "remedy": Repair.remedy(owner: "desktop courier's originating door", nextCall: nil, tap: nil,
                        instruction: "Repair the caller's missing originating app door before preparing another desktop send; nothing was sent.")]),
                dataRoot: dataRoot)
            return Self.stopped(agent, app: "the app", stage: "preparing the courier instructions",
                typed: false, submitted: false, why: error.localizedDescription)
        }
        let message = requested + "\n\n" + instructions.replyInstruction
        let operatorTools = DesktopConversationTools(mac: mac, inner: inner, bundle: bundle, label: label, message: message, lane: lane)
        let client = clients.chatClient(tools: operatorTools)
        let task: JSONValue = .object([
            "app_bundle_id": .string(bundle), "conversation_label": .string(label),
            "operation": .string("send"), "message": .string(message)
        ])
        do {
            // Native serialization carries the exact recipient/message data; the editable part owns the procedure, never delivery evidence.
            let prompt = instructions.procedure + "\n" + (try task.serialize(pretty: false))
            let response = try await client.runEphemeralToolTurn(message: prompt, fileAccess: "auto", requireCompleted: true,
                surface: surface, turn: turn, work: work)
            return await operatorTools.project(answer: Self.answer(response.output), agent: agent)
        } catch let incomplete as EphemeralToolTurnIncomplete {
            // A turn that stopped short still has an answer; it is judged only against what this fence saw happen.
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
            "detail": .string("""
                Delivered to the app's chat: the outgoing message is visible in the verified conversation. Its reply arrives as an inbound message \
                through the agent door, not in this result.
                """),
            "reply_with": .object(["tool": .string("agent_message"), "input": .object(["agent": .string(agent), "text": .string("<your next message>")])])
        ])
    }
    /// Typed or submitted text may double-post on resend; report the exact stopping point.
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
}

/// Request-scoped evidence fence over the transport's own verbs (screen, go, read, its result pages and act); every call still enters the app's file, Trust and
/// Mac Control gates. No other execution door is offered or dispatched.
package actor DesktopConversationTools: ToolDispatchClient {
    let mac: MacOperationContext
    let inner: any ToolDispatchClient
    let bundle: String
    let label: String
    let message: String
    let lane: DesktopLane.Ticket?
    let frontmostBundle: @Sendable () async -> String?
    private var calls = 0
    private var typed = false
    private var submitted = false
    private var selectionSucceeded = false
    /// Exact outgoing transcript occurrences before submission, when the app has a native reader. Missing evidence permits sending, never confirmation.
    private var baseline: Int?
    private var observed = ""
    private var goReport = ""
    /// Retain stage and failure evidence so Stop can report where the send ended.
    private var stage = "opening the app"
    private var problem = ""

    package init(mac: MacOperationContext, inner: any ToolDispatchClient, bundle: String, label: String, message: String,
         lane: DesktopLane.Ticket? = nil, frontmostBundle: @escaping @Sendable () async -> String? = {
             await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
         }) {
        self.mac = mac; self.inner = inner; self.bundle = bundle; self.label = label; self.message = message
        self.lane = lane; self.frontmostBundle = frontmostBundle
    }
    package func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await listAvailableToolSchemas(turn: turn, surface: surface).map(\.name)
    }
    private static let offered: Set<String> = ["screen", "go", "read", "tool_result_page", "act"]
    package func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: Self.offered, turn: turn, surface: surface).filter { Self.offered.contains($0.name) }
    }
    package func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        var mac = self.mac
        if let deadline = invocation.waitDeadline {
            mac.deadline = mac.deadline.map { min($0, deadline) } ?? deadline
        }
        let invocation = invocation.serving(mac: mac)
        guard Self.offered.contains(tool) else {
            throw refusal("This courier only offers its scoped screen, go, read, result paging and act operations. That call did not run.")
        }
        calls += 1
        guard calls <= 24 else { throw refusal("Desktop conversation call budget exceeded.") }
        var args = input.filter { $0.value != .null }
        var typing = false, submitting = false, selecting = false
        if tool == "screen" {
            args["app"] = .string(bundle); args["pixels"] = .bool(false)
        } else if tool == "go" {
            selectionSucceeded = false
            if await frontmostBundle() != bundle {
                // Use the app name because go interprets dotted bundle IDs as web addresses.
                let appName = await MainActor.run {
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
                        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent
                }
                let went = try await inner.dispatch(tool: "go", input: ["name": .string(appName ?? bundle)], surface: surface, turn: turn,
                    invocation: invocation)
                goReport = String(flatten(went).prefix(300))
            }
            guard await frontmostBundle() == bundle else { throw refusal("The exact target app could not be brought forward. \(goReport)") }
            stage = "selecting the conversation"
            // MacFourVerbs' destination wording compares display names. Verify the bundle identity ourselves, then return a fresh scoped read.
            let screen = try await inner.dispatch(tool: "screen", input: ["app": .string(bundle), "pixels": .bool(false)], surface: surface, turn: turn,
                invocation: invocation)
            observed = String(flatten(screen).prefix(120_000))
            return screen
        } else if ["read", "tool_result_page", "act"].contains(tool) {
            let front = await frontmostBundle()
            guard front == bundle else { throw refusal("The target app is no longer in front; no action performed.") }
            if tool == "read" {
                guard args["path"] == nil || args["path"] == .string("") else { throw refusal("This route only reads the on-screen conversation, not files.") }
                args = [:]
            } else if tool == "tool_result_page" {
                // The existing turn-result owner validates handle scope and bounds; no new file reader or persistence is introduced.
            } else {
                // Act can omit its target only after the foreground app is pinned and verified.
                args.removeValue(forKey: "app")
                let target = JSONValue.stringOrEmpty(args["target"])
                // Interpret press as a key only for key names, matching MacControl’s own parser.
                let verb = JSONValue.stringOrEmpty(args["verb"]) == "press" ? (["return", "enter"].contains(target.lowercased()) ? "key" : "click") : JSONValue.stringOrEmpty(args["verb"])
                for key in ["holding", "to", "to_app"] where args[key] == .string("") { args.removeValue(forKey: key) }
                for key in ["seconds", "interval"] where args[key] == .int(0) || args[key] == .double(0) { args.removeValue(forKey: key) }
                if args["repeat"] == .int(1) { args.removeValue(forKey: "repeat") }
                if args["button"] == .string("auto") { args.removeValue(forKey: "button") }
                guard Set(args.keys).isSubset(of: ["verb", "target", "text", "direction", "scroll_amount", "session_id",
                    "__session_id"]) else { throw refusal("Unsupported desktop action fields.") }
                if submitted {
                    return .object([
                        "ok": .bool(true), "status": .string("already_submitted"),
                        "sent": .bool(false), "automatic_resend": .bool(false),
                        "text": .string(
                            "Submission was already attempted. No additional action was performed. Use read with {} to verify the outgoing message."),
                        "next_action": .object(["tool": .string("read"), "input": .object([:])]),
                    ])
                }
                switch verb {
                case "type":
                    guard !typed, JSONValue.stringOrEmpty(args["text"]) == message else { throw refusal("Only the exact requested message may be typed once.") }
                    guard selectionSucceeded, let composer = try await Self.verifiedComposerTarget(mac: mac, bundle: bundle, label: label, content: "") else {
                        throw refusal("The exact conversation and an empty message box could not be verified. Nothing was typed.")
                    }
                    args["target"] = .string(composer)
                    // These keys run to their end; a person's operation already taking the desktop stops the send here, untyped.
                    try lane?.beginKeys()
                    typed = true // before dispatch: uncertain attempts are never replayed
                    stage = "typing the message"; typing = true
                case "key":
                    guard typed, ["return", "enter"].contains(target.lowercased()) else { throw refusal("Only one message submission key is permitted.") }
                    guard try await Self.verifiedComposerTarget(mac: mac, bundle: bundle, label: label, content: message) != nil else {
                        throw refusal("The conversation or composed message changed. Submission stopped.")
                    }
                    baseline = try await DesktopChatRoute.outgoingOccurrences(mac: mac, message, bundle: bundle, label: label)
                    // Between typing and Return the desktop may yield (the text stays in the box and the receipt says so); Return itself runs to its end.
                    try lane?.beginKeys()
                    submitted = true; stage = "verifying the sent message"; submitting = true
                case "click":
                    if typed {
                        guard ["send", "send message"].contains(target.lowercased()) else { throw refusal(
                            "Only the send control may be clicked after composing.") }
                        guard try await Self.verifiedComposerTarget(mac: mac, bundle: bundle, label: label, content: message) != nil else {
                            throw refusal("The conversation or composed message changed. Submission stopped.")
                        }
                        baseline = try await DesktopChatRoute.outgoingOccurrences(mac: mac, message, bundle: bundle, label: label)
                        try lane?.beginKeys()
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
        }
        // Only a read taken after the submission counts as evidence of it.
        if submitting { observed = "" }
        let response: JSONValue
        // The atomic step a person's request may wait for is this keystroke dispatch, never the model turn around it.
        defer { if typing || submitting { lane?.endKeys() } }
        do { response = try await inner.dispatch(tool: tool, input: args, surface: surface, turn: turn, invocation: invocation) }
        catch { problem = String(error.localizedDescription.prefix(240)); throw error }
        if ["screen", "read", "tool_result_page"].contains(tool) {
            observed = String(flatten(response).prefix(120_000))
        }
        if selecting, case .object(let reply) = response, reply["ok"] == .bool(true) {
            selectionSucceeded = true
        }
        if case .object(let reply) = response, reply["ok"] == .bool(false) {
            if case .string(let text)? = reply["text"] { problem = String(text.prefix { $0 != "\n" }.prefix(240)) }
            // A refusal that touched nothing permits another typing attempt without duplicating text.
            if typing, case .object(let detail)? = reply["detail"],
               case .string(let code)? = detail["error"],
               ["no_match", "ambiguous", "target_disabled", "front_window_changed", "owner_changed_apps"].contains(code) {
                typed = false; stage = "selecting the conversation"
            }
        }
        return response
    }

    @concurrent private static func verifiedComposerTarget(mac: MacOperationContext, bundle: String, label: String,
        content: String) async throws -> String? {
        try MacAccessibilityReader.withReadBudget(context: mac) { mac in try verifiedComposerTargetRead(mac: mac, bundle: bundle, label: label,
            content: content) }
    }
    private static func verifiedComposerTargetRead(mac: MacOperationContext, bundle: String, label: String, content: String) throws -> String? {
        let source = SystemMacAXElementSource()
        guard source.isTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundle else { return nil }
        let windows = try source.nativeWindows(pid: app.processIdentifier, context: mac)
        guard let root = source.nativeApplication(pid: app.processIdentifier, context: mac),
              let focused = MacAXAttributeRead.copyElement(root, kAXFocusedWindowAttribute, context: mac),
              let window = windows.first(where: { CFEqual(focused, $0) }) else { return nil }
        let tree = try MacAccessibilityReader.elements(in: window, searching: "the exact desktop conversation and composer", context: mac) {
            MacAXAttributeRead.text($0, kAXSubroleAttribute, context: mac) != "AXApplicationLog"
        }
        func named(_ node: AXUIElement) -> Bool {
            MacAXAttributeRead.text(node, kAXTitleAttribute, context: mac) == label || MacAXAttributeRead.text(node, kAXDescriptionAttribute,
                context: mac) == label
        }
        guard !tree.contains(where: { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXSheetRole || MacAXAttributeRead.text($0,
            kAXSubroleAttribute, context: mac) == kAXDialogSubrole }),
              named(window) || tree.contains(where: {
                  named($0) && (MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == "AXHeading"
                      || MacAXAttributeRead.copyRaw($0, kAXSelectedAttribute, context: mac) as? Bool == true)
              }) else { return nil }
        let boxes = tree.filter {
            [kAXTextAreaRole, kAXTextFieldRole].contains(MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac))
                && MacAXAttributeRead.text($0, kAXSubroleAttribute, context: mac) != kAXSearchFieldSubrole
                && MacAXAttributeRead.copyRaw($0, kAXEnabledAttribute, context: mac) as? Bool == true
        }
        guard boxes.count == 1 else { return nil }
        let value = try DesktopComposer.composerValue(mac: mac, boxes[0])
        guard
              value.trimmingCharacters(in: .whitespacesAndNewlines) == content.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return MacAXAttributeRead.text(boxes[0], kAXRoleAttribute, context: mac) == kAXTextAreaRole ? "text area" : "text"
    }
    /// Native outgoing rows may prove delivery; replies still arrive through the authenticated inbound door.
    func project(answer: [String: JSONValue], agent: String) async -> JSONValue {
        if submitted, let baseline {
            do {
                if let count = try await DesktopChatRoute.outgoingOccurrences(mac: mac, message, bundle: bundle, label: label), count > baseline {
                    return DesktopAgentConversationRoute.delivered(agent)
                }
            } catch { problem = "Outgoing transcript read failed: \(error.localizedDescription)" }
        } else if submitted {
            problem = "No native outgoing-transcript baseline was available; delivery is unconfirmed."
        }
        // Frame model-written notes inside fixed evidence from this request’s fence.
        let note = String(JSONValue.stringOrEmpty(answer["detail"]).prefix(300))
        let why = [problem, note.isEmpty ? "" : "operator: " + note].filter { !$0.isEmpty }.joined(separator: " ")
        return stopped(agent, why: why)
    }
    func stopped(_ agent: String, why: String) -> JSONValue {
        DesktopAgentConversationRoute.stopped(agent, app: "the app", stage: stage, typed: typed, submitted: submitted,
                                              why: why.isEmpty ? problem : why)
    }
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

/// The one desktop lane: one operation drives the desktop at a time, and what the person asks for goes now. The agent's own operation runs only while the
/// person is away; otherwise a send is held by its conversation and does not claim the lane. The newest of the
/// person's asks takes the lane from whatever holds it: a holder that is posting keys ends that bounded sequence first; any other holder is cancelled and
/// left to finish dying on its own, never waited for. An older waiting ask is told it was superseded. So "busy" is only ever said to the agent's own work,
/// and means an operation is driving the desktop now. Keys never wait and every observed step is bounded.
package final class DesktopLane: Sendable {
    static let shared = DesktopLane()

    static func askedByPerson(_ turn: Turn) -> Bool { turn.askedByPerson }
    /// The agent's own desktop work needs positive away evidence; unknown presence counts as here.
    static var personHere: Bool { MacPersonInput.presence()?.here != false }

    enum Admission {
        case admitted(Ticket)
        /// The agent's own operation found the desktop driven now.
        case busy
        /// A newer ask of the person's took the lane first.
        case superseded
        case cancelled
    }

    /// One admitted operation.
    package final class Ticket: Sendable {
        let person: Bool
        fileprivate enum Yield { case released, typing(ScopedWaiter), cancelled }
        private struct State {
            var keys = false
            var typed = false
            var yieldAsked = false
            var yielded = false
            var released = false
            var cancel: (@Sendable () -> Void)?
            var waiters: [ScopedWaiter] = []
        }
        private let state = Mutex(State())
        init(person: Bool) { self.person = person }

        /// A keystroke sequence (paste or type, Return) is about to be posted: a takeover waits for its end, so no key is cut short. A takeover already
        /// taken ends the operation here instead.
        func beginKeys() throws {
            let yielded = state.withLock { state -> Bool in
                if !state.yielded { state.keys = true; state.typed = true }
                return state.yielded
            }
            if yielded { throw CancellationError() }
        }
        /// The keystroke sequence ended; a takeover asked meanwhile cancels the operation now and wakes the person's operation.
        func endKeys() {
            let (cancel, waiters) = state.withLock { state -> ((@Sendable () -> Void)?, [ScopedWaiter]) in
                state.keys = false
                guard state.yieldAsked else { return (nil, []) }
                let waiting = state.waiters
                state.waiters = []
                guard !state.yielded else { return (nil, waiting) }
                state.yielded = true
                return (state.cancel, waiting)
            }
            cancel?()
            for waiter in waiters { waiter.resume() }
        }
        /// The operation yielded the desktop before any key was posted: nothing of it is anywhere but in its owner.
        var yieldedUntyped: Bool { state.withLock { $0.yielded && !$0.typed } }

        fileprivate func started(_ cancel: @escaping @Sendable () -> Void) {
            let late = state.withLock { state -> Bool in
                state.cancel = cancel
                return state.yielded
            }
            if late { cancel() }
        }
        /// Keys in flight: the waiter wakes when they end. Otherwise the operation is cancelled now (once) and the lane is free to take.
        fileprivate func yieldToPerson() -> Yield {
            let (yield, cancel) = state.withLock { state -> (Yield, (@Sendable () -> Void)?) in
                guard !state.released else { return (.released, nil) }
                state.yieldAsked = true
                if state.keys {
                    let waiter = ScopedWaiter()
                    state.waiters.append(waiter)
                    return (.typing(waiter), nil)
                }
                guard !state.yielded else { return (.cancelled, nil) }
                state.yielded = true
                return (.cancelled, state.cancel)
            }
            cancel?()
            return yield
        }
        fileprivate func release() {
            let waiters = state.withLock { state -> [ScopedWaiter] in
                state.released = true
                let waiting = state.waiters
                state.waiters = []
                return waiting
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    private struct Lane {
        var holder: Ticket?
        /// Each person's ask takes the next number; only the newest may take the lane.
        var newest = 0
    }
    private let lane = Mutex(Lane())

    /// The newest person's ask takes the lane, waiting at most for keys in flight; the agent's own never queues.
    func admit(person: Bool) async -> Admission {
        let order = person ? lane.withLock { state -> Int in state.newest += 1; return state.newest } : 0
        while !Task.isCancelled {
            enum Next { case taken(Ticket), busy, superseded, yield(Ticket) }
            let next = lane.withLock { state -> Next in
                if person, state.newest != order { return .superseded }
                guard let held = state.holder else {
                    let ticket = Ticket(person: person)
                    state.holder = ticket
                    return .taken(ticket)
                }
                return person ? .yield(held) : .busy
            }
            switch next {
            case .taken(let ticket): return .admitted(ticket)
            case .busy: return .busy
            case .superseded: return .superseded
            case .yield(let held):
                switch held.yieldToPerson() {
                case .released: continue
                case .typing(let keysEnded): await keysEnded.park()
                case .cancelled:
                    // The cancelled holder finishes dying on its own; the lane is this ask's now, unless a newer ask came meanwhile.
                    let taken = lane.withLock { state -> Ticket? in
                        guard state.newest == order, state.holder === held else { return nil }
                        let ticket = Ticket(person: person)
                        state.holder = ticket
                        return ticket
                    }
                    if let taken { return .admitted(taken) }
                }
            }
        }
        return .cancelled
    }

    /// Run the admitted operation where the lane can cancel it to yield; Stop reaches it as well. Releasing the lane is its settlement; a holder that was
    /// taken over releases nothing of the new holder's.
    func operate<T: Sendable>(_ ticket: Ticket, _ body: @escaping @Sendable () async -> T) async -> T {
        let work = Task { await body() }
        ticket.started { work.cancel() }
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        lane.withLock { state in if state.holder === ticket { state.holder = nil } }
        ticket.release()
        return value
    }
}
