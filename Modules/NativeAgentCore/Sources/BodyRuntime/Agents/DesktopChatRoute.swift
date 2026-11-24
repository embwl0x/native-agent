import AppKit
import ApplicationServices
import SenseCore
import MacNerves
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import Synchronization
// Blueprint: | `DesktopChatRoute.swift` | `accessibility_permission_missing`, `settle`; Non-main recipe-bound sends retain uncertainty and settlement. |

/// Desktop chat selectors and reply reads belong to the saved recipe for the exact target chat.
public struct DesktopChatRoute: Sendable {
    enum Blocker: String, Error {
        case offline = "{app} isn't open. Open {app} and show its chat before sending. Nothing was sent."
        case permission = "Allow NativeAgent Accessibility access so it can use {app}'s window. Nothing was sent."
        case window = "{app} isn't showing its chat. Nothing was sent."
        case thread = "Agent's own chat in {app} couldn't be found or opened, so nothing was sent."
        case missing = "Agent's own chat in {app} is gone, so nothing was sent; the next message opens a new side chat there."
        case typing = "{app}'s message box didn't take the text. Nothing was sent; check {app}'s message box."
        case heldOff
        case submission = "{app} didn't confirm the message. Check Agent's chat in {app}; it won't be resent automatically."
        case moved = "{app} left Agent's chat before answering. The message was sent; its answer will be in Agent's chat in {app}."
        /// Resolve configured agent and app names instead of assuming a fixed persona.
        func detail(mac: MacOperationContext, _ name: String, app: String) -> String {
            self == .heldOff ? MacAttentionSessionStore.sendRefusal(context: mac) : Self.named(rawValue, name, app: app)
        }
        static func named(_ text: String, _ name: String, app: String) -> String {
            text.replacingOccurrences(of: "Agent", with: name).replacingOccurrences(of: "{app}", with: app)
        }
    }
    /// Find missing recipe labels before input so the refusal can prove nothing was sent.
    struct Mismatch: Error { let key: String, wanted: String }
    /// After Return, missing outgoing rows leave submission uncertain; retain the pre-input log baseline.
    struct Unconfirmed: Error { let rows: Int? }
    /// Bind proof to the recipe used at send time; unmatched window labels fail without guessing.
    let recipe: AgentRecipeStore.Recipe
    let bundleID: String
    let ui: AgentHostRow.DesktopChat
    var live: AgentConversationLiveTarget?
    var appName: String { recipe.host.displayName }
    var untitled: String { ui.newChat }
    /// One send's own bookkeeping. The desktop itself is the one desktop lane's (`DesktopLane`): typing takes it, observing a reply holds nothing, so
    /// sends no longer exclude each other here. AX, input, waits and settlement run without holding this lock.
    private final class Progress: Sendable {
        private struct State: Sendable {
            var lastChat: String?
            var pressedReturn = false
            var observations: [String: JSONValue] = [:]
        }
        private let state = Mutex(State())
        func observe(_ fields: [String: JSONValue]) {
            state.withLock { $0.observations.merge(fields) { first, _ in first } }
        }
        func receipt(_ result: JSONValue) -> JSONValue {
            guard case .object(let fields) = result else { return result }
            return .object(fields.merging(state.withLock { $0.observations }) { _, new in new })
        }
        var lastChat: String? {
            get { state.withLock { $0.lastChat } }
            set { state.withLock { $0.lastChat = newValue } }
        }
        var pressedReturn: Bool {
            get { state.withLock { $0.pressedReturn } }
            set { state.withLock { $0.pressedReturn = newValue } }
        }
    }
    private let progress = Progress()
    /// Uncertain results must retain the destination chat for later reconciliation.
    private var lastChat: String? {
        get { progress.lastChat }
        nonmutating set { progress.lastChat = newValue }
    }
    /// After Return, errors leave delivery uncertain.
    private var pressedReturn: Bool {
        get { progress.pressedReturn }
        nonmutating set { progress.pressedReturn = newValue }
    }
    private typealias AX = DesktopComposer

