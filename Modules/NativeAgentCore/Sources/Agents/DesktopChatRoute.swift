import AppKit
import ApplicationServices
import AgentConversations
import MacControl
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `DesktopChatRoute.swift` | Recipe-bound conversation selection, send confirmation and learned reads; deepest exact-title entries come from one bounded postorder snapshot; MacControl owns window/subtree reads, attributes, activation, AX mutations and input construction/emission; control searches exclude the message log, and incomplete reads remain read failures through waits and delivery receipts; shared desktop observation preserves reply quiet, title and setup deadlines, including a final condition read; answered receipts name the read method and wake; uncertain delivery without automatic resend; sends and late readers preserve produced text and release their resources through `settle` |

/// Recipe-bound desktop chat (`agents/recipes/<host>.json`, `desktopChat`):
/// select the agent's side chat, submit input, and read the answer from that chat.
@MainActor public struct DesktopChatRoute {
    enum Blocker: String, Error {
        case offline = "{app} isn't open. Open {app} and show its chat before sending. Nothing was sent."
        case permission = "Allow NativeAgent Accessibility access so it can use {app}'s window. Nothing was sent."
        case window = "{app} isn't showing its chat. Nothing was sent."
        case thread = "Agent's own chat in {app} couldn't be found or opened, so nothing was sent."
        case missing = "Agent's own chat in {app} is gone, so nothing was sent; the next message opens a new side chat there."
        case typing = "{app}'s message box didn't take the text. Nothing was sent; check {app}'s message box."
        case submission = "{app} didn't confirm the message. Check Agent's chat in {app}; it won't be resent automatically."
        case moved = "{app} left Agent's chat before answering. The message was sent; its answer will be in her chat in {app}."
        case timeout = "{app} didn't finish answering within two minutes. The message was sent; its answer will be in her chat in {app}."
        /// Said instead of `moved`/`timeout` while her chat is still read (lateAnswer).
        static let late = "The message was sent; {app} hasn't finished answering. Agent's chat in {app} is still read, and the answer lands on this exchange and reaches her when it comes. Don't resend."
        case locked = "Mac is locked, nothing was sent."
        /// The texts say "Agent"; the agent here may be named otherwise. {app} is the app's name from its recipe.
        func detail(_ name: String, app: String) -> String { Self.named(rawValue, name, app: app) }
        static func named(_ text: String, _ name: String, app: String) -> String {
            text.replacingOccurrences(of: "Agent", with: name).replacingOccurrences(of: "{app}", with: app)
        }
    }
    /// A label the recipe names (`key`) that the window doesn't have, found
    /// before any input, so nothing was sent.
    struct Mismatch: Error { let key: String, wanted: String }
    /// Return was pressed and nothing of hers showed; `rows` is her chat's
    /// log length just before input.
    struct Unconfirmed: Error { let rows: Int? }
    /// The labels a send finds before any input, by their recipe key.
    static let selectors: [String: WritableKeyPath<AgentHostRow.DesktopChat, String>] = [
        "log": \.log, "chatsButton": \.chatsButton, "chatsPanel": \.chatsPanel, "composerCore": \.composerCore, "newChat": \.newChat]
    /// The app driven, from its recipe as this send found it (its proof
    /// records that one): its name, its bundle and every label its window
    /// exposes. Anything unmatched fails with a plain blocker, never a guess;
    /// when the app changes a label, its recipe changes.
    let recipe: AgentRecipeStore.Recipe
    let bundleID: String
    let ui: AgentHostRow.DesktopChat
    var appName: String { recipe.host.displayName }
    var untitled: String { ui.newChat }
    private static var busy = false {
        didSet { if !busy { let waiting = idleWaiters.values; idleWaiters = [:]; waiting.forEach { $0.resume() } } }
    }
    private static var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private static func waitForIdle() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !busy || Task.isCancelled { continuation.resume() }
                else { idleWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in idleWaiters.removeValue(forKey: id)?.resume() }
        }
        try Task.checkCancellation()
    }
    /// The chat her message went into, for an uncertain result to carry.
    private static var lastChat: String?
    /// Which of the chat's same-text messages of hers this send was (0 = first).
    private static var lastOccurrence: Int?
    private static var lastReply = ""
    /// Return was pressed for this send: from here an error leaves its outcome unknown.
    private static var pressedReturn = false
    private typealias AX = GrokRoutineAccessibility

    public static func perform(plan: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"], case .string(let text)? = plan["text"] else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string("Missing message.")])
        }
        guard case .string(let bundle)? = plan["app_bundle_id"],
              let recipe = AgentRecipeStore.recipes.first(where: { $0.host.route == .desktopChat && $0.host.bundleIDs.contains(bundle) }),
              let ui = recipe.host.desktopChat else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string("No recipe says how to drive this app's chat window (route desktop-chat with desktopChat labels). Read it with agent.recipe and fix it with agent.recipe_write. Nothing was sent.")])
        }
        let route = Self(recipe: recipe, bundleID: bundle, ui: ui)
        func execute() async -> JSONValue {
            if plan["dry_run"] == .bool(true) { return await route.dryRun(peerID: peerID, dataRoot: dataRoot) }
            return await route.perform(text, peerID: peerID, plan: plan, dataRoot: dataRoot)
        }
        if MacDriverContext.binding != nil { return await execute() }
        let binding = await MacAttentionSessionStore.shared.bindDriver()
        return await withTaskCancellationHandler {
            await MacDriverContext.$binding.withValue(binding) { await execute() }
        } onCancel: { binding.cancel() }
    }

    /// A repair's dry run (`AgentContactHealth.repair`): the controls a send
    /// finds before any input, found the same way, with no typing and the app
    /// never brought forward. A label that misses is tried with the recipe's
    /// alternates for it; one that matches is written to the recipe.
    private func dryRun(peerID: String, dataRoot: URL) async -> JSONValue {
        let name = AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent
        func failed(_ detail: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
            .object(fields.merging(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false),
                "agent": .string("peer:" + peerID), "transport": .string("desktopChat"), "detail": .string(detail)]) { $1 })
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return failed(Blocker.offline.detail(name, app: appName)) }
        guard !Self.busy else { return failed("\(appName) is still answering the previous message. Nothing was checked.") }
        guard SystemMacAXElementSource().isTrusted() else { return failed(Blocker.permission.detail(name, app: appName)) }
        Self.busy = true
        defer { Self.busy = false }
        var ui = self.ui, tried: Set<String> = []
        while true {
            do {
                try await Self(recipe: recipe, bundleID: bundleID, ui: ui).controls()
                break
            } catch let miss as Mismatch {
                let path = Self.selectors[miss.key] ?? \.log
                guard let next = ui.alternates?[miss.key]?.first(where: { tried.insert(miss.key + "=" + $0).inserted && $0 != ui[keyPath: path] }) else {
                    // Said with the recipe's own label, not the last alternate tried.
                    let report = said(Mismatch(key: miss.key, wanted: self.ui[keyPath: path]))
                    return failed(report.detail, report.fields)
                }
                ui[keyPath: path] = next
            } catch let blocker as Blocker {
                return failed(blocker.detail(name, app: appName))
            } catch {
                return failed("\(appName)'s window couldn't be read: \(error.localizedDescription). Nothing was sent.")
            }
        }
        let version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let changed = Self.selectors.filter { self.ui[keyPath: $0.value] != ui[keyPath: $0.value] }.sorted { $0.key < $1.key }
        var host = recipe.host
        host.desktopChat = ui
        // A finding that cannot be written proves nothing, and no retry runs on it.
        var written: AgentRecipeStore.Recipe?
        if !changed.isEmpty {
            do { written = try AgentRecipeStore.learn(recipe, host: host) }
            catch { return failed("\(appName)'s window matched its recipe's alternates, but the recipe could not take them: \(error). Nothing was proven.") }
        }
        let now = written ?? recipe
        var result: [String: JSONValue] = ["status": .string(written == nil ? "passed" : "repaired"), "dry_run": .bool(true), "sent": .bool(false),
            "agent": .string("peer:" + peerID), "transport": .string("desktopChat"), "recipe_version": .int(Int64(now.recipeVersion)),
            "checked": .array(Self.selectors.keys.sorted().map(JSONValue.string)),
            "detail": .string("\(appName)'s window has every control a send uses; nothing was typed.")]
        if let written {
            result["healed"] = .string(appName + (version.map { " " + $0 } ?? "") + ": " + changed.map {
                "\u{201C}\(self.ui[keyPath: $0.value])\u{201D} is now \u{201C}\(ui[keyPath: $0.value])\u{201D}" }.joined(separator: "; ")
                + " — recipe updated to v\(written.recipeVersion)")
        }
        return .object(result)
    }

    /// The send's controls before any input: the log (`showWindow`), her chat
    /// list (`showSideChats`), the composer and the new-chat control.
    func controls() async throws {
        try await showWindow()
        try await showSideChats()
        _ = try composer(walk(window()))
        guard try !buttons({ MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.newChat }).isEmpty else { throw Mismatch(key: "newChat", wanted: ui.newChat) }
    }

    /// Up to five labels sharing the most words with `wanted`: the window's
    /// titles and descriptions, or `among` when given.
    func nearest(_ wanted: String, among: [String]? = nil) -> [String] {
        func words(_ text: String) -> Set<Substring> { Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }) }
        let goal = words(wanted)
        let seen = Set((among ?? ((try? windows()) ?? []).flatMap { (try? walk($0)) ?? [] }.flatMap { node in
            [kAXTitleAttribute, kAXDescriptionAttribute].map { MacAXAttributeRead.text(node, $0) } })
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }.filter { !$0.isEmpty })
        func shared(_ label: String) -> Int { goal.intersection(words(label)).count }
        return Array(seen.sorted { (shared($0), $1) > (shared($1), $0) }.prefix(5))
    }

    static func quoted(_ labels: [String]) -> String { labels.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") }

    /// The miss as a receipt says it, with the window's nearest labels.
    func said(_ miss: Mismatch, then: String = "Nothing was sent.") -> (detail: String, fields: [String: JSONValue]) {
        let labels = nearest(miss.wanted)
        return ("\(appName)'s window has no \u{201C}\(miss.wanted)\u{201D} (its recipe's \(miss.key))"
                    + (labels.isEmpty ? "" : "; nearest: " + Self.quoted(labels)) + ". " + then,
                ["reason": .string("recipe_mismatch"), "selector": .string(miss.key), "labels": .array(labels.map(JSONValue.string))])
    }

    /// After Return nothing of hers showed: her chat's log, read once more,
    /// says whether its rows changed shape (rows came that don't read as hers)
    /// or nothing came. The message may have gone out either way, so it is
    /// never retried; the receipt (and the harness item `heal` files) says
    /// what the log holds.
    func unconfirmed(_ before: Int?, name: String) -> (detail: String, fields: [String: JSONValue]) {
        let unsure = "The message may have gone out; check \(name)'s chat in \(appName) and don't resend it."
        let rows: [AXUIElement]
        do { rows = try logRows(walk(window())) }
        catch { return (error.localizedDescription + " " + unsure, ["reason": .string("accessibility_read_incomplete")]) }
        guard let before, rows.count > before else {
            // Nothing came: today's words, and the window's labels for the fix.
            var fields = said(Mismatch(key: "userPrefix", wanted: ui.userPrefix)).fields
            fields["reason"] = .string("not_confirmed")
            return (Blocker.submission.detail(name, app: appName), fields)
        }
        let added = Array(rows[before...])
        let row = added.first.map { node in
            let own = MacAXAttributeRead.text(node, kAXTitleAttribute) + MacAXAttributeRead.text(node, kAXDescriptionAttribute)
            return String((own.isEmpty ? ((try? texts(node)) ?? []).prefix(2).joined(separator: " ") : own).prefix(80))
        } ?? ""
        let addedTree: [AXUIElement]
        do { addedTree = try added.flatMap { try MacAccessibilityReader.elements(in: $0, searching: "the outgoing desktop message") } }
        catch { return (error.localizedDescription + " " + unsure, ["reason": .string("accessibility_read_incomplete")]) }
        let labels = nearest(ui.userPrefix, among: addedTree.flatMap { node in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { MacAXAttributeRead.text(node, $0) } })
        return ("\(appName)'s chat gained \(added.count) row\(added.count == 1 ? "" : "s") after the message that \(added.count == 1 ? "doesn't" : "don't") read as hers "
                    + "(its recipe's userPrefix \u{201C}\(ui.userPrefix)\u{201D}): \u{201C}\(row)\u{201D}"
                    + (labels.isEmpty ? "" : "; nearest: " + Self.quoted(labels)) + ". " + unsure,
                ["reason": .string("recipe_mismatch"), "selector": .string("userPrefix"), "row": .string(row), "labels": .array(labels.map(JSONValue.string))])
    }

    private func perform(_ text: String, peerID: String, plan: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        let name = AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent
        guard !Self.busy else {
            return .object(["status": .string("busy"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string("\(appName) is still answering the previous message. Nothing was sent.")])
        }
        Self.busy = true
        var thread: String?
        if case .string(let saved)? = plan["conversation_id"] { thread = saved }
        let store = AgentPeerStore(dataRoot: dataRoot)
        Self.lastChat = nil; Self.lastOccurrence = nil; Self.lastReply = ""; Self.pressedReturn = false
        // Her first message names her, so the chat is recognisably hers in the app.
        let message = thread == nil && !text.hasPrefix(name) ? name + " here — " + text : text
        // The exact first message of each of her chats, by title: a renamed chat
        // is hers only if it opens with exactly that (never just her name).
        let first = thread.map { Self.firsts(peerID: peerID, dataRoot: dataRoot)[$0] } ?? message
        func remember(_ title: String?) {
            Self.remember(title, replacing: thread, first: first, peerID: peerID, dataRoot: dataRoot)
        }
        var submissionConfirmed = false
        // An uncertain send keeps its chat, so the thread resumes instead of being orphaned.
        func uncertain(_ detail: String, _ fields: [String: JSONValue] = [:]) async -> JSONValue {
            var result = fields.merging(["status": .string("outcome_unknown"), "completed": .bool(false), "detail": .string(detail)]) { $1 }
            if !Self.lastReply.isEmpty { result["partial_reply"] = .string(Self.lastReply); result["untrusted_remote_data"] = .bool(true) }
            if submissionConfirmed { result["sent"] = .bool(true) }
            let snapshot = try? await passiveRead()
            let matchingNewChat = thread == nil && snapshot.map({ opensWith($0.turns, first) }) == true ? snapshot?.title : nil
            let chat = matchingNewChat ?? Self.lastChat
            if let chat, chat != untitled { result["conversation_id"] = .string(chat); remember(chat) }
            return .object(result)
        }
        let result: Result<(String, String, JSONValue), Error>
        do { result = .success(try await send(message, thread: thread, first: first) { submissionConfirmed = true }) }
        catch { result = .failure(error) }
        let stopped = Task.isCancelled
        let live = AgentConversationLiveContext.target
        return await settle { @MainActor in
            defer { Self.busy = false }
            do {
                let (reply, title, observation) = try result.get()
                remember(title)
                store.recordProof(peerID: peerID, inbound: true, outbound: true)
                store.recordRoundTrip(peerID: peerID, workspace: title, recipe: recipe)
                var answered: [String: JSONValue] = ["status": .string("answered"), "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                                "sent": .bool(true), "completed": .bool(true), "reply": .string(reply),
                                "conversation_id": .string(title), "continued": .bool(thread != nil), "untrusted_remote_data": .bool(true)]
                answered["reply_observation_receipt"] = observation
                if thread == nil { answered["detail"] = .string("Opened a new side chat in \(appName) for this conversation.") }
                return .object(answered)
            } catch {
                if let failure = error as? MacAccessibilityReader.NativeReadFailure {
                    if Self.pressedReturn || submissionConfirmed {
                        return await uncertain(failure.detail + " " + (submissionConfirmed
                            ? "The message was sent; its answer remains unconfirmed. Nothing was resent."
                            : "Return was posted; message submission is unconfirmed. Nothing was resent."))
                    }
                    return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                        "detail": .string(failure.detail + " Nothing was sent.")])
                }
                if submissionConfirmed {
                    if !stopped, let blocker = error as? Blocker, [.moved, .timeout].contains(blocker) {
                        if let live, let row = live.recordID, let operation = live.operationID,
                           let occurrence = Self.lastOccurrence, let events = try? MacAppSourceEvents(bundleID: bundleID) {
                            let receipt = await uncertain(Blocker.named(Blocker.late, name, app: appName), ["reply_observation": .string("running")])
                            let id = UUID()
                            let task = Task {
                                await lateAnswer(message, occurrence: occurrence, first: first, peerID: peerID,
                                                 row: row, operation: operation, events: events, receipt: receipt, dataRoot: dataRoot)
                                await settle { AgentConversationWatches.finish(id) }
                            }
                            AgentConversationWatches.retain(id, row: row, operation: operation, task: task)
                            return receipt
                        }
                        return await uncertain(blocker.detail(name, app: appName))
                    }
                    return await uncertain("\(appName)'s answer couldn't be read. The message was sent; check \(name)'s chat in \(appName). It won't be resent automatically.")
                }
                if let covered = error as? MacScreenLock.Covered {
                    return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string(covered.detail + " Nothing was sent.")])
                }
                // Its recipe and its window disagree: a repair acts on it (`AgentContactHealth.heal`).
                if let miss = error as? Mismatch {
                    let report = said(miss)
                    return .object(report.fields.merging(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                        "agent": .string("peer:" + peerID), "transport": .string("desktopChat"), "detail": .string(report.detail)]) { $1 })
                }
                if let unconfirmed = error as? Unconfirmed {
                    let report = self.unconfirmed(unconfirmed.rows, name: name)
                    return await uncertain(report.detail, report.fields)
                }
                if let blocker = error as? Blocker {
                    if [.moved, .timeout, .submission].contains(blocker) || Self.pressedReturn { return await uncertain(blocker.detail(name, app: appName)) }
                    // Describe what the app shows when its chat is unavailable.
                    let shown = blocker == .window ? try? await MacAccessibilityReader.read { showing() } : nil
                    let detail = shown.map { "\(appName) isn't showing its chat; it shows \($0). Nothing was sent." }
                    var result: [String: JSONValue] = ["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string(detail ?? blocker.detail(name, app: appName))]
                    // Her saved chat is gone: the conversation drops it, so the next send opens a new one.
                    if blocker == .missing { result["conversation_id"] = .null }
                    return .object(result)
                }
                // Before Return nothing reached it: not sent, in the error's own words.
                guard Self.pressedReturn else {
                    return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                                    "detail": .string("\(appName) couldn't be driven: \(error.localizedDescription). Nothing was sent.")])
                }
                return await uncertain(Blocker.submission.detail(name, app: appName))
            }
        }
    }

    // MARK: - One exchange

    func send(_ message: String, thread: String?, first: String?, didSubmit: () -> Void) async throws -> (String, String, JSONValue) {
        try await unlocked()
        guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
        try await showWindow()
        var (reopen, chat) = try await openThread(thread, first: first)
        Self.lastChat = chat
        let key = flat(message)
        func sent() throws -> Int { try turns(walk(window())).filter { $0.user && flat($0.text) == key }.count }
        func ownsChat() throws -> Bool {
            let all = try turns(walk(window()))
            return thread == nil ? all.isEmpty : opensWith(all, first)
        }
        var rows: Int?
        let before = try await typeAndSubmit(message, chat: chat ?? untitled, reopen: reopen, ownsChat: ownsChat,
                                             count: { rows = try? logRows(walk(window())).count; return try sent() })
        // An additional exact outgoing row confirms submission, not answer delivery.
        do {
            try await until(seconds: 15) { try sent() > before }
        } catch let failure as MacAccessibilityReader.NativeReadFailure { throw failure }
        catch { throw Unconfirmed(rows: rows) }
        Self.lastOccurrence = before
        func mine(_ turns: [Turn]) -> Int? {
            turns.indices.filter { turns[$0].user && flat(turns[$0].text) == key }.dropFirst(before).first
        }
        didSubmit()
        let events = try DesktopRouteObservation(bundleID: bundleID)
        defer { events.stop() }
        var last = "", stableSince = Date()
        let deadline = Date().addingTimeInterval(120)
        repeat {
            try Task.checkCancellation()
            let snapshot = try await passiveRead()
            let all = snapshot.turns
            let title = snapshot.title
            if let current = chat, title != current {
                // The app renames chats a few minutes in: a new title is hers only if it opens with her exact first message.
                guard let title, opensWith(all, first) else { throw Blocker.moved }
                chat = title
            }
            var wake = deadline
            if let index = mine(all) {
                Self.lastChat = title ?? Self.lastChat
                let after = all[(index + 1)...].prefix { !$0.user }
                let reply = after.map(\.text).joined(separator: "\n\n")
                Self.lastReply = reply
                guard all[(index + 1)...].allSatisfy({ !$0.user }) else { throw Blocker.moved }
                if reply != last { last = reply; stableSince = Date() }
                if !reply.isEmpty, !snapshot.generating {
                    let quiet = stableSince.addingTimeInterval(3)
                    if Date() >= quiet { return (reply, try await settledTitle(chat, first: first), events.receipt(readBy: "accessibility")) }
                    wake = min(deadline, quiet)
                }
            }
            if Date() >= deadline { break }
            try await events.next(until: wake)
        } while true
        throw Blocker.timeout
    }

    /// Past the send's two minutes: the app's own accessibility notifications
    /// (values and children changing in its window) each trigger one read of
    /// her chat, never a clock. When the answer after her message is there and
    /// the app has stopped generating, it lands on its exchange. It ends when
    /// the app quits, the exchange is explicitly retired, NativeAgent shuts
    /// down, or a later message of hers follows unanswered.
    /// `occurrence`: which of her same-text messages in that chat this send was.
    func lateAnswer(_ message: String, occurrence: Int, first: String?, peerID: String, row: String, operation: String,
                    events: MacAppSourceEvents, receipt: JSONValue, dataRoot: URL) async {
        let key = flat(message)
        var fields: [String: JSONValue] = if case .object(let fields) = receipt { fields } else { [:] }
        var answer: String?
        do {
            for try await _ in events.stream {
                // Another send drives the app now: read once it is done, not never.
                while Self.busy { try await Self.waitForIdle() }
                try Task.checkCancellation()
                // Hold the same admission as sends across the worker suspension.
                Self.busy = true
                let snapshot: Read
                do { snapshot = try await passiveRead() }
                catch { Self.busy = false; throw error }
                Self.busy = false
                guard opensWith(snapshot.turns, first) else { continue }
                let all = snapshot.turns
                let mine = all.indices.filter { all[$0].user && flat(all[$0].text) == key }
                guard mine.count > occurrence else { continue }
                let index = mine[occurrence]
                let text = all[(index + 1)...].prefix { !$0.user }.map(\.text).joined(separator: "\n\n")
                if !text.isEmpty { fields["partial_reply"] = .string(text); fields["untrusted_remote_data"] = .bool(true) }
                if text.isEmpty, all[(index + 1)...].contains(where: \.user) { break }
                if Task.isCancelled { break }
                guard !text.isEmpty, !snapshot.generating else { continue }
                answer = text
                let title = snapshot.title
                fields["status"] = .string("answered"); fields["completed"] = .bool(true); fields["reply"] = .string(text)
                fields.removeValue(forKey: "partial_reply")
                if let title, title != untitled {
                    fields["conversation_id"] = .string(title)
                }
                break
            }
        } catch { fields["observation_error"] = .string(error.localizedDescription) }
        let stop = Task.isCancelled && answer == nil
            ? "Local reply observation stopped. The message was already sent to \(appName); any answer stays in that chat." : nil
        if answer == nil {
            fields["detail"] = .string(stop ?? "Local reply observation ended without a finished answer. The message was sent; any answer stays in that chat.")
        }
        fields["terminal"] = .bool(true)
        fields["reply_observation"] = .string(answer != nil ? "done" : stop != nil ? "stopped" : "failed")
        let saved = fields, produced = answer
        await settle { @MainActor in
            events.cancel()
            do {
                if case .string(let title)? = saved["conversation_id"] {
                    Self.remember(title, replacing: nil, first: first, peerID: peerID, dataRoot: dataRoot)
                }
                try AgentConversationStore(dataRoot: dataRoot).settleExchange(id: row, exchange: operation,
                    reply: produced, receipt: .object(saved), stopDetail: stop)
                if produced != nil { AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peerID, inbound: true, outbound: true) }
            } catch { nativeLog("Desktop reply result could not be saved: %@", error.localizedDescription) }
        }
    }

    /// The exact first message of each of her chats, by title: a renamed chat
    /// is hers only if it opens with exactly that (never just her name).
    static func firsts(peerID: String, dataRoot: URL) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: firstsFile(peerID: peerID, dataRoot: dataRoot)))) ?? [:]
    }

    private static func firstsFile(peerID: String, dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("agents/desktop-chat-" + peerID + ".json")
    }

    /// Saves `title` as hers; a rename drops the title it replaced.
    static func remember(_ title: String?, replacing thread: String?, first: String?, peerID: String, dataRoot: URL) {
        guard let title, let first else { return }
        let file = firstsFile(peerID: peerID, dataRoot: dataRoot)
        var saved = firsts(peerID: peerID, dataRoot: dataRoot)
        if let thread, thread != title { saved[thread] = nil }
        saved[title] = first
        try? SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(saved), to: file)
    }

    /// Select her saved side chat or create one; a rename must match her exact first user turn.
    /// `reopen` requires a foreground click on the chat's list entry before typing.
    func openThread(_ thread: String?, first: String?) async throws -> (reopen: Bool, chat: String?) {
        let open = try openTitle(walk(window()))
        if let thread, open == thread {
            guard try opensWith(turns(walk(window())), first) else { throw Blocker.thread }
            return (false, thread)
        }
        let openIsHers = try thread != nil && opensWith(turns(walk(window())), first)
        try await showSideChats()
        if let thread {
            let saved = try sideChatEntries(named: thread).count
            if saved == 1 { return (true, thread) }
            guard let open, open != untitled, openIsHers, try sideChatEntries(named: open).count == 1 else {
                // Gone only when the side-chat list is shown and has no entry by that title.
                if saved == 0, try sideChatsPanel(walk(window())) != nil { throw Blocker.missing }
                throw Blocker.thread
            }
            return (true, open)
        } else {
            let new = try buttons { MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.newChat }
            if new.isEmpty { throw Mismatch(key: "newChat", wanted: ui.newChat) }
            guard new.count == 1, try SystemMacAXActSource().performNative(new[0], action: kAXPressAction).get() == .success else { throw Blocker.thread }
            try await until(seconds: 5, else: Blocker.thread) { try openTitle(walk(window())) == untitled && turns(walk(window())).isEmpty }
            return (false, nil)
        }
    }

    func showSideChats() async throws {
        if let back = try buttons({ MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.backToMain }).first {
            guard try SystemMacAXActSource().performNative(back, action: kAXPressAction).get() == .success else { throw Blocker.thread }
            try await until(seconds: 5, else: Blocker.thread) { try headerTitle(walk(window())) == nil }
        }
        if try sideChatsPanel(walk(window())) == nil {
            guard let open = try buttons({ MacAXAttributeRead.text($0, kAXTitleAttribute).hasPrefix(ui.chatsButton) }).first else { throw Mismatch(key: "chatsButton", wanted: ui.chatsButton) }
            guard try SystemMacAXActSource().performNative(open, action: kAXPressAction).get() == .success else { throw Blocker.window }
            try await until(seconds: 5, else: Mismatch(key: "chatsPanel", wanted: ui.chatsPanel)) { try sideChatsPanel(walk(window())) != nil }
        }
    }

    /// Type with the app in front, then restore the prior front app.
    func typeAndSubmit(_ message: String, chat: String, reopen: Bool, ownsChat: () throws -> Bool, count: () throws -> Int) async throws -> Int {
        _ = try composer(walk(window()))
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        // Register before reading keyboard idle. Input renews the same two-second
        // quiet deadline, with the existing five-second overall limit.
        let input = try DesktopRouteObservation(bundleID: bundleID, accessibility: false, keyboard: true)
        let giveUp = Date().addingTimeInterval(5)
        do {
            defer { input.stop() }
            while Date() < giveUp {
                try Task.checkCancellation()
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                if idle >= 2 { break }
                try await input.next(until: min(giveUp, Date().addingTimeInterval(2 - idle)))
            }
        }
        try await unlocked()
        let previous = NSWorkspace.shared.frontmostApplication
        let source = SystemMacAXActSource()
        let activation = await source.activate(pid: app.processIdentifier)
        try Task.checkCancellation()
        guard MacDriverContext.binding?.allowsEmission == true else {
            throw GrokRoutineAccessibility.Failure(detail: "The Mac driver does not permit foreground input. Return control to NativeAgent before continuing; nothing was submitted.")
        }
        guard activation != .invalidTarget else { throw Blocker.offline }
        guard activation == .performed else {
            throw GrokRoutineAccessibility.Failure(detail: source.raiseDiagnostic ?? "\(appName) could not be activated. Bring it forward before continuing.")
        }
        let driver = MacDriverContext.binding?.settlementBinding()
        let before: Int
        do { before = try await typeInFront(message, chat: chat, reopen: reopen, ownsChat: ownsChat, count: count, app: app) }
        catch {
            await settle { @MainActor in
                await MacDriverContext.$binding.withValue(driver) { await restore(previous, from: app) }
            }
            throw error
        }
        await settle { @MainActor in
            await MacDriverContext.$binding.withValue(driver) { await restore(previous, from: app) }
        }
        return before
    }

    private func restore(_ previous: NSRunningApplication?, from app: NSRunningApplication) async {
        guard let previous, !previous.isTerminated, previous.processIdentifier != app.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        let source = SystemMacAXActSource()
        let outcome = await source.activate(pid: previous.processIdentifier)
        if outcome != .performed {
            nativeLog("Desktop foreground restoration stopped: %@", source.raiseDiagnostic ?? outcome.rawValue)
        }
    }

    private func typeInFront(_ message: String, chat: String, reopen: Bool, ownsChat: () throws -> Bool, count: () throws -> Int, app: NSRunningApplication) async throws -> Int {
        func front() -> Bool {
            MacDriverContext.binding?.allowsEmission == true
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }
        let sink = CGEventSink()
        func click(_ node: AXUIElement) throws {
            let frame = try frame(of: node)
            let point = CGPoint(x: frame.minX + frame.width * 0.35, y: frame.midY)
            guard let events = sink.clickEvents(at: point) else { throw Blocker.typing }
            for event in events {
                guard front() else { throw Blocker.window }
                PersonOnlyWindows.beforeAgentPointer(at: point)
                sink.postNative(event)
            }
        }
        try await until(seconds: 4, else: Blocker.window) { front() }
        if reopen {
            // Only ever her own entry in the side-chat list; never the main chat.
            let entries = try sideChatEntries(named: chat)
            guard entries.count == 1 else { throw Blocker.thread }
            try click(entries[0])
            // Wait for the selected chat's log to load before counting its rows.
            try await until(seconds: 5, else: Blocker.thread) { try openTitle(walk(window())) == chat && !turns(walk(window())).isEmpty }
        }
        // Activation can change the window: verify her opening message before any input.
        guard try openTitle(walk(window())) == chat, try ownsChat() else { throw Blocker.thread }
        // Count the loaded log in her verified chat immediately before input.
        let before = try count()
        // Draft text is unavailable; select-all and paste replace her side-chat composer.
        // Use HID input, checking frontmost ownership before each event.
        func keys(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
            guard let events = sink.keyEvents(code, flags: flags) else { throw Blocker.typing }
            for event in events {
                // Shotgun: never while the person types in their own window, which would take these keys.
                guard front(), !PersonOnlyWindows.keyboardHeldByPerson else { throw Blocker.typing }
                sink.postNative(event)
            }
        }
        try click(composer(walk(window())).node)
        try await Task.sleep(for: .milliseconds(300))
        let pasteboard = NSPasteboard.general
        let saved = try AX.copyPasteboard(pasteboard)
        pasteboard.clearContents()
        let wrote = pasteboard.setString(message, forType: .string)
        let ours = pasteboard.changeCount
        defer {
            // Only put the person's clipboard back if nothing new was copied meanwhile.
            if pasteboard.changeCount == ours {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        guard wrote else { throw Blocker.typing }
        // User can switch chats during the pauses: recheck hers before select-all and before Return.
        guard try openTitle(walk(window())) == chat, try ownsChat() else { throw Blocker.thread }
        try keys(0, flags: .maskCommand)   // select all in her box
        try keys(9, flags: .maskCommand)   // paste
        try await Task.sleep(for: .milliseconds(400))
        guard try openTitle(walk(window())) == chat, try ownsChat() else { throw Blocker.thread }
        Self.pressedReturn = true
        try keys(36)
        try await Task.sleep(for: .milliseconds(300))
        return before
    }

    /// Wait briefly for a new chat's name; return its current title on every exchange.
    func settledTitle(_ thread: String?, first: String?) async throws -> String {
        let events = thread == nil ? try DesktopRouteObservation(bundleID: bundleID) : nil
        defer { events?.stop() }
        let deadline = Date().addingTimeInterval(thread == nil ? 8 : 0)
        while true {
            let snapshot = try await passiveRead()
            guard opensWith(snapshot.turns, first) else { throw Blocker.moved }
            if thread != nil || (snapshot.title ?? untitled) != untitled || Date() >= deadline {
                return snapshot.title ?? thread ?? untitled
            }
            try await events?.next(until: deadline)
        }
    }

    // MARK: - Reading the window

    /// Send-only couriers share this recipe's native outgoing-row reader.
    /// Composer values never enter `turns`; a missing recipe or changed chat
    /// supplies no delivery evidence. Couriers may still submit without a
    /// reader, leaving delivery unconfirmed.
    static func outgoingOccurrences(_ message: String, bundle: String, label: String) async throws -> Int? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle,
              let recipe = AgentRecipeStore.recipes.first(where: { $0.host.bundleIDs.contains(bundle) && $0.host.desktopChat != nil }),
              let ui = recipe.host.desktopChat else { return nil }
        let route = Self(recipe: recipe, bundleID: bundle, ui: ui)
        let read = try await route.passiveRead()
        guard read.title == label else { return nil }
        return read.turns.filter { $0.user && route.flat($0.text) == route.flat(message) }.count
    }

    struct Turn: Sendable { let user: Bool; let text: String }

    struct Read: Sendable { let turns: [Turn]; let title: String?; let generating: Bool }

    func passiveRead() async throws -> Read {
        try await MacAccessibilityReader.read {
            let tree = try walk(window())
            let title = try openTitle(tree)
            let answering = try composer(tree).title.hasSuffix(" " + ui.stop) || tree.contains { button in
                MacAXAttributeRead.text(button, kAXRoleAttribute) == kAXButtonRole
                    && [kAXTitleAttribute, kAXDescriptionAttribute].contains { MacAXAttributeRead.text(button, $0).hasPrefix(ui.stop) }
            }
            let read = try Read(turns: turns(tree), title: title, generating: answering)
            guard try openTitle(walk(window())) == title else { throw Blocker.moved }
            return read
        }
    }

    /// Keys and paste on a locked Mac would go to the lock screen's password field.
    /// The screensaver sets the same flag, so it is woken first.
    func unlocked() async throws {
        let session = try await MacScreenLock.wakeIfCovered().after
        guard session.sessionReadable, session.onConsole, !session.screenIsLocked else { throw Blocker.locked }
    }

    nonisolated func windows() throws -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        return try SystemMacAXElementSource().nativeWindows(pid: app.processIdentifier)
    }

    /// What the app's windows show when none holds the chat: each window's title
    /// or, for a dialog, its words. Nil when nothing can be read.
    nonisolated func showing() -> String? {
        guard let all = try? windows() else { return nil }
        if all.isEmpty { return "no window" + (NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isHidden == true ? " (it is hidden)" : "") }
        let seen = all.compactMap { window -> String? in
            guard let tree = try? walk(window) else { return "an incomplete Accessibility read" }
            let words = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXStaticTextRole }
                .map { MacAXAttributeRead.text($0, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let title = MacAXAttributeRead.text(window, kAXTitleAttribute)
            let text = MacAXAttributeRead.text(window, kAXSubroleAttribute) == "AXDialog" || title.isEmpty
                ? words.prefix(2).joined(separator: ": ") : "a window titled \u{201C}\(title)\u{201D}"
            return text.isEmpty ? nil : (text.hasPrefix("a window") ? text : "\u{201C}" + String(text.prefix(200)) + "\u{201D}")
        }
        return seen.isEmpty ? nil : seen.joined(separator: " and ")
    }

    nonisolated func hasLog(_ window: AXUIElement) throws -> Bool { try walk(window).contains { MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.log } }

    /// The window holding the chat log.
    nonisolated func window() throws -> AXUIElement {
        let all = try windows()
        if all.count == 1 { return all[0] }
        guard let chat = try all.first(where: hasLog) else { throw all.isEmpty ? Blocker.window as any Error : Mismatch(key: "log", wanted: ui.log) }
        return chat
    }

    /// A minimized chat takes no clicks, and a closed one has nothing to click:
    /// un-minimize it, or reopen the app to bring its window back.
    func showWindow() async throws {
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty ? [] : try windows()
        var restored = false
        for window in existing where MacAXAttributeRead.copyRaw(window, kAXMinimizedAttribute) as? Bool == true {
            guard try SystemMacAXActSource().setNativeAttribute(window, attribute: kAXMinimizedAttribute, value: kCFBooleanFalse).get() == .success else { throw Blocker.window }
            restored = true
        }
        if restored { try await Task.sleep(for: .milliseconds(600)) }
        guard try !existing.contains(where: hasLog) else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Blocker.offline }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        do { try await until(seconds: 8) { try windows().contains(where: hasLog) } }
        catch let failure as MacAccessibilityReader.NativeReadFailure { throw failure }
        catch { throw (try? windows())?.isEmpty == false ? Mismatch(key: "log", wanted: ui.log) : Blocker.window as any Error }
    }

    /// The window's elements without descending into the message log: a long
    /// chat otherwise exhausts a bounded walk. The log node itself is kept.
    nonisolated func walk(_ root: AXUIElement) throws -> [AXUIElement] {
        try MacAccessibilityReader.elements(in: root, searching: "the desktop chat controls") {
            MacAXAttributeRead.text($0, kAXTitleAttribute) != self.ui.log
        }
    }

    nonisolated func buttons(_ match: (AXUIElement) -> Bool) throws -> [AXUIElement] {
        try walk(window()).filter { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXButtonRole && match($0) }
    }

    nonisolated func composer(_ tree: [AXUIElement]) throws -> (title: String, node: AXUIElement) {
        // While the app replies its Send button reads "Stop", so match the stable part.
        let boxes = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXButtonRole && MacAXAttributeRead.text($0, kAXTitleAttribute).contains(ui.composerCore) }
        if boxes.isEmpty { throw Mismatch(key: "composerCore", wanted: ui.composerCore) }
        guard boxes.count == 1 else { throw Blocker.window }
        return (MacAXAttributeRead.text(boxes[0], kAXTitleAttribute), boxes[0])
    }

    func frame(of node: AXUIElement) throws -> CGRect {
        guard let frame = MacAXAttributeRead.frame(node) else { throw Blocker.window }
        return frame
    }

    /// The open chat's title: the header when the side-chat panel is closed,
    /// else the panel entry the app marks current.
    nonisolated func openTitle(_ tree: [AXUIElement]) throws -> String? {
        if let title = try headerTitle(tree) { return title }
        guard let panel = try sideChatsPanel(tree) else { return nil }
        return try MacAccessibilityReader.elements(in: panel, searching: "the current desktop chat").first { MacAXAttributeRead.text($0, ui.current) == ui.currentValue }
            .map { entryTitle(MacAXAttributeRead.text($0, kAXTitleAttribute)) }
    }

    /// An entry's chat title without the app's status words.
    nonisolated func entryTitle(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(ui.unreadSuffix) { return String(text.dropLast(ui.unreadSuffix.count)) }
        if text.hasSuffix(ui.actionsSuffix) {
            text = String(text.dropLast(ui.actionsSuffix.count))
            // Drop the age token ("18m", "2h", "3d") that precedes the actions label.
            if let space = text.lastIndex(of: " ") { text = String(text[..<space]) }
        }
        return text
    }

    nonisolated func headerTitle(_ tree: [AXUIElement]) throws -> String? {
        guard let back = tree.first(where: { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXButtonRole && MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.backToMain }),
              let row = MacAXAttributeRead.parent(back) else { return nil }
        let siblings = try MacAccessibilityReader.childElements(in: row, searching: "the desktop chat header")
        guard let index = siblings.firstIndex(where: { CFEqual($0, back) }) else { return nil }
        return siblings[(index + 1)...].first { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXStaticTextRole }
            .map { MacAXAttributeRead.text($0, kAXValueAttribute) }
    }

    nonisolated func sideChatsPanel(_ tree: [AXUIElement]) throws -> AXUIElement? {
        tree.first { MacAXAttributeRead.text($0, kAXSubroleAttribute) == "AXLandmarkNavigation" && MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.chatsPanel }
    }

    /// The deepest pressable entries in the side-chat list that carry exactly this title.
    func sideChatEntries(named title: String) throws -> [AXUIElement] {
        try MacAccessibilityReader.withReadBudget {
            guard let panel = try sideChatsPanel(walk(window())) else { return [] }
            let (source, snapshot) = try MacAccessibilityReader.nativeSnapshot(in: panel, searching: "the desktop chat entries")
            var labelled: Set<[Int]> = [], entries: Set<[Int]> = [], found: [AXUIElement] = []
            for node in snapshot.nodes.reversed() {
                guard let element = node.element.flatMap(source.element) else { throw MacAccessibilityReader.NativeReadFailure(detail: "The desktop chat entry could not be read.") }
                let matches = labelled.contains(node.path) || [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
                    entryTitle(MacAXAttributeRead.text(element, $0)) == title
                }
                let entry = matches && node.attributes.role != kAXTextFieldRole && MacAXAttributeRead.copyActions(element).contains(kAXPressAction)
                if entry && !entries.contains(node.path) { found.append(element) }
                if matches { labelled.insert(Array(node.path.dropLast())) }
                if entry || entries.contains(node.path) { entries.insert(Array(node.path.dropLast())) }
            }
            try Task.checkCancellation()
            guard MacAXLimits.readDeadline.map({ Date() < $0 }) == true else { throw MacAccessibilityReader.NativeReadFailure(detail: "The desktop chat entry search exhausted the shared reader time budget.") }
            return found.reversed()
        }
    }

    /// The open chat's turns, oldest first. Two shapes are live in one log:
    /// "User message: …"/"Assistant message: …" texts, and grouped turns where
    /// the person's starts with "You:" and the assistant's carries "Copy response".
    nonisolated func turns(_ tree: [AXUIElement]) throws -> [Turn] {
        try logRows(tree).compactMap { child in
            if MacAXAttributeRead.text(child, kAXRoleAttribute) == kAXStaticTextRole {
                let value = MacAXAttributeRead.text(child, kAXValueAttribute)
                if value.hasPrefix(ui.userPrefix) { return Turn(user: true, text: String(value.dropFirst(ui.userPrefix.count))) }
                if value.hasPrefix(ui.assistantPrefix) { return Turn(user: false, text: String(value.dropFirst(ui.assistantPrefix.count))) }
                return nil
            }
            let kids = try MacAccessibilityReader.childElements(in: child, searching: "the desktop message")
            if let first = kids.first, MacAXAttributeRead.text(first, kAXValueAttribute) == ui.userLabel {
                return Turn(user: true, text: try kids.dropFirst().flatMap(texts).joined(separator: "\n"))
            }
            guard try MacAccessibilityReader.elements(in: child, searching: "the desktop assistant message").contains(where: { MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.assistantMarker }) else { return nil }
            let body = try texts(child)
            return body.isEmpty ? nil : Turn(user: false, text: body.joined(separator: "\n"))
        }
    }

    /// The open chat's log rows, as the window has them.
    nonisolated func logRows(_ tree: [AXUIElement]) throws -> [AXUIElement] {
        guard let log = tree.first(where: { MacAXAttributeRead.text($0, kAXTitleAttribute) == ui.log }) else { throw Mismatch(key: "log", wanted: ui.log) }
        return try MacAccessibilityReader.childElements(in: log, searching: "the desktop transcript rows")
    }

    nonisolated func texts(_ node: AXUIElement) throws -> [String] {
        try MacAccessibilityReader.elements(in: node, searching: "the desktop reply text")
            .filter { MacAXAttributeRead.text($0, kAXRoleAttribute) == kAXStaticTextRole }
            .map { MacAXAttributeRead.text($0, kAXValueAttribute) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// True only when the chat's first user turn is exactly this saved first message.
    func opensWith(_ turns: [Turn], _ first: String?) -> Bool {
        guard let first, let opener = turns.first(where: \.user) else { return false }
        return flat(opener.text) == flat(first)
    }

    func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Waits for `ready`. On timeout it throws the last recipe miss a read hit
    /// (a label the window lacks, so healing sees it), else `timeout`.
    func until(seconds: Double, else timeout: any Error = Blocker.submission, _ ready: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        let events = try DesktopRouteObservation(bundleID: bundleID)
        defer { events.stop() }
        var miss: Mismatch?
        repeat {
            try Task.checkCancellation()
            do { if try ready() { return } }
            catch let error as MacAccessibilityReader.NativeReadFailure { throw error }
            catch is CancellationError { throw CancellationError() }
            catch let error as Mismatch { miss = error }
            catch {}
            if Date() >= deadline { break }
            try await events.next(until: deadline)
        } while true
        throw miss.map { $0 as any Error } ?? timeout
    }

}
