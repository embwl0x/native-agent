import AppKit
import ApplicationServices
import ChatOrchestration
import MacControl
import NativeAgentCore
import PersistenceCore

/// A chat app driven through its own window, by the labels its recipe names
/// (agents/recipes/<host>.json, `desktopChat`). The agent gets a side chat of
/// her own there; every message selects that chat by its title, types into it,
/// and reads the answer back from it — never from any other chat. Seen on the
/// first such app (09-22): the composer is one AX button whose title is its
/// whole text ("Message Attach file Dictate a message Send" when empty), so
/// text goes in by click and paste.
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
        didSet { if !busy { let waiting = idleWaiters; idleWaiters = []; waiting.forEach { $0.resume() } } }
    }
    private static var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The chat her message went into, for an uncertain result to carry.
    private static var lastChat: String?
    /// Which of the chat's same-text messages of hers this send was (0 = first).
    private static var lastOccurrence: Int?
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
        if plan["dry_run"] == .bool(true) { return await route.dryRun(peerID: peerID, dataRoot: dataRoot) }
        return await route.perform(text, peerID: peerID, plan: plan, dataRoot: dataRoot)
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
        guard AXIsProcessTrusted() else { return failed(Blocker.permission.detail(name, app: appName)) }
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
        AgentPeerStore(dataRoot: dataRoot).recordRoundTrip(peerID: peerID, workspace: "dry run", recipe: now)
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
        _ = try composer()
        guard try !buttons({ AX.string($0, kAXTitleAttribute) == ui.newChat }).isEmpty else { throw Mismatch(key: "newChat", wanted: ui.newChat) }
    }

    /// Up to five labels sharing the most words with `wanted`: the window's
    /// titles and descriptions, or `among` when given.
    func nearest(_ wanted: String, among: [String]? = nil) -> [String] {
        func words(_ text: String) -> Set<Substring> { Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }) }
        let goal = words(wanted)
        let seen = Set((among ?? ((try? windows()) ?? []).flatMap { walk($0) }.flatMap { node in
            [kAXTitleAttribute, kAXDescriptionAttribute].map { AX.string(node, $0) } })
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
        guard let rows = try? logRows() else { return said(Mismatch(key: "log", wanted: ui.log), then: unsure) }
        guard let before, rows.count > before else {
            // Nothing came: today's words, and the window's labels for the fix.
            var fields = said(Mismatch(key: "userPrefix", wanted: ui.userPrefix)).fields
            fields["reason"] = .string("not_confirmed")
            return (Blocker.submission.detail(name, app: appName), fields)
        }
        let added = Array(rows[before...])
        let row = added.first.map { node in
            let own = AX.string(node, kAXTitleAttribute) + AX.string(node, kAXDescriptionAttribute)
            return String((own.isEmpty ? texts(node).prefix(2).joined(separator: " ") : own).prefix(80))
        } ?? ""
        let labels = nearest(ui.userPrefix, among: added.flatMap { AX.nodes($0) }.flatMap { node in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { AX.string(node, $0) } })
        return ("\(appName)'s chat gained \(added.count) row\(added.count == 1 ? "" : "s") after the message that \(added.count == 1 ? "doesn't" : "don't") read as hers "
                    + "(its recipe's userPrefix \u{201C}\(ui.userPrefix)\u{201D}): \u{201C}\(row)\u{201D}"
                    + (labels.isEmpty ? "" : "; nearest: " + Self.quoted(labels)) + ". " + unsure,
                ["reason": .string("recipe_mismatch"), "selector": .string("userPrefix"), "row": .string(row), "labels": .array(labels.map(JSONValue.string))])
    }

    private func perform(_ text: String, peerID: String, plan: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        let name = AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string(Blocker.offline.detail(name, app: appName))])
        }
        guard !Self.busy else {
            return .object(["status": .string("busy"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string("\(appName) is still answering the previous message. Nothing was sent.")])
        }
        Self.busy = true
        defer { Self.busy = false }
        var thread: String?
        if case .string(let saved)? = plan["conversation_id"] { thread = saved }
        let store = AgentPeerStore(dataRoot: dataRoot)
        Self.lastChat = nil; Self.lastOccurrence = nil; Self.pressedReturn = false
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
            if submissionConfirmed { result["sent"] = .bool(true) }
            let snapshot = try? await passiveRead()
            let matchingNewChat = thread == nil && snapshot.map({ opensWith($0.turns, first) }) == true ? snapshot?.title : nil
            let chat = matchingNewChat ?? Self.lastChat
            if let chat, chat != untitled { result["conversation_id"] = .string(chat); remember(chat) }
            return .object(result)
        }
        do {
            let (reply, title) = try await send(message, thread: thread, first: first) { submissionConfirmed = true }
            remember(title)
            store.recordProof(peerID: peerID, inbound: true, outbound: true)
            store.recordRoundTrip(peerID: peerID, workspace: title, recipe: recipe)
            var answered: [String: JSONValue] = ["status": .string("answered"), "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                            "sent": .bool(true), "completed": .bool(true), "reply": .string(reply),
                            "conversation_id": .string(title), "continued": .bool(thread != nil), "untrusted_remote_data": .bool(true)]
            if thread == nil { answered["detail"] = .string("Opened a new side chat in \(appName) for this conversation.") }
            return .object(answered)
        } catch {
            if submissionConfirmed {
                if let blocker = error as? Blocker, [.moved, .timeout].contains(blocker) {
                    // User 10-07: an answer is delivered whenever it comes.
                    if let live = AgentConversationLiveContext.target, let row = live.recordID, let operation = live.operationID,
                       let occurrence = Self.lastOccurrence, let events = try? MacAppSourceEvents(bundleID: bundleID) {
                        Task { await lateAnswer(message, occurrence: occurrence, first: first, peerID: peerID,
                                                row: row, operation: operation, events: events, dataRoot: dataRoot) }
                        return await uncertain(Blocker.named(Blocker.late, name, app: appName))
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
                // Say what the app shows instead of its chat (09-25: a forced-update alert over its login window).
                let shown = blocker == .window ? try? await DesktopPeerReadLane.read { showing() } : nil
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

    // MARK: - One exchange

    func send(_ message: String, thread: String?, first: String?, didSubmit: () -> Void) async throws -> (String, String) {
        try await unlocked()
        guard AXIsProcessTrusted() else { throw Blocker.permission }
        try await showWindow()
        var (reopen, chat) = try await openThread(thread, first: first)
        Self.lastChat = chat
        let key = String(flat(message).prefix(40))
        func mine(_ turns: [Turn]) -> Int? { turns.lastIndex { $0.user && flat($0.text).hasPrefix(key) } }
        func sent() throws -> Int { try turns().filter { $0.user && flat($0.text).hasPrefix(key) }.count }
        func ownsChat() throws -> Bool {
            let all = try turns()
            return thread == nil ? all.isEmpty : opensWith(all, first)
        }
        var rows: Int?
        let before = try await typeAndSubmit(message, chat: chat ?? untitled, reopen: reopen, ownsChat: ownsChat,
                                             count: { rows = try? logRows().count; return try sent() })
        do {
            try await until(seconds: 15) { try sent() > before }
        } catch { throw Unconfirmed(rows: rows) }
        Self.lastOccurrence = before
        didSubmit()
        var last = "", stableSince = Date()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            let snapshot = try await passiveRead()
            let all = snapshot.turns
            let title = snapshot.title
            if let current = chat, title != current {
                // The app renames chats a few minutes in: a new title is hers only if it opens with her exact first message.
                guard let title, opensWith(all, first) else { throw Blocker.moved }
                chat = title
            }
            guard let index = mine(all) else { continue }
            Self.lastChat = title ?? Self.lastChat
            let reply = all[(index + 1)...].filter { !$0.user }.map(\.text).joined(separator: "\n\n")
            if reply != last { last = reply; stableSince = Date(); continue }
            if !reply.isEmpty, Date().timeIntervalSince(stableSince) >= 3, !snapshot.generating {
                return (reply, try await settledTitle(chat, first: first))
            }
        }
        throw Blocker.timeout
    }

    /// Past the send's two minutes: the app's own accessibility notifications
    /// (values and children changing in its window) each trigger one read of
    /// her chat, never a clock. When the answer after her message is there and
    /// the app has stopped generating, it lands on its exchange. It ends when
    /// the app quits, or when a later message of hers follows unanswered.
    /// `occurrence`: which of her same-text messages in that chat this send was.
    func lateAnswer(_ message: String, occurrence: Int, first: String?, peerID: String, row: String, operation: String,
                    events: MacAppSourceEvents, dataRoot: URL) async {
        defer { events.cancel() }
        let key = String(flat(message).prefix(40))
        do {
            for try await _ in events.stream {
                // Another send drives the app now: read once it is done, not never.
                while Self.busy { await withCheckedContinuation { Self.idleWaiters.append($0) } }
                // Hold the same admission as sends across the worker suspension.
                Self.busy = true
                let snapshot = try? await passiveRead()
                Self.busy = false
                guard let snapshot, opensWith(snapshot.turns, first) else { continue }
                let all = snapshot.turns
                let mine = all.indices.filter { all[$0].user && flat(all[$0].text).hasPrefix(key) }
                guard mine.count > occurrence else { continue }
                let index = mine[occurrence]
                let answer = all[(index + 1)...].prefix { !$0.user }.map(\.text).joined(separator: "\n\n")
                if answer.isEmpty, all[(index + 1)...].contains(where: \.user) { return }
                guard !answer.isEmpty, !snapshot.generating else { continue }
                let title = snapshot.title
                var receipt: [String: JSONValue] = ["status": .string("answered"), "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                                                    "sent": .bool(true), "completed": .bool(true), "reply": .string(answer), "untrusted_remote_data": .bool(true)]
                if let title, title != untitled {
                    receipt["conversation_id"] = .string(title)
                    // The title it carries resumes this chat, alongside any earlier one.
                    Self.remember(title, replacing: nil, first: first, peerID: peerID, dataRoot: dataRoot)
                }
                try GrokDesktopReply.land(receipt, answer: answer, row: row, operation: operation, dataRoot: dataRoot)
                AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peerID, inbound: true, outbound: true)
                return
            }
        } catch { nativeLog("Desktop reply observation or save failed: %@", error.localizedDescription) }
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
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }

    /// Her chat by its saved title, or a new side chat on first use. Returns
    /// true when her chat's list entry still has to be clicked: the app ignores
    /// AXPress and background clicks on entries (09-22), so that click happens
    /// in front, in the same brief window as typing.
    /// Also returns the chat's title now: when the app has renamed her chat, the
    /// one it marks current is hers only if its first user turn is exactly her saved first message.
    func openThread(_ thread: String?, first: String?) async throws -> (reopen: Bool, chat: String?) {
        let open = openTitle()
        if let thread, open == thread {
            guard try opensWith(turns(), first) else { throw Blocker.thread }
            return (false, thread)
        }
        let openIsHers = thread != nil && (try? opensWith(turns(), first)) == true
        try await showSideChats()
        if let thread {
            let saved = try sideChatEntries(named: thread).count
            if saved == 1 { return (true, thread) }
            guard let open, open != untitled, openIsHers, try sideChatEntries(named: open).count == 1 else {
                // Gone only when the side-chat list is shown and has no entry by that title.
                throw saved == 0 && (try? sideChatsPanel()) != nil ? Blocker.missing : Blocker.thread
            }
            return (true, open)
        } else {
            let new = try buttons { AX.string($0, kAXTitleAttribute) == ui.newChat }
            if new.isEmpty { throw Mismatch(key: "newChat", wanted: ui.newChat) }
            guard new.count == 1, AXUIElementPerformAction(new[0], kAXPressAction as CFString) == .success else { throw Blocker.thread }
            try await until(seconds: 5, else: Blocker.thread) { try openTitle() == untitled && turns().isEmpty }
            return (false, nil)
        }
    }

    func showSideChats() async throws {
        if let back = try buttons({ AX.string($0, kAXTitleAttribute) == ui.backToMain }).first {
            _ = AXUIElementPerformAction(back, kAXPressAction as CFString)
            try await until(seconds: 5, else: Blocker.thread) { headerTitle() == nil }
        }
        if try sideChatsPanel() == nil {
            guard let open = try buttons({ AX.string($0, kAXTitleAttribute).hasPrefix(ui.chatsButton) }).first else { throw Mismatch(key: "chatsButton", wanted: ui.chatsButton) }
            guard AXUIElementPerformAction(open, kAXPressAction as CFString) == .success else { throw Blocker.window }
            try await until(seconds: 5, else: Mismatch(key: "chatsPanel", wanted: ui.chatsPanel)) { try sideChatsPanel() != nil }
        }
    }

    /// Type with the app in front (its composer only takes real input), then
    /// give the front back to whoever had it.
    /// Returns `count` as read in her verified-open chat just before input.
    func typeAndSubmit(_ message: String, chat: String, reopen: Bool, ownsChat: () throws -> Bool, count: () throws -> Int) async throws -> Int {
        // The app's box label never shows its text and drops "Send" in some states
        // (09-22: User's main chat read "Message Attach file Dictate a message"),
        // so no draft check here: select-all + paste in her own chat replaces it.
        _ = try composer()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Blocker.offline }
        // Let the person's typing finish (up to ~5s) so it can't land in the app.
        for _ in 0..<25 where CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 2 {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await unlocked()
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let before: Int
        do { before = try await typeInFront(message, chat: chat, reopen: reopen, ownsChat: ownsChat, count: count, app: app) } catch { await restore(previous, from: app); throw error }
        await restore(previous, from: app)
        return before
    }

    private func restore(_ previous: NSRunningApplication?, from app: NSRunningApplication) async {
        guard let previous, !previous.isTerminated, previous.processIdentifier != app.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let url = previous.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func typeInFront(_ message: String, chat: String, reopen: Bool, ownsChat: () throws -> Bool, count: () throws -> Int, app: NSRunningApplication) async throws -> Int {
        func front() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        func click(_ node: AXUIElement) throws {
            let frame = try frame(of: node)
            let point = CGPoint(x: frame.minX + frame.width * 0.35, y: frame.midY)
            let events = try [CGEventType.leftMouseDown, .leftMouseUp].map { type -> CGEvent in
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw Blocker.typing }
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.setIntegerValueField(.eventSourceUserData, value: NativeAgentMacEventIdentity.sourceUserData)
                return event
            }
            for event in events {
                guard front() else { throw Blocker.window }
                PersonOnlyWindows.beforeAgentPointer(at: point)
                NativeAgentMotorEpoch.notePostedHIDEvent()
                event.post(tap: .cghidEventTap)
            }
        }
        try await until(seconds: 4, else: Blocker.window) { front() }
        if reopen {
            // Only ever her own entry in the side-chat list; never the main chat.
            let entries = try sideChatEntries(named: chat)
            guard entries.count == 1 else { throw Blocker.thread }
            try click(entries[0])
            // 09-22: wait for her log too, so the baseline below counts her rows, not a half-loaded log's.
            try await until(seconds: 5, else: Blocker.thread) { try openTitle() == chat && !turns().isEmpty }
        }
        // Activation can change the window: verify her opening message before any input.
        guard openTitle() == chat, try ownsChat() else { throw Blocker.thread }
        // 09-22: baseline taken here, in her chat; counted in whatever chat was open
        // before the reopen, an older same-prefix row of hers could confirm as new.
        let before = try count()
        // The app never exposes the box's text (its label stays "Message …"), so a
        // draft can't be seen; this is her own side chat, so select-all + paste
        // replaces whatever is in her box. Delivery is proven after Return by
        // her "User message:" row appearing (see send()).
        // The app ignores postToPid key events (09-22 live test), so keys use the
        // HID tap with the app re-checked frontmost immediately before each one.
        func keys(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
            for event in try AX.keyEvents(code, flags: flags) {
                // Shotgun: never while the person types in their own window, which would take these keys.
                guard front(), !PersonOnlyWindows.keyboardHeldByPerson else { throw Blocker.typing }
                NativeAgentMotorEpoch.notePostedHIDEvent()
                event.post(tap: .cghidEventTap)
            }
        }
        try click(composer().node)
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
        guard openTitle() == chat, try ownsChat() else { throw Blocker.thread }
        try keys(0, flags: .maskCommand)   // select all in her box
        try keys(9, flags: .maskCommand)   // paste
        try await Task.sleep(for: .milliseconds(400))
        guard openTitle() == chat, try ownsChat() else { throw Blocker.thread }
        Self.pressedReturn = true
        try keys(36)
        try await Task.sleep(for: .milliseconds(300))
        return before
    }

    /// First use: wait briefly for the app to name the new chat. Every exchange
    /// returns the title the chat shows now (2026-09-22: the app renames chats
    /// after the first minutes, and a stale saved title broke the next send).
    func settledTitle(_ thread: String?, first: String?) async throws -> String {
        let deadline = Date().addingTimeInterval(thread == nil ? 8 : 0)
        while true {
            let snapshot = try await passiveRead()
            guard opensWith(snapshot.turns, first) else { throw Blocker.moved }
            if thread != nil || (snapshot.title ?? untitled) != untitled || Date() >= deadline {
                return snapshot.title ?? thread ?? untitled
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Reading the window

    struct Turn: Sendable { let user: Bool; let text: String }

    struct Read: Sendable { let turns: [Turn]; let title: String?; let generating: Bool }

    func passiveRead() async throws -> Read {
        try await DesktopPeerReadLane.read {
            let title = openTitle()
            let read = Read(turns: try turns(), title: title, generating: generating())
            guard openTitle() == title else { throw Blocker.moved }
            return read
        }
    }

    /// Keys and paste on a locked Mac would go to the lock screen's password field.
    /// The screensaver sets the same flag, so it is woken first.
    func unlocked() async throws {
        try await MacScreenLock.wakeIfCovered()
        // Fail closed: no session dictionary, or no proof it is on console and unlocked, sends nothing.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { throw Blocker.locked }
    }

    nonisolated func windows() throws -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        return AX.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// What the app's windows show when none holds the chat: each window's title
    /// or, for a dialog, its words. Nil when nothing can be read.
    nonisolated func showing() -> String? {
        guard let all = try? windows() else { return nil }
        if all.isEmpty { return "no window" + (NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isHidden == true ? " (it is hidden)" : "") }
        let seen = all.compactMap { window -> String? in
            let words = AX.nodes(window).filter { AX.string($0, kAXRoleAttribute) == kAXStaticTextRole }
                .map { AX.string($0, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let title = AX.string(window, kAXTitleAttribute)
            let text = AX.string(window, kAXSubroleAttribute) == "AXDialog" || title.isEmpty
                ? words.prefix(2).joined(separator: ": ") : "a window titled \u{201C}\(title)\u{201D}"
            return text.isEmpty ? nil : (text.hasPrefix("a window") ? text : "\u{201C}" + String(text.prefix(200)) + "\u{201D}")
        }
        return seen.isEmpty ? nil : seen.joined(separator: " and ")
    }

    nonisolated func hasLog(_ window: AXUIElement) -> Bool { walk(window).contains { AX.string($0, kAXTitleAttribute) == ui.log } }

    /// The window holding the chat log (09-22: a Settings window beside it failed as "signed out").
    nonisolated func window() throws -> AXUIElement {
        let all = try windows()
        if all.count == 1 { return all[0] }
        guard let chat = all.first(where: hasLog) else { throw all.isEmpty ? Blocker.window as any Error : Mismatch(key: "log", wanted: ui.log) }
        return chat
    }

    /// A minimized chat takes no clicks, and a closed one has nothing to click:
    /// un-minimize it, or reopen the app to bring its window back.
    func showWindow() async throws {
        var restored = false
        for window in try windows() where AX.attribute(window, kAXMinimizedAttribute) as? Bool == true {
            restored = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success || restored
        }
        if restored { try await Task.sleep(for: .milliseconds(600)) }
        guard try !windows().contains(where: hasLog) else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Blocker.offline }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        do { try await until(seconds: 8) { try windows().contains(where: hasLog) } }
        catch { throw (try? windows())?.isEmpty == false ? Mismatch(key: "log", wanted: ui.log) : Blocker.window as any Error }
    }

    nonisolated func children(_ node: AXUIElement) -> [AXUIElement] {
        AX.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// The window's elements without descending into the message log: a long
    /// chat otherwise exhausts a bounded walk before the side-chat controls
    /// (09-22: User's main chat hid "New side chat"). The log node itself is kept.
    nonisolated func walk(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 4000 {
            let node = queue.removeFirst(); result.append(node)
            if AX.string(node, kAXTitleAttribute) == ui.log { continue }
            queue.append(contentsOf: children(node))
        }
        return result
    }

    nonisolated func buttons(_ match: (AXUIElement) -> Bool) throws -> [AXUIElement] {
        walk(try window()).filter { AX.string($0, kAXRoleAttribute) == kAXButtonRole && match($0) }
    }

    nonisolated func composer() throws -> (title: String, node: AXUIElement) {
        // While the app replies its Send button reads "Stop", so match the stable part.
        let boxes = try buttons { AX.string($0, kAXTitleAttribute).contains(ui.composerCore) }
        if boxes.isEmpty { throw Mismatch(key: "composerCore", wanted: ui.composerCore) }
        guard boxes.count == 1 else { throw Blocker.window }
        return (AX.string(boxes[0], kAXTitleAttribute), boxes[0])
    }

    func frame(of node: AXUIElement) throws -> CGRect {
        guard let position = AX.attribute(node, kAXPositionAttribute), let size = AX.attribute(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { throw Blocker.window }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { throw Blocker.window }
        return CGRect(origin: point, size: extent)
    }

    /// The open side chat's title, beside "Back to main chat"; nil in the main chat.
    /// The open chat's title: the header when the side-chat panel is closed,
    /// else the panel entry the app marks current.
    nonisolated func openTitle() -> String? {
        if let title = headerTitle() { return title }
        guard let panel = try? sideChatsPanel() else { return nil }
        return AX.nodes(panel).first { AX.string($0, ui.current) == ui.currentValue }
            .map { entryTitle(AX.string($0, kAXTitleAttribute)) }
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

    nonisolated func headerTitle() -> String? {
        guard let back = try? buttons({ AX.string($0, kAXTitleAttribute) == ui.backToMain }).first,
              let row = AX.parent(back) else { return nil }
        let siblings = children(row)
        guard let index = siblings.firstIndex(where: { CFEqual($0, back) }) else { return nil }
        return siblings[(index + 1)...].first { AX.string($0, kAXRoleAttribute) == kAXStaticTextRole }
            .map { AX.string($0, kAXValueAttribute) }
    }

    nonisolated func sideChatsPanel() throws -> AXUIElement? {
        walk(try window()).first { AX.string($0, kAXSubroleAttribute) == "AXLandmarkNavigation" && AX.string($0, kAXTitleAttribute) == ui.chatsPanel }
    }

    /// The deepest pressable entries in the side-chat list that carry exactly this title.
    func sideChatEntries(named title: String) throws -> [AXUIElement] {
        guard let panel = try sideChatsPanel() else { return [] }
        func pressable(_ node: AXUIElement) -> Bool {
            var names: CFArray?
            return AXUIElementCopyActionNames(node, &names) == .success && (names as? [String] ?? []).contains(kAXPressAction)
        }
        func labelled(_ node: AXUIElement) -> Bool {
            AX.nodes(node).contains { item in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { key in
                let label = AX.string(item, key).trimmingCharacters(in: .whitespacesAndNewlines)
                // The app appends a status to unread entries: "<title> Unread updates".
                return entryTitle(label) == title } }
        }
        let found = AX.nodes(panel).filter { AX.string($0, kAXRoleAttribute) != kAXTextFieldRole && pressable($0) && labelled($0) }
        return found.filter { candidate in
            !found.contains { other in
                guard !CFEqual(other, candidate) else { return false }
                var node = AX.parent(other)
                while let current = node { if CFEqual(current, candidate) { return true }; node = AX.parent(current) }
                return false
            }
        }
    }

    /// The open chat's turns, oldest first. Two shapes are live in one log:
    /// "User message: …"/"Assistant message: …" texts, and grouped turns where
    /// the person's starts with "You:" and the assistant's carries "Copy response".
    nonisolated func turns() throws -> [Turn] {
        try logRows().compactMap { child in
            if AX.string(child, kAXRoleAttribute) == kAXStaticTextRole {
                let value = AX.string(child, kAXValueAttribute)
                if value.hasPrefix(ui.userPrefix) { return Turn(user: true, text: String(value.dropFirst(ui.userPrefix.count))) }
                if value.hasPrefix(ui.assistantPrefix) { return Turn(user: false, text: String(value.dropFirst(ui.assistantPrefix.count))) }
                return nil
            }
            let kids = children(child)
            if let first = kids.first, AX.string(first, kAXValueAttribute) == ui.userLabel {
                return Turn(user: true, text: kids.dropFirst().flatMap(texts).joined(separator: "\n"))
            }
            guard AX.nodes(child).contains(where: { AX.string($0, kAXTitleAttribute) == ui.assistantMarker }) else { return nil }
            let body = texts(child)
            return body.isEmpty ? nil : Turn(user: false, text: body.joined(separator: "\n"))
        }
    }

    /// The open chat's log rows, as the window has them.
    nonisolated func logRows() throws -> [AXUIElement] {
        guard let log = walk(try window()).first(where: { AX.string($0, kAXTitleAttribute) == ui.log }) else { throw Mismatch(key: "log", wanted: ui.log) }
        return children(log)
    }

    /// Depth-first in reading order: breadth-first with a 1,500-node cap
    /// shuffled and cut long answers (09-22). The cap is only a safety bound.
    nonisolated func texts(_ node: AXUIElement) -> [String] {
        var stack = [node], result: [String] = [], visited = 0
        while visited < 20_000, let current = stack.popLast() {
            visited += 1
            if AX.string(current, kAXRoleAttribute) == kAXStaticTextRole {
                let value = AX.string(current, kAXValueAttribute)
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(value) }
            }
            stack.append(contentsOf: children(current).reversed())
        }
        return result
    }

    nonisolated func generating() -> Bool {
        // While answering, the composer's label ends in " Stop" rather than starting with it.
        if (try? composer().title.hasSuffix(" " + ui.stop)) == true { return true }
        return (try? buttons { button in [kAXTitleAttribute, kAXDescriptionAttribute].contains { AX.string(button, $0).hasPrefix(ui.stop) } }.isEmpty == false) ?? false
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
        var miss: Mismatch?
        while Date() < deadline {
            do { if try ready() { return } } catch let error as Mismatch { miss = error } catch {}
            try await Task.sleep(for: .milliseconds(200))
        }
        throw miss.map { $0 as any Error } ?? timeout
    }

}