    @concurrent public static func perform(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, plan: [String: JSONValue],
        dataRoot: URL) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"] else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string("Missing contact.")])
        }
        let recipes: [AgentRecipeStore.Recipe]
        do {
            recipes = try await Task.detached {
                try AgentRecipeStore.requireAvailable()
                return AgentRecipeStore.recipes
            }.value
        } catch {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The desktop recipe catalog could not be read: \(error.localizedDescription). Nothing was sent.")])
        }
        guard case .string(let bundle)? = plan["app_bundle_id"],
              let recipe = recipes.first(where: { $0.host.route == .desktopChat && $0.host.bundleIDs.contains(bundle) }),
              let ui = recipe.host.desktopChat else {
                    return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string("""
                                No recipe says how to drive this app's chat window (mac: mac, route desktop-chat with desktopChat labels). Read it with \
                                agent.recipe and fix it with agent.recipe_write. Nothing was sent.
                                """)])
        }
        let route = Self(recipe: recipe, bundleID: bundle, ui: ui, live: conversation.liveTarget)
        if plan["status"] == .string("desktop_chat_read") {
            var reading = mac
            reading.observationMode = .passive
            return await route.read(mac: reading, peerID: peerID, thread: plan["conversation_id"]?.stringValue, dataRoot: dataRoot)
        }
        guard case .string(let text)? = plan["text"] else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string("Missing message.")])
        }
        func execute(mac: MacOperationContext) async -> JSONValue {
            do { try await route.prepareRenderer(mac: mac) }
            catch {
                return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string("\(route.appName)'s Accessibility preparation failed: \(error.localizedDescription). Nothing was sent.")])
            }
            var reading = mac
            reading.observationMode = .passive
            if plan["dry_run"] == .bool(true) { return await route.dryRun(turn: turn, mac: reading, peerID: peerID, dataRoot: dataRoot) }
            return await route.perform(turn: turn, mac: reading, conversation: conversation, text, peerID: peerID, plan: plan, dataRoot: dataRoot)
        }
        // A resumed queue must not inherit the driver generation its first attempt lost. Explicit handback still requires an explicit return.
        if mac.driver?.handedBack == true {
                    return .object(["status": .string("unavailable"), "sent": .bool(false),
                "detail": .string(MacAttentionSessionStore.sendRefusal(context: mac))])
        }
        let binding: MacDriverBinding
        do { binding = try await MacAttentionSessionStore.shared.bindDriver() }
        catch {
                    return .object(["status": .string("unavailable"), "sent": .bool(false),
                "reason": .string("trust_policy_unavailable"), "detail": .string(error.localizedDescription),
                "remedy": Repair.why(owner: "trust/policy.json", tap: "Trust",
                    instruction: "Preserve the policy bytes and repair the authority before continuing.")])
        }
        return await withTaskCancellationHandler {
            await withAgentMacDriver(mac, driver: binding) { mac in
                var hands = mac
                hands.background = true
                return route.progress.receipt(await execute(mac: hands))
            }
        } onCancel: { binding.cancel() }
    }

    /// Explicit verification reads only the authored controls, without input or selector guessing. A mismatch belongs to agent.recipe_write.
    private func dryRun(turn: NativeAgentCore.Turn, mac: MacOperationContext, peerID: String, dataRoot: URL) async -> JSONValue {
        var name = ""
        do {
            name = try await Task.detached { try AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent }.value
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { throw Blocker.offline }
            guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
            let person = DesktopLane.askedByPerson(turn)
            guard case .admitted(let ticket) = await DesktopLane.shared.admit(person: person) else {
                return .object(["status": .string("not_started"), "dry_run": .bool(true), "sent": .bool(false), "detail": .string(person
                    ? "The check did not start: it was stopped, or the person's newer desktop request took the desktop first. Nothing was checked."
                    : "Another operation is driving the desktop now, so nothing was checked. Check again later.")])
            }
            try await DesktopLane.shared.operate(ticket) { () -> Result<Void, Error> in
                Result { try self.controls(mac: mac) }
            }.get()
            return .object(["status": .string("passed"), "dry_run": .bool(true), "sent": .bool(false),
                "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                "recipe_version": .int(Int64(recipe.recipeVersion)),
                "detail": .string("The authored controls are present. Nothing was typed or sent.")])
        } catch {
            let detail: String
            var fields: [String: JSONValue] = [:]
            if let miss = error as? Mismatch { let report = said(mac: mac, miss); detail = report.detail; fields = report.fields }
            else if let blocker = error as? Blocker {
                detail = blocker.detail(mac: mac, name, app: appName)
                if blocker == .permission { fields = Self.permissionFields }
            } else { detail = error.localizedDescription }
            fields.merge(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false), "detail": .string(detail)]) { $1 }
            fields["remedy"] = Repair.reconcile(instruction: "Read the authored recipe and correct its exact controls before explicitly sending again.",
                nextCall: .object(["tool": .string("app"), "input": .object([
                    "action": .string("agent.recipe"), "args": .object(["host": .string(recipe.host.id)])])]))
            return .object(fields)
        }
    }

    private func controls(mac: MacOperationContext) throws {
        let tree = try walk(mac: mac, window(mac: mac))
        guard tree.contains(where: { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.log }) else {
            throw Mismatch(key: "log", wanted: ui.log)
        }
        try checkedComposer(mac: mac, tree)
        guard tree.contains(where: {
            MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXButtonRole
                && MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.newChat
        }) else { throw Mismatch(key: "newChat", wanted: ui.newChat) }
    }

    func nearest(mac: MacOperationContext, _ wanted: String, among: [String]? = nil) throws -> [String] {
        func words(_ text: String) -> Set<Substring> { Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }) }
        let goal = words(wanted)
        let labels: [String]
        if let among { labels = among }
        else {
            labels = try windows(mac: mac).flatMap { try walk(mac: mac, $0) }.flatMap { node in
                [kAXTitleAttribute, kAXDescriptionAttribute].map { MacAXAttributeRead.text(node, $0, context: mac) }
            }
        }
        let seen = Set(labels
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }.filter { !$0.isEmpty })
        func shared(_ label: String) -> Int { goal.intersection(words(label)).count }
        return Array(seen.sorted { (shared($0), $1) > (shared($1), $0) }.prefix(5))
    }

    static func quoted(_ labels: [String]) -> String { labels.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") }

    func said(mac: MacOperationContext, _ miss: Mismatch, then: String = "Nothing was sent.") -> (detail: String, fields: [String: JSONValue]) {
        let labels: [String]
        do { labels = try nearest(mac: mac, miss.wanted) }
        catch {
            return ("\(appName)'s recipe control \(miss.key) could not be resolved: \(miss.wanted). "
                + "Reading nearby controls failed: \(error.localizedDescription). " + then,
                ["reason": .string("recipe_mismatch"), "selector": .string(miss.key), "read_error": .string(error.localizedDescription)])
        }
        return ("\(appName)'s window has no \u{201C}\(miss.wanted)\u{201D} (its recipe's \(miss.key))"
                    + (labels.isEmpty ? "" : "; nearest: " + Self.quoted(labels)) + ". " + then,
                ["reason": .string("recipe_mismatch"), "selector": .string(miss.key), "labels": .array(labels.map(JSONValue.string))])
    }

    /// Missing outgoing text after Return cannot justify resend; report whether log rows changed shape or never appeared.
    func unconfirmed(mac: MacOperationContext, _ before: Int?, name: String) -> (detail: String, fields: [String: JSONValue]) {
        let unsure = "The message may have gone out; check \(name)'s chat in \(appName) and don't resend it."
        let rows: [AXUIElement]
        do { rows = try logRows(mac: mac, walk(mac: mac, window(mac: mac))) }
        catch { return (error.localizedDescription + " " + unsure, ["reason": .string("accessibility_read_incomplete")]) }
        guard let before, rows.count > before else {
            // Report the current window’s labels so repair uses observed evidence.
            var fields = said(mac: mac, Mismatch(key: "userPrefix", wanted: ui.userPrefix)).fields
            fields["reason"] = .string("not_confirmed")
            return (Blocker.submission.detail(mac: mac, name, app: appName), fields)
        }
        let added = Array(rows[before...])
        let row: String
        do {
            row = try added.first.map { node in
                let own = MacAXAttributeRead.text(node, kAXTitleAttribute, context: mac)
                    + MacAXAttributeRead.text(node, kAXDescriptionAttribute, context: mac)
                if own.isEmpty { return String(try texts(mac: mac, node).prefix(2).joined(separator: " ").prefix(80)) }
                return String(own.prefix(80))
            } ?? ""
        }
        catch { return (error.localizedDescription + " " + unsure, ["reason": .string("accessibility_read_incomplete")]) }
        let addedTree: [AXUIElement]
        do { addedTree = try added.flatMap { try MacAccessibilityReader.elements(in: $0, searching: "the outgoing desktop message", context: mac) } }
        catch { return (error.localizedDescription + " " + unsure, ["reason": .string("accessibility_read_incomplete")]) }
        let labels: [String]
        do { labels = try nearest(mac: mac, ui.userPrefix, among: addedTree.flatMap { node in
            [kAXTitleAttribute, kAXDescriptionAttribute].map { MacAXAttributeRead.text(node, $0, context: mac) } + [textValue(node, mac: mac)] })
        } catch { return (error.localizedDescription + " " + unsure, ["reason": .string("accessibility_read_incomplete")]) }
        return ("""
            \(appName)'s chat gained \(added.count) row\(added.count == 1 ? "" : "s") after the message that \
            \(added.count == 1 ? "doesn't" : "don't") read as the agent's\u{20}
            """
                    + "(its recipe's userPrefix \u{201C}\(ui.userPrefix)\u{201D}): \u{201C}\(row)\u{201D}"
                    + (labels.isEmpty ? "" : "; nearest: " + Self.quoted(labels)) + ". " + unsure,
                ["reason": .string("recipe_mismatch"), "selector": .string("userPrefix"), "row": .string(row), "labels": .array(labels.map(JSONValue.string))])
    }

    private func perform(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, _ text: String, peerID: String,
        plan: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        let name: String
        do { name = try await Task.detached { try AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent }.value }
        catch { return .object(["status": .string("unavailable"), "reason": .string("persona_profile_unavailable"), "sent": .bool(false),
            "detail": .string(error.localizedDescription)]) }
        let thread: String?
        if case .string(let saved)? = plan["conversation_id"] { thread = saved }
        else { thread = nil }
        let store = AgentPeerStore(dataRoot: dataRoot)
        // Name the configured agent in its opening message so the chat is recognizable.
        let message = thread == nil && !text.hasPrefix(name) ? name + " here — " + text : text
        // The exact first message of each of the agent's chats, by title: a renamed chat is the agent's only if it opens with exactly that (never just its
        // name).
        let first: String?
        do {
            if let thread { first = try await Task.detached { try Self.firsts(peerID: peerID, dataRoot: dataRoot)[thread] }.value }
            else { first = message }
        }
        catch {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "reason": .string("desktop_identity_unavailable"),
                "detail": .string("""
                    Saved desktop conversation identity could not be read: \(error.localizedDescription). Repair the saved identity file before \
                    sending.
                    """)])
        }
        // Settlement is detached: carry the exact operation and authority, never look up task-local context after crossing that boundary.
        let sendTarget = conversation.liveTarget
        let sendDriver = mac.driver
        // Person-requested sends (the person's own send, or any send in a turn that is the person's own message) go now or report a blocker; only
        // autonomous sends wait for absence.
        let byPerson = turn.personInitiatedSend?.text == text || DesktopLane.askedByPerson(turn)
        let send = DesktopSend(peerID: peerID, dataRoot: dataRoot, text: text, thread: thread, first: first, byPerson: byPerson,
                               sendTarget: sendTarget, sendDriver: sendDriver)
        return await runDesktopSend(turn: turn, mac: mac, name: name, message: message, store: store, send: send)
    }

    private struct DesktopSend: Sendable {
        let peerID: String
        let dataRoot: URL
        let text: String
        let thread: String?
        let first: String?
        let byPerson: Bool
        let sendTarget: AgentConversationLiveTarget?
        let sendDriver: MacDriverBinding?
    }

    /// Hold an autonomous send for a free Mac when its operation still owns the wait.
    private func heldForMac(_ detail: String, send: DesktopSend) async -> JSONValue {
        let (byPerson, sendDriver, sendTarget) = (send.byPerson, send.sendDriver, send.sendTarget)
        let (dataRoot, text, thread) = (send.dataRoot, send.text, send.thread)
        guard !byPerson, !Task.isCancelled, sendDriver?.handedBack != true,
              let live = sendTarget, let row = live.recordID, let operation = live.operationID else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "detail": .string(detail)])
        }
        do {
            try await Task.detached {
                try AgentConversationStore(dataRoot: dataRoot).holdForMac(id: row, operation: operation, text: text,
                    conversation: thread, detail: detail)
            }.value
            return .object(["status": .string("held"), "reason": .string("mac_busy"), "sent": .bool(false),
                "completed": .bool(false), "detail": .string(detail + " Waiting for the Mac to be free; it will go then. Do not send it again.")])
        } catch {
                return .object(["status": .string("unavailable"), "sent": .bool(false),
                "detail": .string(detail + " Saving the waiting message failed: " + error.localizedDescription)])
        }
    }

    /// Save the chat's exact title and opening message.
    private func remember(_ title: String?, send: DesktopSend) async throws {
        let (thread, first, peerID, dataRoot) = (send.thread, send.first, send.peerID, send.dataRoot)
        try await Task.detached { try Self.remember(title, replacing: thread, first: first, peerID: peerID, dataRoot: dataRoot) }.value
    }

    /// Drive and confirm submission under the desktop lane, then observe its answer.
    private func runDesktopSend(turn: Turn, mac: MacOperationContext, name: String, message: String, store: AgentPeerStore,
                                send: DesktopSend) async -> JSONValue {
        let (byPerson, thread, first, dataRoot) = (send.byPerson, send.thread, send.first, send.dataRoot)
        var submissionConfirmed = false
        let result: Result<Driven, Error>
        do {
            try Task.checkCancellation()
            // Opening the chat, typing and confirming the outgoing row take the one desktop lane; the reply is observed after it, holding nothing.
            let ticket: DesktopLane.Ticket
            switch await DesktopLane.shared.admit(person: byPerson) {
            case .admitted(let admitted): ticket = admitted
            case .cancelled: throw CancellationError()
            case .busy:
                return .object(["status": .string("busy"), "sent": .bool(false), "completed": .bool(false), "detail": .string("""
                    Another operation is driving the desktop right now, so \(appName) was not touched. Nothing was sent; send again when it finishes.
                    """)])
            case .superseded:
                return .object(["status": .string("not_sent"), "sent": .bool(false), "completed": .bool(false), "detail": .string("""
                    Superseded by the person's newer desktop request before \(appName) was touched; nothing was sent and nothing of it waits. Send it \
                    again if it is still wanted.
                    """)])
            }
            let driven = await DesktopLane.shared.operate(ticket) { () -> Result<Driven, Error> in
                do { return .success(try await self.drive(turn: turn, mac: mac, message, thread: thread, first: first,
                    lane: ticket, dataRoot: dataRoot)) }
                catch { return .failure(error) }
            }
            if ticket.yieldedUntyped {
                guard byPerson else {
                    return await heldForMac("The person asked for the desktop, so this message stepped aside before anything was written.", send: send)
                }
                return .object(["status": .string("not_sent"), "sent": .bool(false), "completed": .bool(false), "detail": .string("""
                    Set aside for the person's newer desktop request before anything was typed; nothing was sent and nothing of it waits. Send it \
                    again if it is still wanted.
                    """)])
            }
            let sent = try driven.get()
            submissionConfirmed = true
            result = .success(sent)
        }
        catch { result = .failure(error) }
        let stopped = Task.isCancelled
        let confirmed = submissionConfirmed
        return await settle {
            await settleDesktopSend(result, mac: mac, name: name, store: store, send: send, stopped: stopped, confirmed: confirmed)
        }
    }

    // An uncertain send keeps its chat, so the thread resumes instead of being orphaned.
    private func uncertain(_ detail: String, _ fields: [String: JSONValue] = [:], send: DesktopSend, confirmed: Bool) async -> JSONValue {
        var result = fields.merging(["status": .string("outcome_unknown"), "completed": .bool(false),
            "terminal": .bool(true), "reply_observation": .string("failed"), "detail": .string(detail)]) { $1 }
        if confirmed { result["sent"] = .bool(true) }
        let chat = lastChat
        if let chat, chat != untitled {
            result["conversation_id"] = .string(chat)
            do { try await remember(chat, send: send) }
            catch { result["identity_persistence_error"] = .string("The sent conversation identity could not be saved: "
                + error.localizedDescription + ". Repair its identity file; do not repeat the send.") }
        }
        return .object(result)
    }

    /// Record the submitted message, or reconcile the exact submission evidence after driving. The answer is read when asked for.
    private func settleDesktopSend(_ result: Result<Driven, Error>, mac: MacOperationContext, name: String,
                                   store: AgentPeerStore, send: DesktopSend, stopped: Bool, confirmed: Bool) async -> JSONValue {
        let (peerID, thread, sendDriver) = (send.peerID, send.thread, send.sendDriver)
        do {
            let title = try result.get().chat
            var sent: [String: JSONValue] = ["status": .string("sent"), "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                "sent": .bool(true), "completed": .bool(false), "continued": .bool(thread != nil),
                "detail": .string("Sent; \(appName) answers in \(name)'s chat there. Read the answer with agent.read.")]
            if let title {
                do { try await remember(title, send: send) }
                catch { sent["identity_persistence_error"] = .string("The message was sent, but its conversation identity could not be saved: "
                    + error.localizedDescription + ". Repair its identity file; do not repeat the send.") }
                sent["conversation_id"] = .string(title)
                sent["read_with"] = Self.readWith(peerID: peerID, title: title)
            }
            await Task.detached { store.recordProof(peerID: peerID, inbound: false, outbound: true) }.value
            return .object(sent)
        } catch {
            if let failure = error as? MacAccessibilityReader.NativeReadFailure {
                if pressedReturn || confirmed {
                    return await uncertain(failure.detail + " " + (confirmed
                        ? "The message was sent; its answer remains unconfirmed. Nothing was resent."
                        : "Return was posted; message submission is unconfirmed. Nothing was resent."), send: send, confirmed: confirmed)
                }
                return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string(failure.detail + " Nothing was sent.")])
            }
            if confirmed {
                if let blocker = error as? Blocker, blocker == .moved {
                    return await uncertain(blocker.detail(mac: mac, name, app: appName),
                        ["reply_observation": .string("failed"), "terminal": .bool(true)], send: send, confirmed: confirmed)
                }
                return await uncertain("""
                    \(appName)'s answer couldn't be read. The message was sent; check \(name)'s chat in \(appName). It won't be resent \
                    automatically.
                    """, send: send, confirmed: confirmed)
            }
            if let covered = error as? MacScreenLock.Covered {
                if pressedReturn {
                    return await uncertain(covered.detail + " Return was posted; submission is unconfirmed. Nothing was resent.",
                        send: send, confirmed: confirmed)
                }
                if covered.code == "human_takeover", !pressedReturn, !stopped { return await heldForMac(covered.detail, send: send) }
                return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string(
                    covered.detail + " Nothing was sent.")])
            }
            // Return the first recipe/window mismatch with its owning repair.
            if let miss = error as? Mismatch {
                let report = said(mac: mac, miss)
                return .object(report.fields.merging(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                    "agent": .string("peer:" + peerID), "transport": .string("desktopChat"), "detail": .string(report.detail)]) { $1 })
            }
            if let unconfirmed = error as? Unconfirmed {
                let report = self.unconfirmed(mac: mac, unconfirmed.rows, name: name)
                return await uncertain(report.detail, report.fields, send: send, confirmed: confirmed)
            }
            if let blocker = error as? Blocker {
                if blocker == .heldOff, pressedReturn {
                    return await uncertain("""
                        Use of the Mac was handed back, so \(name) stopped using \(appName). Return had already been posted; message \
                        submission is unconfirmed. Check \(name)'s chat in \(appName) before trying again; nothing was resent.
                        """, send: send, confirmed: confirmed)
                }
                if [.moved, .submission].contains(blocker) || pressedReturn { return await uncertain(blocker.detail(mac: mac, name,
                    app: appName), send: send, confirmed: confirmed) }
                if blocker == .heldOff, !stopped {
                    let detail = withAgentMacDriver(mac, driver: sendDriver) { mac in MacAttentionSessionStore.sendRefusal(context: mac) }
                    return await heldForMac(detail, send: send)
                }
                let shown: String?
                if blocker == .window {
                    do { shown = try await MacAccessibilityReader.read(context: mac) { mac in try showing(mac: mac) } }
                    catch { shown = "an unreadable window: \(error.localizedDescription)" }
                } else { shown = nil }
                let detail = shown.map { "\(appName) isn't showing its chat; it shows \($0). Nothing was sent." }
                var result: [String: JSONValue] = ["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string(detail ?? blocker.detail(mac: mac, name, app: appName))]
                if blocker == .permission { result.merge(Self.permissionFields) { _, new in new } }
                // Drop a definitely removed chat handle so a later explicit send can open a new chat.
                if blocker == .missing { result["conversation_id"] = .null }
                return .object(result)
            }
            if let refusal = error as? MacNativeActionFailure, case .driver = refusal,
               !pressedReturn, !stopped {
                let detail = withAgentMacDriver(mac, driver: sendDriver) { mac in MacAttentionSessionStore.sendRefusal(context: mac) }
                return await heldForMac(detail, send: send)
            }
            // Before Return, report the specific failure without implying submission.
            guard pressedReturn else {
                return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                                "detail": .string("\(appName) couldn't be driven: \(error.localizedDescription). Nothing was sent.")])
            }
            return await uncertain(Blocker.submission.detail(mac: mac, name, app: appName), send: send, confirmed: confirmed)
        }
    }

    // MARK: - One exchange

    private static var permissionFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["reason": .string("accessibility_permission_missing")]
        fields["remedy"] = SystemPermissionPreflight.remedy("accessibility")
        return fields
    }

    /// What the lane part of a send hands to its reply observation.
    struct Driven: Sendable {
        let before: Int
        let chat: String?
    }

    /// The send's desktop part, under the lane: open the chat, type, submit and see the outgoing row.
    @concurrent func drive(turn: NativeAgentCore.Turn, mac: MacOperationContext, _ message: String, thread: String?, first: String?,
        lane: DesktopLane.Ticket, dataRoot: URL) async throws -> Driven {
        guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
        let opened = try await inChatWindow(turn: turn, mac: mac) {
            try await showWindow(turn: turn, mac: mac)
            return try await openThread(turn: turn, mac: mac, thread, first: first)
        }
        let reopen = opened.reopen
        let chat = opened.chat
        lastChat = chat
        let key = TextNormalization.collapseWhitespace(message)
        func sent() throws -> Int {
            try turns(mac: mac, walk(mac: mac, window(mac: mac)))
                .filter { $0.user && TextNormalization.collapseWhitespace($0.text) == key }.count
        }
        func ownsChat() throws -> Bool {
            let all = try turns(mac: mac, walk(mac: mac, window(mac: mac)))
            return thread == nil ? all.isEmpty : opensWith(all, first)
        }
        var rows: Int?
        let before = try await inChatWindow(turn: turn, mac: mac) {
            try await typeAndSubmit(turn: turn, mac: mac, message, chat: chat ?? untitled, reopen: reopen, ownsChat: ownsChat,
                count: { rows = try logRows(mac: mac, walk(mac: mac, window(mac: mac))).count; return try sent() }, lane: lane)
        }
        // An additional exact outgoing row confirms submission, not answer delivery.
        var shown: String?
        do {
            try await until("the message to appear in \(appName)'s chat", mac: mac) {
                let tree = try walk(mac: mac, window(mac: mac))
                guard try turns(mac: mac, tree).filter({ $0.user && TextNormalization.collapseWhitespace($0.text) == key }).count > before else {
                    return false
                }
                shown = try openTitle(mac: mac, tree)
                return true
            }
        } catch let failure as MacAccessibilityReader.NativeReadFailure { throw failure }
        catch { throw Unconfirmed(rows: rows) }
        if thread == nil, shown == nil || shown == untitled {
            let naming = "\(appName) to name the new chat"
            do {
                try await until(naming, mac: mac) {
                    let tree = try walk(mac: mac, window(mac: mac))
                    shown = try openTitle(mac: mac, tree)
                    guard try opensWith(turns(mac: mac, tree), first) else { throw Blocker.moved }
                    return shown != nil && shown != untitled
                }
            } catch let failure as AX.Failure where failure.step == naming {}
        }
        let titled = shown.flatMap { $0 == untitled ? nil : $0 } ?? chat
        lastChat = titled
        return Driven(before: before, chat: titled)
    }

    static func readWith(peerID: String, title: String) -> JSONValue {
        .object(["tool": .string("agent_read"), "input": .object(["agent": .string("peer:" + peerID), "conversation_id": .string(title)])])
    }

    private func read(mac: MacOperationContext, peerID: String, thread: String?, dataRoot: URL) async -> JSONValue {
        var fields: [String: JSONValue] = ["agent": .string("peer:" + peerID), "transport": .string("desktopChat"), "sent": .bool(true)]
        func waiting(_ detail: String) -> JSONValue {
            fields["status"] = .string("waiting")
            fields["completed"] = .bool(false)
            fields["detail"] = .string(detail)
            return .object(fields)
        }
        guard let thread else {
            fields["status"] = .string("nothing_to_read")
            fields["detail"] = .string("No chat in \(appName) is bound to this conversation yet; nothing was read.")
            return .object(fields)
        }
        fields["conversation_id"] = .string(thread)
        fields["read_with"] = Self.readWith(peerID: peerID, title: thread)
        do {
            guard let first = try await Task.detached(operation: { try Self.firsts(peerID: peerID, dataRoot: dataRoot)[thread] }).value else {
                fields["status"] = .string("nothing_to_read")
                fields["detail"] = .string("The chat \u{201C}\(thread)\u{201D} has no saved opening message, so it can't be recognised; nothing was read.")
                return .object(fields)
            }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                return waiting("\(appName) isn't open, so the answer in \u{201C}\(thread)\u{201D} wasn't read. Nothing changed.")
            }
            let snapshot = try await passiveRead(mac: mac)
            guard let title = snapshot.title, title == thread || opensWith(snapshot.turns, first) else {
                return waiting("""
                    \(appName) is showing another chat, so the answer in \u{201C}\(thread)\u{201D} wasn't read. Nothing changed; read again while that chat \
                    is showing, or send the next message, which reopens it.
                    """)
            }
            if title != thread {
                try await Task.detached { try Self.remember(title, replacing: thread, first: first, peerID: peerID, dataRoot: dataRoot) }.value
                fields["conversation_id"] = .string(title)
                fields["read_with"] = Self.readWith(peerID: peerID, title: title)
            }
            let answer = snapshot.turns.lastIndex(where: \.user).map { Array(snapshot.turns[($0 + 1)...]) } ?? []
            let reply = answer.map(\.text).joined(separator: "\n\n")
            guard !reply.isEmpty, !snapshot.generating else {
                if !reply.isEmpty { fields["partial_reply"] = .string(reply); fields["untrusted_remote_data"] = .bool(true) }
                return waiting("\(appName) hasn't finished answering in \u{201C}\(title)\u{201D} yet.")
            }
            let usedRecipe = recipe
            await Task.detached {
                let store = AgentPeerStore(dataRoot: dataRoot)
                store.recordProof(peerID: peerID, inbound: true, outbound: true)
                store.recordRoundTrip(peerID: peerID, workspace: title, recipe: usedRecipe)
            }.value
            fields.merge(["status": .string("answered"), "completed": .bool(true), "reply": .string(reply),
                "untrusted_remote_data": .bool(true)]) { $1 }
            return .object(fields)
        } catch let miss as Mismatch {
            return waiting(said(mac: mac, miss, then: "Nothing was read.").detail)
        } catch let blocker as Blocker {
            return waiting(Blocker.named(blocker.rawValue, "the agent", app: appName) + " Nothing was read.")
        } catch {
            return waiting("\(appName)'s answer couldn't be read: \(error.localizedDescription) Nothing changed; read again.")
        }
    }

    /// A title or persona name alone cannot prove chat ownership; require its exact opening message.
    nonisolated static func firsts(peerID: String, dataRoot: URL) throws -> [String: String] {
        let file = firstsFile(peerID: peerID, dataRoot: dataRoot)
        do { return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }

    nonisolated private static func firstsFile(peerID: String, dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("agents/desktop-chat-" + peerID + ".json")
    }

    /// Replace the previous saved title when recording a rename.
    nonisolated static func remember(_ title: String?, replacing thread: String?, first: String?, peerID: String, dataRoot: URL) throws {
        guard let title, let first else { return }
        let file = firstsFile(peerID: peerID, dataRoot: dataRoot)
        var saved = try firsts(peerID: peerID, dataRoot: dataRoot)
        let previous = saved
        if let thread, thread != title { saved[thread] = nil }
        saved[title] = first
        guard saved != previous else { return }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(saved), to: file)
    }

    private func inChatWindow<T>(turn: Turn, mac: MacOperationContext, work: () async throws -> T) async rethrows -> T {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let held = try await MacBodyNerve.holding(pid: app?.processIdentifier, bundleURL: url, turn: turn, context: mac,
            background: true, expect: .elementOrSurface, observed: progress.observe, work: work)
        return held.value
    }

    /// Select or create only the owned chat; renames require the exact opening turn, and reopening focuses the list entry and presses Return.
    @concurrent func openThread(turn: NativeAgentCore.Turn, mac: MacOperationContext, _ thread: String?, first: String?) async throws -> (
        reopen: Bool, chat: String?) {
        let open = try openTitle(mac: mac, walk(mac: mac, window(mac: mac)))
        if let thread, open == thread {
            guard try opensWith(turns(mac: mac, walk(mac: mac, window(mac: mac))), first) else { throw Blocker.thread }
            return (false, thread)
        }
        let openIsOwned = try thread != nil && opensWith(turns(mac: mac, walk(mac: mac, window(mac: mac))), first)
        try await showSideChats(turn: turn, mac: mac)
        if let thread {
            let saved = try sideChatEntries(mac: mac, named: thread).count
            if saved == 1 { return (true, thread) }
            guard let open, open != untitled, openIsOwned, try sideChatEntries(mac: mac, named: open).count == 1 else {
                // Gone only when the side-chat list is shown and has no entry by that title.
                if saved == 0, try sideChatsPanel(mac: mac, walk(mac: mac, window(mac: mac))) != nil { throw Blocker.missing }
                throw Blocker.thread
            }
            return (true, open)
        } else {
            let new = try buttons(mac: mac) { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.newChat }
            if new.isEmpty { throw Mismatch(key: "newChat", wanted: ui.newChat) }
            guard new.count == 1, let newChat = new.first, try SystemMacAXActSource().performNative(newChat, action: kAXPressAction, turn: turn,
                context: mac).get() == .success else { throw Blocker.thread }
            try await until("a new chat to open in \(appName)", mac: mac) { try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == untitled && turns(
                mac: mac, walk(mac: mac, window(mac: mac))).isEmpty }
            return (false, nil)
        }
    }

    @concurrent func showSideChats(turn: NativeAgentCore.Turn, mac: MacOperationContext) async throws {
        if let back = try buttons(mac: mac, { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.backToMain }).first {
            guard try SystemMacAXActSource().performNative(back, action: kAXPressAction, turn: turn,
                context: mac).get() == .success else { throw Blocker.thread }
            try await until("\(appName) to leave the open chat", mac: mac) { try headerTitle(mac: mac, walk(mac: mac, window(mac: mac))) == nil }
        }
        if try sideChatsPanel(mac: mac, walk(mac: mac, window(mac: mac))) == nil {
            guard let open = try buttons(mac: mac, { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac).hasPrefix(ui.chatsButton) })
                .first else { throw Mismatch(
                key: "chatsButton", wanted: ui.chatsButton) }
            guard try SystemMacAXActSource().performNative(open, action: kAXPressAction, turn: turn,
                context: mac).get() == .success else { throw Blocker.window }
            try await until("\(appName)'s side-chat list to open", mac: mac) { try sideChatsPanel(mac: mac, walk(mac: mac,
                window(mac: mac))) != nil }
        }
    }

    /// Background hands only: Accessibility focus, an Accessibility value write read back exactly, and Return delivered to the app's own process. The
    /// person's screen, keyboard and clipboard are never used, so nothing is activated or restored.
    @concurrent func typeAndSubmit(turn: NativeAgentCore.Turn, mac: MacOperationContext, _ message: String, chat: String, reopen: Bool,
        ownsChat: () throws -> Bool, count: () throws -> Int, lane: DesktopLane.Ticket) async throws -> Int {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        let source = SystemMacAXActSource()
        let sink = CGEventSink()
        func focus(_ node: AXUIElement) throws {
            guard try source.setNativeAttribute(node, attribute: kAXFocusedAttribute, value: kCFBooleanTrue, turn: turn, context: mac).get() == .success
            else { throw Blocker.typing }
        }
        func returnKey(submitting: Bool) throws {
            for down in [true, false] {
                guard mac.driver?.allowsAction(context: mac) == true else { throw Blocker.heldOff }
                guard sink.post(key: MacKeyEvent(keyCode: 36, down: down), toPid: app.processIdentifier, turn: turn, context: mac) else {
                    throw Blocker.typing
                }
                // Only an emitted Return can make submission uncertain; a refusal before key-down proves nothing was sent.
                if submitting { pressedReturn = true }
            }
        }
        if reopen {
            // Only ever the agent's own entry in the side-chat list; never the main chat.
            let entries = try sideChatEntries(mac: mac, named: chat)
            guard entries.count == 1, let entry = entries.first else { throw Blocker.thread }
            try focus(entry)
            try returnKey(submitting: false)
            // Wait for the selected log to load before measuring its baseline.
            try await until("the chat \u{201C}\(chat)\u{201D} to load", mac: mac) {
                try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat && !turns(mac: mac,
                walk(mac: mac, window(mac: mac))).isEmpty }
        }
        let tree = try walk(mac: mac, window(mac: mac))
        guard try openTitle(mac: mac, tree) == chat, try ownsChat() else { throw Blocker.thread }
        // Measure the baseline in the verified loaded chat immediately before input.
        let before = try count()
        // Read the exact composer before any input can overwrite a draft.
        let card = try composer(mac: mac, tree).node
        let box = try composerInput(mac: mac, tree)
        guard try AX.composerValue(mac: mac, box).isEmpty else {
            throw AX.Failure(detail: "The selected chat already holds a draft, left untouched. Finish or clear it before sending.")
        }
        try focus(box)
        try await until("the message box to take focus", mac: mac) {
            guard try ownsChat() else { throw Blocker.thread }
            return try MacAXAttributeRead.checkedBool(box, kAXFocusedAttribute, context: mac) == true
        }
        guard try source.setNativeAttribute(box, attribute: kAXValueAttribute, value: message as CFString, turn: turn, context: mac).get() == .success
        else { throw Blocker.typing }
        let step = "\(appName)'s message box to take the text"
        do {
            try await until(step, mac: mac) {
                guard try ownsChat(), try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat else { throw Blocker.thread }
                return TextNormalization.collapseWhitespace(try AX.composerValue(mac: mac, box)) == TextNormalization.collapseWhitespace(message)
            }
        } catch let failure as AX.Failure where failure.step == step {
            throw AX.Failure(detail: """
                \(appName)'s message box did not take the text written through Accessibility, so nothing was sent. \(appName) cannot be written to \
                in the background.
                """)
        }
        guard try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat, try ownsChat(),
              MacAXAttributeRead.parent(box, context: mac).map({ CFEqual($0, card) }) == true,
              TextNormalization.collapseWhitespace(try AX.composerValue(mac: mac, box)) == TextNormalization.collapseWhitespace(message),
              try MacAXAttributeRead.checkedBool(box, kAXFocusedAttribute, context: mac) == true else {
            throw AX.Failure(detail: "The exact composer did not confirm the full message. Submission stopped; inspect the retained draft before another send.")
        }
        // Return and its confirmation are the keystroke a person's request waits for; it is bounded by each step's patience.
        try lane.beginKeys()
        try returnKey(submitting: true)
        return before
    }

    // MARK: - Reading the window

    /// Outgoing transcript rows may establish delivery; composer values and changed chats cannot. A courier without a native reader may submit but must leave
    /// delivery unconfirmed.
    @concurrent static func outgoingOccurrences(mac: MacOperationContext, _ message: String, bundle: String, label: String) async throws -> Int? {
        let recipes = try await Task.detached {
            try AgentRecipeStore.requireAvailable()
            return AgentRecipeStore.recipes
        }.value
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle,
              let recipe = recipes.first(where: { $0.host.bundleIDs.contains(bundle) && $0.host.desktopChat != nil }),
              let ui = recipe.host.desktopChat else { return nil }
        let route = Self(recipe: recipe, bundleID: bundle, ui: ui, live: nil)
        let read = try await route.passiveRead(mac: mac)
        guard read.title == label else { return nil }
        let key = TextNormalization.collapseWhitespace(message)
        return read.turns.filter { $0.user && TextNormalization.collapseWhitespace($0.text) == key }.count
    }

    struct ChatRow: Sendable { let user: Bool; let text: String }

    struct Read: Sendable { let turns: [ChatRow]; let title: String?; let generating: Bool }

    /// Cold accessibility settlement and the subsequent synchronous reads belong to the non-main send/read path.
    func prepareRenderer(mac: MacOperationContext) async throws {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return }
        try await SystemMacAXElementSource.prepareRenderer(pid: pid, context: mac)
    }

    func passiveRead(mac: MacOperationContext) async throws -> Read {
        try await prepareRenderer(mac: mac)
        return try await MacAccessibilityReader.read(context: mac) { mac in
            let tree = try walk(mac: mac, window(mac: mac))
            let title = try openTitle(mac: mac, tree)
            let box = try composer(mac: mac, tree)
            let controls = try tree + MacAccessibilityReader.attachments(in: box.node, context: mac)
            let answering = box.title.hasSuffix(" " + ui.stop) || controls.contains { button in
                MacAXAttributeRead.text(button, kAXRoleAttribute, context: mac) == kAXButtonRole
                    && [kAXTitleAttribute, kAXDescriptionAttribute].contains { MacAXAttributeRead.text(button, $0, context: mac).hasPrefix(ui.stop) }
            }
            let read = try Read(turns: turns(mac: mac, tree), title: title, generating: answering)
            guard try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == title else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "\(appName)'s open chat changed during the read.", changed: true)
            }
            return read
        }
    }

    nonisolated func windows(mac: MacOperationContext) throws -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        return try SystemMacAXElementSource().nativeWindows(pid: app.processIdentifier, context: mac)
    }

    /// Report window or dialog evidence when none contains the chat; unreadable windows supply no description.
    nonisolated func showing(mac: MacOperationContext) throws -> String? {
        let all = try windows(mac: mac)
        if all.isEmpty { return "no window" + (NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isHidden == true
            ? " (it is hidden)" : "") }
        let seen = try all.compactMap { window -> String? in
            let tree = try walk(mac: mac, window)
            let words = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXStaticTextRole }
                .map { MacAXAttributeRead.text($0, kAXValueAttribute, context: mac).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let title = MacAXAttributeRead.text(window, kAXTitleAttribute, context: mac)
            let text = MacAXAttributeRead.text(window, kAXSubroleAttribute, context: mac) == "AXDialog" || title.isEmpty
                ? words.prefix(2).joined(separator: ": ") : "a window titled \u{201C}\(title)\u{201D}"
            return text.isEmpty ? nil : (text.hasPrefix("a window") ? text : "\u{201C}" + String(text.prefix(200)) + "\u{201D}")
        }
        return seen.isEmpty ? nil : seen.joined(separator: " and ")
    }

    nonisolated func hasLog(mac: MacOperationContext, _ window: AXUIElement) throws -> Bool { try walk(mac: mac, window).contains { MacAXAttributeRead.text($0,
        kAXTitleAttribute, context: mac) == ui.log } }

    nonisolated func window(mac: MacOperationContext) throws -> AXUIElement {
        let all = try windows(mac: mac)
        if all.count == 1, let window = all.first { return window }
        guard let chat = try all.first(where: { try hasLog(mac: mac, $0) }) else { throw all.isEmpty ? Blocker.window as any Error : Mismatch(key: "log",
            wanted: ui.log) }
        return chat
    }

    /// Unminimize or reopen the chat before attempting clicks that hidden or absent windows cannot receive.
    @concurrent func showWindow(turn: NativeAgentCore.Turn, mac: MacOperationContext) async throws {
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty ? [] : try windows(mac: mac)
        for window in existing where MacAXAttributeRead.copyRaw(window, kAXMinimizedAttribute, context: mac) as? Bool == true {
            guard try SystemMacAXActSource().setNativeAttribute(window, attribute: kAXMinimizedAttribute, value: kCFBooleanFalse, turn: turn, context: mac).get(
                ) == .success else { throw Blocker.window }
        }
        guard try !existing.contains(where: { try hasLog(mac: mac, $0) }) else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Blocker.offline }
        do { try await DesktopRouteObservation.openApplication(url, context: mac) }
        catch is OperationWaitBudget.Exceeded {
            throw AX.Failure(detail: "Waited \(Int(DesktopRouteObservation.stepPatience)) seconds for macOS to open \(appName), and it did not happen.",
                step: "macOS to open \(appName)")
        }
        try await until("\(appName)'s chat window to open", mac: mac) { try windows(mac: mac).contains(where: { try hasLog(mac: mac, $0) }) }
    }

    /// Exclude message bodies from navigation walks so long logs cannot exhaust the bound; retain the log node.
    nonisolated func walk(mac: MacOperationContext, _ root: AXUIElement) throws -> [AXUIElement] {
        try MacAccessibilityReader.withReadBudget(context: mac) { mac in
            let content = try ui.contentRole.map { try MacAccessibilityReader.contentRegion(in: root, role: $0, context: mac) } ?? root
            return try MacAccessibilityReader.elements(in: content, searching: "the desktop chat controls", context: mac) {
                MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) != self.ui.log
            }
        }
    }

    nonisolated func buttons(mac: MacOperationContext, _ match: (AXUIElement) -> Bool) throws -> [AXUIElement] {
        try walk(mac: mac, window(mac: mac)).filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXButtonRole && match($0) }
    }

    nonisolated func composer(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> (title: String, node: AXUIElement) {
        // Match stable button labels because Send becomes Stop during replies.
        let boxes = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXButtonRole && MacAXAttributeRead.text($0, kAXTitleAttribute,
            context: mac)
            .contains(ui.composerCore) }
        guard let box = boxes.first else { throw Mismatch(key: "composerCore", wanted: ui.composerCore) }
        if boxes.count > 1 {
            let subtree = try MacAccessibilityReader.elements(in: box, searching: "the selected chat's composer", context: mac)
            guard boxes.dropFirst().allSatisfy({ match in subtree.contains { CFEqual($0, match) } }) else { throw Blocker.window }
        }
        return (MacAXAttributeRead.text(box, kAXTitleAttribute, context: mac), box)
    }

    private static var unidentifiedComposer: AX.Failure {
        AX.Failure(detail: "The exact composer's readable text field could not be identified. Its draft was left untouched; nothing was typed.")
    }

    private func checkedComposer(mac: MacOperationContext, _ tree: [AXUIElement]) throws {
        _ = try AX.composerValue(mac: mac, composerInput(mac: mac, tree))
    }

    /// The message box is whatever in the composer takes typed text, whatever role the app gives it: a text role, an element marked
    /// editable, one holding a caret, or one whose value can be written (an app may expose its box as a button).
    private func composerInput(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> AXUIElement {
        try MacAccessibilityReader.withReadBudget(context: mac) { mac in
            try composerInput(in: composer(mac: mac, tree).node, mac: mac)
        }
    }

    private func parts(of composer: AXUIElement, mac: MacOperationContext) throws -> [AXUIElement] {
        let shown = try MacAccessibilityReader.elements(in: composer, searching: "the selected chat's composer", context: mac)
        return try shown + MacAccessibilityReader.attachments(in: composer, context: mac).filter { part in !shown.contains { CFEqual($0, part) } }
    }

    private func composerInput(in group: AXUIElement, mac: MacOperationContext) throws -> AXUIElement {
        let elements = try parts(of: group, mac: mac)
        let boxes = elements.filter {
            let role = MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac)
            guard role != kAXStaticTextRole, !MacActClosedLoop.isSecureField(role: role),
                  MacAXAttributeRead.text($0, kAXSubroleAttribute, context: mac) != kAXSearchFieldSubrole else { return false }
            return MacActClosedLoop.canType(role: role) || MacAXAttributeRead.copyRaw($0, "AXEditable", context: mac) as? Bool == true
                || MacAXAttributeRead.copyRaw($0, kAXSelectedTextRangeAttribute, context: mac) != nil
                || MacAXAttributeRead.isSettable($0, kAXValueAttribute, context: mac)
        }
        // Text inside an editable box can itself hold a caret: the box is the outermost one.
        let outermost = boxes.filter { box in
            // Walk up to the composer itself, included: it may be the box.
            var node = CFEqual(box, group) ? nil : MacAXAttributeRead.copyElement(box, kAXParentAttribute, context: mac)
            while let current = node {
                if boxes.contains(where: { CFEqual($0, current) }) { return false }
                node = CFEqual(current, group) ? nil : MacAXAttributeRead.copyElement(current, kAXParentAttribute, context: mac)
            }
            return true
        }
        guard outermost.count == 1, let box = outermost.first else { throw Self.unidentifiedComposer }
        return box
    }

    func frame(mac: MacOperationContext, of node: AXUIElement) throws -> CGRect {
        guard let frame = MacAXAttributeRead.frame(node, context: mac) else { throw Blocker.window }
        return frame
    }

    nonisolated func openTitle(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> String? {
        if let title = try headerTitle(mac: mac, tree) { return title }
        guard let panel = try sideChatsPanel(mac: mac, tree) else { return nil }
        return try MacAccessibilityReader.elements(in: panel, searching: "the current desktop chat", context: mac).first { MacAXAttributeRead.text($0,
            ui.current, context: mac) == ui.currentValue }
            .map { entryTitle(MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac)) }
    }

    nonisolated func textValue(_ node: AXUIElement, mac: MacOperationContext) -> String {
        MacAXAttributeRead.copyRaw(node, kAXValueAttribute, context: mac) as? String ?? ""
    }

    nonisolated func entryTitle(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(ui.unreadSuffix) { return String(text.dropLast(ui.unreadSuffix.count)) }
        if text.hasSuffix(ui.actionsSuffix) {
            text = String(text.dropLast(ui.actionsSuffix.count))
            // Exclude the age token before actions so it cannot become part of the chat title.
            if let space = text.lastIndex(of: " ") { text = String(text[..<space]) }
        }
        return text
    }

    nonisolated func headerTitle(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> String? {
        guard let back = tree.first(where: { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXButtonRole && MacAXAttributeRead.text($0,
            kAXTitleAttribute, context: mac) == ui.backToMain }),
              let row = MacAXAttributeRead.parent(back, context: mac) else { return nil }
        let siblings = try MacAccessibilityReader.childElements(in: row, searching: "the desktop chat header", context: mac)
        guard let index = siblings.firstIndex(where: { CFEqual($0, back) }) else { return nil }
        return siblings[(index + 1)...].first { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXStaticTextRole }
            .map { MacAXAttributeRead.text($0, kAXValueAttribute, context: mac) }
    }

    nonisolated func sideChatsPanel(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> AXUIElement? {
        tree.first { MacAXAttributeRead.text($0, kAXSubroleAttribute, context: mac) == "AXLandmarkNavigation" && MacAXAttributeRead.text($0,
            kAXTitleAttribute, context: mac) == ui.chatsPanel }
    }

    func sideChatEntries(mac: MacOperationContext, named title: String) throws -> [AXUIElement] {
        try MacAccessibilityReader.withReadBudget(context: mac) { mac in
            guard let panel = try sideChatsPanel(mac: mac, walk(mac: mac, window(mac: mac))) else { return [] }
            let (source, snapshot) = try MacAccessibilityReader.nativeSnapshot(in: panel, searching: "the desktop chat entries", context: mac)
            var labelled: Set<[Int]> = [], entries: Set<[Int]> = [], found: [AXUIElement] = []
            for node in snapshot.nodes.reversed() {
                guard let element = node.element.flatMap(source.element) else { throw MacAccessibilityReader.NativeReadFailure(
                    detail: "The desktop chat entry could not be read.") }
                let matches = labelled.contains(node.path) || [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                    entryTitle(MacAXAttributeRead.text(element, $0, context: mac)) == title
                } || entryTitle(textValue(element, mac: mac)) == title
                let entry = try matches && node.attributes.role != kAXTextFieldRole && MacAXAttributeRead.copyActions(element, context: mac).contains(
                    kAXPressAction)
                if entry && !entries.contains(node.path) { found.append(element) }
                if matches { labelled.insert(Array(node.path.dropLast())) }
                if entry || entries.contains(node.path) { entries.insert(Array(node.path.dropLast())) }
            }
            try Task.checkCancellation()
            // Finish through the reader's checked budget; its deadline is private to Mac control.
            _ = try MacAXAttributeRead.checkedText(panel, kAXRoleAttribute, context: mac)
            return found.reversed()
        }
    }

    /// Both prefixed-text and grouped-turn AX shapes are live; read either without inventing speaker identity.
    nonisolated func turns(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> [ChatRow] {
        try logRows(mac: mac, tree).compactMap { child in
            if MacAXAttributeRead.text(child, kAXRoleAttribute, context: mac) == kAXStaticTextRole {
                let value = MacAXAttributeRead.text(child, kAXValueAttribute, context: mac)
                if value.hasPrefix(ui.userPrefix) { return ChatRow(user: true, text: String(value.dropFirst(ui.userPrefix.count))) }
                if value.hasPrefix(ui.assistantPrefix) { return ChatRow(user: false, text: String(value.dropFirst(ui.assistantPrefix.count))) }
                return nil
            }
            let kids = try MacAccessibilityReader.childElements(in: child, searching: "the desktop message", context: mac)
            if let first = kids.first, textValue(first, mac: mac) == ui.userLabel {
                return ChatRow(user: true, text: try kids.dropFirst().flatMap { try texts(mac: mac, $0) }.joined(separator: "\n"))
            }
            guard try MacAccessibilityReader.elements(in: child, searching: "the desktop assistant message", context: mac).contains(where: { MacAXAttributeRead
                .text(
                $0, kAXTitleAttribute, context: mac) == ui.assistantMarker }) else { return nil }
            let body = try texts(mac: mac, child)
            return body.isEmpty ? nil : ChatRow(user: false, text: body.joined(separator: "\n"))
        }
    }

    nonisolated func logRows(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> [AXUIElement] {
        guard let log = tree.first(where: { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.log }) else { throw Mismatch(key: "log",
            wanted: ui.log) }
        return try MacAccessibilityReader.childElements(in: log, searching: "the desktop transcript rows", context: mac)
    }

    nonisolated func texts(mac: MacOperationContext, _ node: AXUIElement) throws -> [String] {
        try MacAccessibilityReader.elements(in: node, searching: "the desktop reply text", context: mac)
            .filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXStaticTextRole }
            .map { MacAXAttributeRead.text($0, kAXValueAttribute, context: mac) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func opensWith(_ turns: [ChatRow], _ first: String?) -> Bool {
        guard let first, let opener = turns.first(where: \.user) else { return false }
        return TextNormalization.collapseWhitespace(opener.text) == TextNormalization.collapseWhitespace(first)
    }

    /// Read the condition after registration, then after its source changes. Silence is cancellable and bounded by the step's patience; when it runs out
    /// the failure says what the step waited for (`step`, in the person's words) and what the app showed instead.
    // Every caller is @concurrent (drive, openThread, showSideChats, showWindow, typeAndSubmit), so the wait runs off the main actor in its caller.
    func until(_ step: String, mac: MacOperationContext, _ ready: () throws -> Bool) async throws {
        let events = try await DesktopRouteObservation(bundleID: bundleID, context: mac, patience: DesktopRouteObservation.stepPatience)
        defer { events.stop() }
        var waitingPublished = false
        repeat {
            try Task.checkCancellation()
            if try ready() { return }
            if let live, !waitingPublished {
                await AgentConversationLiveHub.shared.note(live, "Waiting on \(appName)'s desktop controls; cancel to stop waiting.")
                waitingPublished = true
            }
            do { try await events.next() }
            catch is DesktopRouteObservation.Expired {
                let front = NSWorkspace.shared.frontmostApplication
                let saw: String
                if front?.bundleIdentifier != bundleID {
                    saw = "\(front?.localizedName ?? "Another app") was in front, not \(appName)."
                } else if let chat = try? openTitle(mac: mac, walk(mac: mac, window(mac: mac))) {
                    saw = "\(appName) showed the chat \u{201C}\(chat)\u{201D}."
                } else { saw = "\(appName) showed no open chat title." }
                throw DesktopComposer.Failure(detail: "Waited \(Int(DesktopRouteObservation.stepPatience)) seconds for \(step), and it did not "
                    + "happen. " + saw, step: step)
            }
        } while true
    }

}
