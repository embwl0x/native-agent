import AppKit
import ApplicationServices
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// A chat app driven through its own window (today: Muse, com.meta.endo). The
/// agent gets a side chat of her own there; every message selects that chat by
/// its title, types into it, and reads the answer back from it — never from
/// any other chat. Seen on the installed app (09-22): the composer is one AX
/// button whose title is its whole text ("Message Attach file Dictate a
/// message Send" when empty), so text goes in by click and paste.
@MainActor enum DesktopChatRoute {
    enum Blocker: String, Error {
        case offline = "Muse isn't installed or wouldn't open. Nothing was sent."
        case permission = "Allow NativeAgent Accessibility access so it can use Muse's window. Nothing was sent."
        case window = "Muse isn't showing its chat (is it signed in?). Nothing was sent."
        case thread = "Agent's own chat in Muse couldn't be found or opened, so nothing was sent."
        case typing = "Muse's message box didn't take the text. Nothing was sent; check Muse's message box."
        case submission = "Muse didn't confirm the message. Check Agent's chat in Muse; it won't be resent automatically."
        case moved = "Muse left Agent's chat before answering. The message was sent; its answer will be in her chat in Muse."
        case timeout = "Muse didn't finish answering within two minutes. The message was sent; its answer will be in her chat in Muse."
        case locked = "Mac is locked, nothing was sent."
        /// The texts say "Agent"; the agent here may be named otherwise.
        func detail(_ name: String) -> String { rawValue.replacingOccurrences(of: "Agent", with: name) }
    }
    /// EVERY SELECTOR IN ONE PLACE: the labels Muse's window exposes, as seen
    /// on the installed app 09-22. When Muse changes them, change them here;
    /// anything unmatched fails with a plain blocker, never a guess.
    enum Muse {
        static let newChat = "New side chat"            // button, and a new chat's title
        static let backToMain = "Back to main chat"     // header button; the title follows it
        static let chatsButton = "Chats"                // prefix of "Chats Open chat and side chats"
        static let chatsPanel = "Side chats"            // AXLandmarkNavigation
        static let log = "Chat messages"
        static let composerCore = "Attach file Dictate a message"
        static let userPrefix = "User message: ", assistantPrefix = "Assistant message: "
        static let userLabel = "You:", assistantMarker = "Copy response", stop = "Stop"
        // Side-chat entries are labelled "<title> Unread updates" or
        // "<title> 18m More thread actions"; the open one has aria-current=page.
        static let unreadSuffix = " Unread updates", actionsSuffix = " More thread actions"
        static let current = "AXARIACurrent", currentValue = "page"
    }
    static let bundleID = "com.meta.endo"
    static let untitled = Muse.newChat
    private static var busy = false
    /// The chat her message went into, for an uncertain result to carry.
    private static var lastChat: String?
    private typealias AX = GrokRoutineAccessibility

