import AppKit
import ApplicationServices
import AgentConversations
import MacControl
import MacIntegration
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
        case locked = "Mac is locked, nothing was sent."
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
    private struct State: Sendable {
        var busy = false
        var lastChat: String?
        var lastReply = ""
        var pressedReturn = false
    }
    // Only send bookkeeping is locked. AX, input, waits and settlement run without holding it.
    private static let state = Mutex(State())
    private static func claim() -> Bool {
        state.withLock {
            guard !$0.busy else { return false }
            $0.busy = true
            return true
        }
    }
    private static func release() { state.withLock { $0.busy = false } }
    /// Uncertain results must retain the destination chat for later reconciliation.
    private static var lastChat: String? {
        get { state.withLock { $0.lastChat } }
        set { state.withLock { $0.lastChat = newValue } }
    }
    private static var lastReply: String {
        get { state.withLock { $0.lastReply } }
        set { state.withLock { $0.lastReply = newValue } }
    }
    /// After Return, errors leave delivery uncertain.
    private static var pressedReturn: Bool {
        get { state.withLock { $0.pressedReturn } }
        set { state.withLock { $0.pressedReturn = newValue } }
    }
    private typealias AX = GrokRoutineAccessibility

    @concurrent public static func perform(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, plan: [String: JSONValue],
        dataRoot: URL) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"], case .string(let text)? = plan["text"] else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string("Missing message.")])
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
        func execute(mac: MacOperationContext) async -> JSONValue {
            do { try await route.prepareRenderer(mac: mac) }
            catch {
                return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                    "detail": .string("\(route.appName)'s Accessibility preparation failed: \(error.localizedDescription). Nothing was sent.")])
            }
            if plan["dry_run"] == .bool(true) { return await route.dryRun(turn: turn, mac: mac, peerID: peerID, dataRoot: dataRoot) }
            return await route.perform(turn: turn, mac: mac, conversation: conversation, text, peerID: peerID, plan: plan, dataRoot: dataRoot)
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
            await withAgentMacDriver(mac, driver: binding) { mac in await execute(mac: mac) }
        } onCancel: { binding.cancel() }
    }

    /// Explicit verification reads only the authored controls, without input or selector guessing. A mismatch belongs to agent.recipe_write.
    private func dryRun(turn: NativeAgentCore.Turn, mac: MacOperationContext, peerID: String, dataRoot: URL) async -> JSONValue {
        guard Self.claim() else {
            return .object(["status": .string("busy"), "dry_run": .bool(true), "sent": .bool(false),
                "detail": .string("The previous desktop send is still running. Nothing was checked.")])
        }
        defer { Self.release() }
        var name = ""
        do {
            name = try await Task.detached { try AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent }.value
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { throw Blocker.offline }
            guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
            try await controls(turn: turn, mac: mac)
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

    /// Resolve every required control before any input.
    func controls(turn: NativeAgentCore.Turn, mac: MacOperationContext) async throws {
        try await showWindow(turn: turn, mac: mac)
        try await showSideChats(turn: turn, mac: mac)
        _ = try composer(mac: mac, walk(mac: mac, window(mac: mac)))
        guard try !buttons(mac: mac, { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.newChat }).isEmpty else { throw Mismatch(
            key: "newChat", wanted: ui.newChat) }
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
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { MacAXAttributeRead.text(node, $0, context: mac) } })
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
        guard Self.claim() else {
            return .object(["status": .string("busy"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string("\(appName) is still answering the previous message. Nothing was sent.")])
        }
        let thread: String?
        if case .string(let saved)? = plan["conversation_id"] { thread = saved }
        else { thread = nil }
        let store = AgentPeerStore(dataRoot: dataRoot)
        Self.lastChat = nil; Self.lastReply = ""; Self.pressedReturn = false
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
            Self.release()
            return .object(["status": .string("unavailable"), "sent": .bool(false), "reason": .string("desktop_identity_unavailable"),
                "detail": .string("""
                    Saved desktop conversation identity could not be read: \(error.localizedDescription). Repair the saved identity file before \
                    sending.
                    """)])
        }
        // Settlement is detached: carry the exact operation and authority, never look up task-local context after crossing that boundary.
        let sendTarget = conversation.liveTarget
        let sendDriver = mac.driver
        // Person-requested sends go now or report a blocker; only autonomous sends wait for absence.
        let byPerson = turn.personInitiatedSend?.text == text
        @Sendable func heldForMac(_ detail: String) async -> JSONValue {
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
        @Sendable func remember(_ title: String?) async throws {
            try await Task.detached { try Self.remember(title, replacing: thread, first: first, peerID: peerID, dataRoot: dataRoot) }.value
        }
        var submissionConfirmed = false
        let result: Result<(String, String, JSONValue), Error>
        do {
            try Task.checkCancellation()
            guard byPerson || MacPersonInput.presence()?.here == false else {
                Self.release()
                return await heldForMac(MacPersonInput.presence()?.here == true ? MacAttentionSessionStore.personUsingMac
                    : "I held off because the Mac's input is not yet known to be free. Nothing was sent.")
            }
            result = .success(try await send(turn: turn, mac: mac, message, thread: thread, first: first) { submissionConfirmed = true })
        }
        catch { result = .failure(error) }
        let stopped = Task.isCancelled
        let confirmed = submissionConfirmed
        // An uncertain send keeps its chat, so the thread resumes instead of being orphaned.
        @Sendable func uncertain(_ detail: String, _ fields: [String: JSONValue] = [:]) async -> JSONValue {
            var result = fields.merging(["status": .string("outcome_unknown"), "completed": .bool(false),
                "terminal": .bool(true), "reply_observation": .string("failed"), "detail": .string(detail)]) { $1 }
            if !Self.lastReply.isEmpty { result["partial_reply"] = .string(Self.lastReply); result["untrusted_remote_data"] = .bool(true) }
            if confirmed { result["sent"] = .bool(true) }
            let chat = Self.lastChat
            if let chat, chat != untitled {
                result["conversation_id"] = .string(chat)
                do { try await remember(chat) }
                catch { result["identity_persistence_error"] = .string("The sent conversation identity could not be saved: "
                    + error.localizedDescription + ". Repair its identity file; do not repeat the send.") }
            }
            return .object(result)
        }
        return await settle {
            defer { Self.release() }
            do {
                let (reply, title, observation) = try result.get()
                let identityError: String?
                do { try await remember(title); identityError = nil }
                catch { identityError = "The answer arrived, but its conversation identity could not be saved: " + error.localizedDescription
                    + ". Repair its identity file; do not repeat the send." }
                let usedRecipe = recipe
                await Task.detached {
                    store.recordProof(peerID: peerID, inbound: true, outbound: true)
                    store.recordRoundTrip(peerID: peerID, workspace: title, recipe: usedRecipe)
                }.value
                var answered: [String: JSONValue] = ["status": .string("answered"), "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                                "sent": .bool(true), "completed": .bool(true), "reply": .string(reply),
                                "conversation_id": .string(title), "continued": .bool(thread != nil), "untrusted_remote_data": .bool(true)]
                answered["reply_observation_receipt"] = observation
                if let identityError { answered["identity_persistence_error"] = .string(identityError) }
                if thread == nil { answered["detail"] = .string("Opened a new side chat in \(appName) for this conversation.") }
                return .object(answered)
            } catch {
                if let failure = error as? MacAccessibilityReader.NativeReadFailure {
                    if Self.pressedReturn || confirmed {
                        return await uncertain(failure.detail + " " + (confirmed
                            ? "The message was sent; its answer remains unconfirmed. Nothing was resent."
                            : "Return was posted; message submission is unconfirmed. Nothing was resent."))
                    }
                    return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                        "detail": .string(failure.detail + " Nothing was sent.")])
                }
                if confirmed {
                    if let blocker = error as? Blocker, blocker == .moved {
                        return await uncertain(blocker.detail(mac: mac, name, app: appName), ["reply_observation": .string("failed"), "terminal": .bool(true)])
                    }
                    return await uncertain("""
                        \(appName)'s answer couldn't be read. The message was sent; check \(name)'s chat in \(appName). It won't be resent \
                        automatically.
                        """)
                }
                if let covered = error as? MacScreenLock.Covered {
                    if Self.pressedReturn { return await uncertain(covered.detail + " Return was posted; submission is unconfirmed. Nothing was resent.") }
                    if covered.code == "human_takeover", !Self.pressedReturn, !stopped { return await heldForMac(covered.detail) }
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
                    return await uncertain(report.detail, report.fields)
                }
                if let blocker = error as? Blocker {
                    if blocker == .heldOff, Self.pressedReturn {
                        return await uncertain("""
                            You were typing or switched windows, so \(name) stopped using \(appName). Return had already been posted; message \
                            submission is unconfirmed. Check \(name)'s chat in \(appName) before trying again; nothing was resent.
                            """)
                    }
                    if [.moved, .submission].contains(blocker) || Self.pressedReturn { return await uncertain(blocker.detail(mac: mac, name,
                        app: appName)) }
                    if blocker == .heldOff, !stopped {
                        let detail = withAgentMacDriver(mac, driver: sendDriver) { mac in MacAttentionSessionStore.sendRefusal(context: mac) }
                        return await heldForMac(detail)
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
                   !Self.pressedReturn, !stopped {
                    let detail = withAgentMacDriver(mac, driver: sendDriver) { mac in MacAttentionSessionStore.sendRefusal(context: mac) }
                    return await heldForMac(detail)
                }
                // Before Return, report the specific failure without implying submission.
                guard Self.pressedReturn else {
                    return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                                    "detail": .string("\(appName) couldn't be driven: \(error.localizedDescription). Nothing was sent.")])
                }
                return await uncertain(Blocker.submission.detail(mac: mac, name, app: appName))
            }
        }
    }

    // MARK: - One exchange

    private static var permissionFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["reason": .string("accessibility_permission_missing")]
        fields["remedy"] = SystemPermissionPreflight.remedy("accessibility")
        return fields
    }

    @concurrent func send(turn: NativeAgentCore.Turn, mac: MacOperationContext, _ message: String, thread: String?, first: String?,
        didSubmit: () -> Void) async throws -> (String, String, JSONValue) {
        try await unlocked(turn: turn, mac: mac)
        guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
        try await showWindow(turn: turn, mac: mac)
        let opened = try await openThread(turn: turn, mac: mac, thread, first: first)
        let reopen = opened.reopen
        var chat = opened.chat
        Self.lastChat = chat
        let key = flat(message)
        func sent() throws -> Int { try turns(mac: mac, walk(mac: mac, window(mac: mac))).filter { $0.user && flat($0.text) == key }.count }
        func ownsChat() throws -> Bool {
            let all = try turns(mac: mac, walk(mac: mac, window(mac: mac)))
            return thread == nil ? all.isEmpty : opensWith(all, first)
        }
        var rows: Int?
        let before = try await typeAndSubmit(turn: turn, mac: mac, message, chat: chat ?? untitled, reopen: reopen, ownsChat: ownsChat,
                                             count: { rows = try logRows(mac: mac, walk(mac: mac, window(mac: mac))).count; return try sent() })
        // An additional exact outgoing row confirms submission, not answer delivery.
        do {
            try await until(mac: mac) { try sent() > before }
        } catch let failure as MacAccessibilityReader.NativeReadFailure { throw failure }
        catch { throw Unconfirmed(rows: rows) }
        func mine(_ turns: [ChatRow]) -> Int? {
            turns.indices.filter { turns[$0].user && flat(turns[$0].text) == key }.dropFirst(before).first
        }
        didSubmit()
        let events = try await DesktopRouteObservation(bundleID: bundleID, context: mac)
        defer { events.stop() }
        if let live { await AgentConversationLiveHub.shared.note(live, "Waiting on \(appName)'s reply; cancel to stop waiting.") }
        repeat {
            try Task.checkCancellation()
            let snapshot = try await passiveRead(mac: mac)
            let all = snapshot.turns
            let title = snapshot.title
            if let current = chat, title != current {
                // Accept a renamed chat only if its exact first message proves identity.
                guard let title, opensWith(all, first) else { throw Blocker.moved }
                chat = title
            }
            if let index = mine(all) {
                Self.lastChat = title ?? Self.lastChat
                let after = all[(index + 1)...].prefix { !$0.user }
                let reply = after.map(\.text).joined(separator: "\n\n")
                Self.lastReply = reply
                guard all[(index + 1)...].allSatisfy({ !$0.user }) else { throw Blocker.moved }
                if !reply.isEmpty, !snapshot.generating {
                    return (reply, try await settledTitle(mac: mac, first: first),
                        await events.receipt(readBy: "accessibility", replyComplete: true))
                }
            }
            try await events.next()
        } while true
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

    /// Select or create only the owned chat; renames require the exact opening turn and reopen requires a foreground list click.
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
            try await until(mac: mac) { try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == untitled && turns(
                mac: mac, walk(mac: mac, window(mac: mac))).isEmpty }
            return (false, nil)
        }
    }

    @concurrent func showSideChats(turn: NativeAgentCore.Turn, mac: MacOperationContext) async throws {
        if let back = try buttons(mac: mac, { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == ui.backToMain }).first {
            guard try SystemMacAXActSource().performNative(back, action: kAXPressAction, turn: turn,
                context: mac).get() == .success else { throw Blocker.thread }
            try await until(mac: mac) { try headerTitle(mac: mac, walk(mac: mac, window(mac: mac))) == nil }
        }
        if try sideChatsPanel(mac: mac, walk(mac: mac, window(mac: mac))) == nil {
            guard let open = try buttons(mac: mac, { MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac).hasPrefix(ui.chatsButton) })
                .first else { throw Mismatch(
                key: "chatsButton", wanted: ui.chatsButton) }
            guard try SystemMacAXActSource().performNative(open, action: kAXPressAction, turn: turn,
                context: mac).get() == .success else { throw Blocker.window }
            try await until(mac: mac) { try sideChatsPanel(mac: mac, walk(mac: mac,
                window(mac: mac))) != nil }
        }
    }

    /// Restore the prior front app after input only while foreground ownership remains ours.
    @concurrent func typeAndSubmit(turn: NativeAgentCore.Turn, mac: MacOperationContext, _ message: String, chat: String, reopen: Bool,
        ownsChat: () throws -> Bool, count: () throws -> Int) async throws -> Int {
        _ = try composer(mac: mac, walk(mac: mac, window(mac: mac)))
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        guard !PersonOnlyWindows.keyboardHeldByPerson else { throw Blocker.heldOff }
        try await unlocked(turn: turn, mac: mac)
        let previous = NSWorkspace.shared.frontmostApplication
        let source = SystemMacAXActSource()
        let activation = await source.activate(pid: app.processIdentifier, context: mac)
        try Task.checkCancellation()
        guard mac.driver?.allowsEmission(context: mac) == true else {
            throw Blocker.heldOff
        }
        guard activation != .invalidTarget else { throw Blocker.offline }
        guard activation == .performed else {
            throw GrokRoutineAccessibility.Failure(detail: source.raiseDiagnostic ?? "\(appName) could not be activated. Bring it forward before continuing.")
        }
        let driver = mac.driver?.settlementBinding()
        let before: Int
        do { before = try await typeInFront(mac: mac, message, chat: chat, reopen: reopen, ownsChat: ownsChat, count: count, app: app) }
        catch {
            await settle {
                await withAgentMacDriver(mac, driver: driver) { mac in await restore(mac: mac, previous, from: app) }
            }
            throw error
        }
        await settle {
            await withAgentMacDriver(mac, driver: driver) { mac in await restore(mac: mac, previous, from: app) }
        }
        return before
    }

    private func restore(mac: MacOperationContext, _ previous: NSRunningApplication?, from app: NSRunningApplication) async {
        guard let previous, !previous.isTerminated, previous.processIdentifier != app.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        let source = SystemMacAXActSource()
        let outcome = await source.activate(pid: previous.processIdentifier, context: mac)
        if outcome != .performed {
            nativeLog("Desktop foreground restoration stopped: %@", source.raiseDiagnostic ?? outcome.rawValue)
        }
    }

    @concurrent private func typeInFront(mac: MacOperationContext, _ message: String, chat: String, reopen: Bool, ownsChat: () throws -> Bool,
        count: () throws -> Int, app: NSRunningApplication) async throws -> Int {
        func front() -> Bool {
            mac.driver?.allowsEmission(context: mac) == true
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }
        let sink = CGEventSink()
        func click(_ node: AXUIElement) async throws {
            let frame = try frame(mac: mac, of: node)
            let point = CGPoint(x: frame.minX + frame.width * 0.35, y: frame.midY)
            guard let events = sink.clickEvents(at: point) else { throw Blocker.typing }
            for event in events {
                guard front(), !PersonOnlyWindows.keyboardHeldByPerson else { throw Blocker.heldOff }
                try await sink.postNative(event, context: mac)
            }
        }
        try await until(mac: mac) { front() }
        if reopen {
            // Only ever the agent's own entry in the side-chat list; never the main chat.
            let entries = try sideChatEntries(mac: mac, named: chat)
            guard entries.count == 1, let entry = entries.first else { throw Blocker.thread }
            try await click(entry)
            // Wait for the selected log to load before measuring its baseline.
            try await until(mac: mac) { try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat && !turns(mac: mac,
                walk(mac: mac, window(mac: mac))).isEmpty }
        }
        // Activation may change the chat; recheck the opening message before input.
        guard try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat, try ownsChat() else { throw Blocker.thread }
        // Measure the baseline in the verified loaded chat immediately before input.
        let before = try count()
        // Read the exact composer before any input can overwrite a draft.
        let inputBox = try composerInput(mac: mac, walk(mac: mac, window(mac: mac)))
        guard try AX.composerValue(mac: mac, inputBox).isEmpty else {
            throw AX.Failure(detail: "The selected chat already holds a draft, left untouched. Finish or clear it before sending.")
        }
        // Use HID input, checking frontmost ownership before each event.
        func keys(_ code: CGKeyCode, flags: CGEventFlags = []) async throws {
            guard let events = sink.keyEvents(code, flags: flags) else { throw Blocker.typing }
            for event in events {
                // Never emit keys while the person is typing in another window.
                guard front(), !PersonOnlyWindows.keyboardHeldByPerson else { throw Blocker.heldOff }
                try await sink.postNative(event, context: mac)
                // Only an emitted Return can make submission uncertain. A safety refusal before key-down proves nothing was sent.
                if code == 36 { Self.pressedReturn = true }
            }
        }
        try await click(inputBox)
        try await until(mac: mac) {
            guard front(), try ownsChat() else { throw Blocker.heldOff }
            return try MacAXAttributeRead.checkedBool(inputBox, kAXFocusedAttribute, context: mac) == true
        }
        try await DesktopClipboard.shared.acquire()
        defer { DesktopClipboard.shared.release() }
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        let saved = try AX.copyPasteboard(pasteboard)
        pasteboard.clearContents()
        let wrote = pasteboard.setString(message, forType: .string)
        let ours = pasteboard.changeCount
        defer {
            // Only put the person's clipboard back if nothing new was copied meanwhile.
            if pasteboard.changeCount == ours {
                pasteboard.clearContents()
                if !saved.isEmpty { _ = AX.restorePasteboard(saved, to: pasteboard) }
            }
        }
        guard wrote else { throw Blocker.typing }
        // Recheck ownership before paste and Return.
        guard try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat, try ownsChat() else { throw Blocker.thread }
        let currentInput = try composerInput(mac: mac, walk(mac: mac, window(mac: mac)))
        guard CFEqual(inputBox, currentInput), try AX.composerValue(mac: mac, currentInput).isEmpty else {
            throw AX.Failure(detail: "The selected composer changed or holds a draft, left untouched. Nothing was pasted.")
        }
        try await keys(9, flags: .maskCommand)
        try await until(mac: mac) {
            guard front(), try ownsChat(), try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat else { throw Blocker.heldOff }
            guard CFEqual(currentInput, try composerInput(mac: mac, walk(mac: mac, window(mac: mac)))) else { throw Blocker.thread }
            return flat(try AX.composerValue(mac: mac, currentInput)) == flat(message)
        }
        guard try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == chat, try ownsChat() else { throw Blocker.thread }
        guard CFEqual(currentInput, try composerInput(mac: mac, walk(mac: mac, window(mac: mac)))),
              flat(try AX.composerValue(mac: mac, currentInput)) == flat(message) else {
            throw AX.Failure(detail: "The exact composer did not confirm the full message. Submission stopped; inspect the retained draft before another send.")
        }
        try await keys(36)
        return before
    }

    /// A named, owned chat supplies the persisted identity.
    func settledTitle(mac: MacOperationContext, first: String?) async throws -> String {
        let events = try await DesktopRouteObservation(bundleID: bundleID, context: mac)
        defer { events.stop() }
        while true {
            let snapshot = try await passiveRead(mac: mac)
            guard opensWith(snapshot.turns, first) else { throw Blocker.moved }
            if let title = snapshot.title, !title.isEmpty, title != untitled { return title }
            try await events.next()
        }
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
        return read.turns.filter { $0.user && route.flat($0.text) == route.flat(message) }.count
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
            let answering = try composer(mac: mac, tree).title.hasSuffix(" " + ui.stop) || tree.contains { button in
                MacAXAttributeRead.text(button, kAXRoleAttribute, context: mac) == kAXButtonRole
                    && [kAXTitleAttribute, kAXDescriptionAttribute].contains { MacAXAttributeRead.text(button, $0, context: mac).hasPrefix(ui.stop) }
            }
            let read = try Read(turns: turns(mac: mac, tree), title: title, generating: answering)
            guard try openTitle(mac: mac, walk(mac: mac, window(mac: mac))) == title else { throw Blocker.moved }
            return read
        }
    }

    /// Keys and paste on a locked Mac would go to the lock screen's password field. The screensaver sets the same flag, so it is woken first.
    func unlocked(turn: NativeAgentCore.Turn, mac: MacOperationContext) async throws {
        let session = try await MacScreenLock.wakeIfCovered(turn: turn, context: mac).after
        guard session.sessionReadable, session.onConsole, !session.screenIsLocked else { throw Blocker.locked }
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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try await until(mac: mac) { try windows(mac: mac).contains(where: { try hasLog(mac: mac, $0) }) }
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
        if boxes.isEmpty { throw Mismatch(key: "composerCore", wanted: ui.composerCore) }
        guard boxes.count == 1, let box = boxes.first else { throw Blocker.window }
        return (MacAXAttributeRead.text(box, kAXTitleAttribute, context: mac), box)
    }

    nonisolated func composerInput(mac: MacOperationContext, _ tree: [AXUIElement]) throws -> AXUIElement {
        let group = try composer(mac: mac, tree).node
        let boxes = try MacAccessibilityReader.elements(in: group, searching: "the selected chat's composer", context: mac).filter {
            [kAXTextAreaRole, kAXTextFieldRole].contains(MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac))
                && MacAXAttributeRead.text($0, kAXSubroleAttribute, context: mac) != kAXSearchFieldSubrole
        }
        guard boxes.count == 1, let box = boxes.first else {
            throw AX.Failure(detail: "The exact composer's readable text field could not be identified. Its draft was left untouched; nothing was typed.")
        }
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
                let matches = labelled.contains(node.path) || [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
                    entryTitle(MacAXAttributeRead.text(element, $0, context: mac)) == title
                }
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
            if let first = kids.first, MacAXAttributeRead.text(first, kAXValueAttribute, context: mac) == ui.userLabel {
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
        return flat(opener.text) == flat(first)
    }

    func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Read the condition after registration, then after its source changes. Silence remains a cancellable wait.
    @concurrent func until(mac: MacOperationContext, _ ready: () throws -> Bool) async throws {
        let events = try await DesktopRouteObservation(bundleID: bundleID, context: mac)
        defer { events.stop() }
        var waitingPublished = false
        repeat {
            try Task.checkCancellation()
            if try ready() { return }
            if let live, !waitingPublished {
                await AgentConversationLiveHub.shared.note(live, "Waiting on \(appName)'s desktop controls; cancel to stop waiting.")
                waitingPublished = true
            }
            try await events.next()
        } while true
    }

}