    static func perform(plan: [String: JSONValue], dataRoot: URL) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"], case .string(let text)? = plan["text"] else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string("Missing message.")])
        }
        guard !busy else {
            return .object(["status": .string("busy"), "sent": .bool(false), "completed": .bool(false),
                            "detail": .string("Muse is still answering the previous message. Nothing was sent.")])
        }
        busy = true
        defer { busy = false }
        var thread: String?
        if case .string(let saved)? = plan["conversation_id"] { thread = saved }
        let store = AgentPeerStore(dataRoot: dataRoot)
        let name = AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).agent
        lastChat = nil
        // Her first message names her, so the chat is recognisably hers in Muse.
        let message = thread == nil && !text.hasPrefix(name) ? name + " here — " + text : text
        // The exact first message of each of her chats, by title: a renamed chat
        // is hers only if it opens with exactly that (never just her name).
        let file = dataRoot.appendingPathComponent("agents/desktop-chat-" + peerID + ".json")
        var firsts = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
        let first = thread.map { firsts[$0] } ?? message
        func remember(_ title: String?) {
            guard let title, let first else { return }
            if let thread, thread != title { firsts[thread] = nil }
            firsts[title] = first
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(firsts).write(to: file, options: .atomic)
        }
        // An uncertain send keeps its chat, so the thread resumes instead of being orphaned.
        func uncertain(_ detail: String) -> JSONValue {
            var result: [String: JSONValue] = ["status": .string("outcome_unknown"), "completed": .bool(false), "detail": .string(detail)]
            let matchingNewChat = thread == nil && (try? opensWith(turns(), first)) == true ? openTitle() : nil
            let chat = matchingNewChat ?? lastChat
            if let chat, chat != untitled { result["conversation_id"] = .string(chat); remember(chat) }
            return .object(result)
        }
        do {
            let (reply, title) = try await send(message, thread: thread, first: first)
            remember(title)
            store.recordProof(peerID: peerID, inbound: true, outbound: true)
            store.recordRoundTrip(peerID: peerID, workspace: title)
            return .object(["status": .string("answered"), "agent": .string("peer:" + peerID), "transport": .string("desktopChat"),
                            "sent": .bool(true), "completed": .bool(true), "reply": .string(reply),
                            "conversation_id": .string(title), "continued": .bool(thread != nil), "untrusted_remote_data": .bool(true)])
        } catch let blocker as Blocker {
            if [.moved, .timeout, .submission].contains(blocker) { return uncertain(blocker.detail(name)) }
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string(blocker.detail(name))])
        } catch {
            return uncertain(Blocker.submission.detail(name))
        }
    }

    // MARK: - One exchange

    static func send(_ message: String, thread: String?, first: String?) async throws -> (String, String) {
        try unlocked()
        guard AXIsProcessTrusted() else { throw Blocker.permission }
        guard await ensureRunning() else { throw Blocker.offline }
        try await showWindow()
        var (reopen, chat) = try await openThread(thread, first: first)
        lastChat = chat
        let key = String(flat(message).prefix(40))
        func mine(_ turns: [Turn]) -> Int? { turns.lastIndex { $0.user && flat($0.text).hasPrefix(key) } }
        func sent() throws -> Int { try turns().filter { $0.user && flat($0.text).hasPrefix(key) }.count }
        let before = try await typeAndSubmit(message, chat: chat ?? untitled, reopen: reopen, count: sent)
        do {
            try await until(seconds: 15) { try sent() > before }
        } catch { throw Blocker.submission }
        var last = "", stableSince = Date()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            let all = try turns()
            let title = openTitle()
            if let current = chat, title != current {
                // Muse renames chats a few minutes in: a new title is hers only if it opens with her exact first message.
                guard let title, opensWith(all, first) else { throw Blocker.moved }
                chat = title
            }
            guard let index = mine(all) else { continue }
            lastChat = title ?? lastChat
            let reply = all[(index + 1)...].filter { !$0.user }.map(\.text).joined(separator: "\n\n")
            if reply != last { last = reply; stableSince = Date(); continue }
            if !reply.isEmpty, Date().timeIntervalSince(stableSince) >= 3, !generating() {
                return (reply, try await settledTitle(chat))
            }
        }
        throw Blocker.timeout
    }

    /// Her chat by its saved title, or a new side chat on first use. Returns
    /// true when her chat's list entry still has to be clicked: Muse ignores
    /// AXPress and background clicks on entries (09-22), so that click happens
    /// in front, in the same brief window as typing.
    /// Also returns the chat's title now: when Muse has renamed her chat, the
    /// one it marks current is hers only if its first user turn is exactly her saved first message.
    static func openThread(_ thread: String?, first: String?) async throws -> (reopen: Bool, chat: String?) {
        let open = openTitle()
        if let thread, open == thread { return (false, thread) }
        let openIsHers = thread != nil && (try? opensWith(turns(), first)) == true
        try await showSideChats()
        if let thread {
            if try sideChatEntries(named: thread).count == 1 { return (true, thread) }
            guard let open, open != untitled, openIsHers, try sideChatEntries(named: open).count == 1 else { throw Blocker.thread }
            return (true, open)
        } else {
            let new = try buttons { AX.string($0, kAXTitleAttribute) == Muse.newChat }
            guard new.count == 1, AXUIElementPerformAction(new[0], kAXPressAction as CFString) == .success else { throw Blocker.thread }
            do { try await until(seconds: 5) { try openTitle() == untitled && turns().isEmpty } } catch { throw Blocker.thread }
            return (false, nil)
        }
    }

    static func showSideChats() async throws {
        if let back = try buttons({ AX.string($0, kAXTitleAttribute) == Muse.backToMain }).first {
            _ = AXUIElementPerformAction(back, kAXPressAction as CFString)
            do { try await until(seconds: 5) { headerTitle() == nil } } catch { throw Blocker.thread }
        }
        if try sideChatsPanel() == nil {
            guard let open = try buttons({ AX.string($0, kAXTitleAttribute).hasPrefix(Muse.chatsButton) }).first,
                  AXUIElementPerformAction(open, kAXPressAction as CFString) == .success else { throw Blocker.window }
            do { try await until(seconds: 5) { try sideChatsPanel() != nil } } catch { throw Blocker.thread }
        }
    }

    /// Type with the app in front (its composer only takes real input), then
    /// give the front back to whoever had it.
    /// Returns `count` as read in her verified-open chat just before input.
    static func typeAndSubmit(_ message: String, chat: String, reopen: Bool, count: () throws -> Int) async throws -> Int {
        // Muse's box label never shows its text and drops "Send" in some states
        // (09-22: User's main chat read "Message Attach file Dictate a message"),
        // so no draft check here: select-all + paste in her own chat replaces it.
        _ = try composer()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Blocker.offline }
        // Let the person's typing finish (up to ~5s) so it can't land in Muse.
        for _ in 0..<25 where CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 2 {
            try await Task.sleep(for: .milliseconds(200))
        }
        try unlocked()
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let before: Int
        do { before = try await typeInFront(message, chat: chat, reopen: reopen, count: count, app: app) } catch { await restore(previous, from: app); throw error }
        await restore(previous, from: app)
        return before
    }

    private static func restore(_ previous: NSRunningApplication?, from app: NSRunningApplication) async {
        guard let previous, !previous.isTerminated, previous.processIdentifier != app.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let url = previous.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func typeInFront(_ message: String, chat: String, reopen: Bool, count: () throws -> Int, app: NSRunningApplication) async throws -> Int {
        func front() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        func click(_ node: AXUIElement) throws {
            let frame = try frame(of: node)
            let point = CGPoint(x: frame.minX + frame.width * 0.35, y: frame.midY)
            let events = try [CGEventType.leftMouseDown, .leftMouseUp].map { type -> CGEvent in
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw Blocker.typing }
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                return event
            }
            for event in events {
                guard front() else { throw Blocker.window }
                event.post(tap: .cghidEventTap)
            }
        }
        do { try await until(seconds: 4) { front() } } catch { throw Blocker.window }
        if reopen {
            // Only ever her own entry in the side-chat list; never the main chat.
            let entries = try sideChatEntries(named: chat)
            guard entries.count == 1 else { throw Blocker.thread }
            try click(entries[0])
            // 09-22: wait for her log too, so the baseline below counts her rows, not a half-loaded log's.
            do { try await until(seconds: 5) { try openTitle() == chat && !turns().isEmpty } } catch { throw Blocker.thread }
        }
        // Activation can change the window: recheck her chat and an empty box before any input.
        guard openTitle() == chat else { throw Blocker.thread }
        // 09-22: baseline taken here, in her chat; counted in whatever chat was open
        // before the reopen, an older same-prefix row of hers could confirm as new.
        let before = try count()
        // Muse never exposes the box's text (its label stays "Message …"), so a
        // draft can't be seen; this is her own side chat, so select-all + paste
        // replaces whatever is in her box. Delivery is proven after Return by
        // her "User message:" row appearing (see send()).
        // Muse ignores postToPid key events (09-22 live test), so keys use the
        // HID tap with Muse re-checked frontmost immediately before each one.
        func keys(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
            for event in try AX.keyEvents(code, flags: flags) {
                guard front() else { throw Blocker.typing }
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
        guard openTitle() == chat else { throw Blocker.thread }
        try keys(0, flags: .maskCommand)   // select all in her box
        try keys(9, flags: .maskCommand)   // paste
        try await Task.sleep(for: .milliseconds(400))
        guard openTitle() == chat else { throw Blocker.thread }
        try keys(36)
        try await Task.sleep(for: .milliseconds(300))
        return before
    }

    /// First use: wait briefly for Muse to name the new chat. Every exchange
    /// returns the title the chat shows now (2026-09-22: Muse renames chats
    /// after the first minutes, and a stale saved title broke the next send).
    static func settledTitle(_ thread: String?) async throws -> String {
        if thread == nil { try? await until(seconds: 8) { (openTitle() ?? untitled) != untitled } }
        return openTitle() ?? thread ?? untitled
    }

    // MARK: - Reading the window

    struct Turn { let user: Bool; let text: String }

    /// Keys and paste on a locked Mac would go to the lock screen's password field.
    static func unlocked() throws {
        // Fail closed: no session dictionary, or no proof it is on console and unlocked, sends nothing.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { throw Blocker.locked }
    }

    static func windows() throws -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Blocker.offline }
        return AX.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func hasLog(_ window: AXUIElement) -> Bool { walk(window).contains { AX.string($0, kAXTitleAttribute) == Muse.log } }

    /// The window holding the chat log (09-22: a Settings window beside it failed as "signed out").
    static func window() throws -> AXUIElement {
        let all = try windows()
        if all.count == 1 { return all[0] }
        guard let chat = all.first(where: hasLog) else { throw Blocker.window }
        return chat
    }

    /// A minimized chat takes no clicks, and a closed one has nothing to click:
    /// un-minimize it, or reopen the app to bring its window back.
    static func showWindow() async throws {
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
        do { try await until(seconds: 8) { try windows().contains(where: hasLog) } } catch { throw Blocker.window }
    }

    static func children(_ node: AXUIElement) -> [AXUIElement] {
        AX.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// The window's elements without descending into the message log: a long
    /// chat otherwise exhausts a bounded walk before the side-chat controls
    /// (09-22: User's main chat hid "New side chat"). The log node itself is kept.
    static func walk(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 4000 {
            let node = queue.removeFirst(); result.append(node)
            if AX.string(node, kAXTitleAttribute) == Muse.log { continue }
            queue.append(contentsOf: children(node))
        }
        return result
    }

    static func buttons(_ match: (AXUIElement) -> Bool) throws -> [AXUIElement] {
        walk(try window()).filter { AX.string($0, kAXRoleAttribute) == kAXButtonRole && match($0) }
    }

    static func composer() throws -> (title: String, node: AXUIElement) {
        // While Muse replies its Send button reads "Stop", so match the stable part.
        let boxes = try buttons { AX.string($0, kAXTitleAttribute).contains(Muse.composerCore) }
        guard boxes.count == 1 else { throw Blocker.window }
        return (AX.string(boxes[0], kAXTitleAttribute), boxes[0])
    }

    static func frame(of node: AXUIElement) throws -> CGRect {
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
    /// else the panel entry Muse marks current.
    static func openTitle() -> String? {
        if let title = headerTitle() { return title }
        guard let panel = try? sideChatsPanel() else { return nil }
        return AX.nodes(panel).first { AX.string($0, Muse.current) == Muse.currentValue }
            .map { entryTitle(AX.string($0, kAXTitleAttribute)) }
    }

    /// An entry's chat title without Muse's status words.
    static func entryTitle(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(Muse.unreadSuffix) { return String(text.dropLast(Muse.unreadSuffix.count)) }
        if text.hasSuffix(Muse.actionsSuffix) {
            text = String(text.dropLast(Muse.actionsSuffix.count))
            // Drop the age token ("18m", "2h", "3d") that precedes the actions label.
            if let space = text.lastIndex(of: " ") { text = String(text[..<space]) }
        }
        return text
    }

    static func headerTitle() -> String? {
        guard let back = try? buttons({ AX.string($0, kAXTitleAttribute) == Muse.backToMain }).first,
              let row = AX.parent(back) else { return nil }
        let siblings = children(row)
        guard let index = siblings.firstIndex(where: { CFEqual($0, back) }) else { return nil }
        return siblings[(index + 1)...].first { AX.string($0, kAXRoleAttribute) == kAXStaticTextRole }
            .map { AX.string($0, kAXValueAttribute) }
    }

    static func sideChatsPanel() throws -> AXUIElement? {
        walk(try window()).first { AX.string($0, kAXSubroleAttribute) == "AXLandmarkNavigation" && AX.string($0, kAXTitleAttribute) == Muse.chatsPanel }
    }

    /// The deepest pressable entries in the side-chat list that carry exactly this title.
    static func sideChatEntries(named title: String) throws -> [AXUIElement] {
        guard let panel = try sideChatsPanel() else { return [] }
        func pressable(_ node: AXUIElement) -> Bool {
            var names: CFArray?
            return AXUIElementCopyActionNames(node, &names) == .success && (names as? [String] ?? []).contains(kAXPressAction)
        }
        func labelled(_ node: AXUIElement) -> Bool {
            AX.nodes(node).contains { item in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { key in
                let label = AX.string(item, key).trimmingCharacters(in: .whitespacesAndNewlines)
                // Muse appends a status to unread entries: "<title> Unread updates".
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
    static func turns() throws -> [Turn] {
        guard let log = walk(try window()).first(where: { AX.string($0, kAXTitleAttribute) == Muse.log }) else { throw Blocker.window }
        return children(log).compactMap { child in
            if AX.string(child, kAXRoleAttribute) == kAXStaticTextRole {
                let value = AX.string(child, kAXValueAttribute)
                if value.hasPrefix(Muse.userPrefix) { return Turn(user: true, text: String(value.dropFirst(Muse.userPrefix.count))) }
                if value.hasPrefix(Muse.assistantPrefix) { return Turn(user: false, text: String(value.dropFirst(Muse.assistantPrefix.count))) }
                return nil
            }
            let kids = children(child)
            if let first = kids.first, AX.string(first, kAXValueAttribute) == Muse.userLabel {
                return Turn(user: true, text: kids.dropFirst().flatMap(texts).joined(separator: "\n"))
            }
            guard AX.nodes(child).contains(where: { AX.string($0, kAXTitleAttribute) == Muse.assistantMarker }) else { return nil }
            let body = texts(child)
            return body.isEmpty ? nil : Turn(user: false, text: body.joined(separator: "\n"))
        }
    }

    /// Depth-first in reading order: breadth-first with a 1,500-node cap
    /// shuffled and cut long answers (09-22). The cap is only a safety bound.
    static func texts(_ node: AXUIElement) -> [String] {
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

    static func generating() -> Bool {
        // While answering, the composer's label ends in " Stop" rather than starting with it.
        if (try? composer().title.hasSuffix(" " + Muse.stop)) == true { return true }
        return (try? buttons { button in [kAXTitleAttribute, kAXDescriptionAttribute].contains { AX.string(button, $0).hasPrefix(Muse.stop) } }.isEmpty == false) ?? false
    }

    /// True only when the chat's first user turn is exactly this saved first message.
    static func opensWith(_ turns: [Turn], _ first: String?) -> Bool {
        guard let first, let opener = turns.first(where: \.user) else { return false }
        return flat(opener.text) == flat(first)
    }

    static func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func until(seconds: Double, _ ready: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? ready()) == true { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Blocker.submission
    }

    static func ensureRunning() async -> Bool {
        func running() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
        if running() { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 where !running() { try? await Task.sleep(nanoseconds: 500_000_000) }
        if running() { try? await Task.sleep(nanoseconds: 4_000_000_000) }
        return running()
    }
}
