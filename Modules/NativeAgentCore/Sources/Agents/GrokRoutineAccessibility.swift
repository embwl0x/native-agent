import GrokLink
import AppKit
import os
import ApplicationServices
import ChatOrchestration
import MacControl
import NativeAgentCore
import PersistenceCore

/// Passive peer reads share a serial lane; no AX handles leave a read.
public enum DesktopPeerReadLane {
    private static let queue = DispatchQueue(label: "NativeAgent.desktop-peer-reads", qos: .utility)

    public static func read<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return value
    }
}

/// Native-only secret transfer. AX values never cross a model, screenshot,
/// tool result, clipboard, log, approval preview or transcript boundary.
@MainActor public enum GrokRoutineAccessibility {
    public enum Blocker: String, Error {
        case offline = "Grok Bot desktop app not running."
        case permission = "Allow NativeAgent Accessibility access to set up the Grok Bot routine."
        case conversation = "Grok Bot does not expose one unambiguous current chat and empty composer. Open the intended chat with no draft, then Connect again."
        case submission = "Routine request submission is unconfirmed. Check Grok Bot; this app will not resend it automatically."
        case accessibility = "Grok Bot's web Accessibility tree could not be enabled or read. Check NativeAgent Accessibility access, then Connect again."
        case mainBot = "Grok Bot's main sidebar chat could not be selected unambiguously. Close any open routine panel, then Connect again."
        case details = "Grok Bot's Details tab could not be selected unambiguously. Check the main Grok Bot chat, then Connect again."
        case routines = "Grok Bot's Details tab did not expose one Routines section. Check Grok Bot, then Connect again."
        case routine = "Grok Bot's NativeAgent reply routine row could not be opened unambiguously. Check Routines for duplicate names, then Connect again."
        case secrets = "Grok Bot's Routines panel did not expose one unambiguous webhook URL and readable key through Accessibility. Close any open routine panel before sending a setup or cleanup request."
        case missingRoutine = "The NativeAgent reply routine is missing from Grok Bot's Routines panel."
        case cleanup = "Grok Bot's routine panel could not be closed. Close it before continuing."
    }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).isEmpty }
    /// Opens Grok Bot when it is closed and waits for it to be up, so a person
    /// never has to launch it first.
    public static func ensureRunning() async -> Bool {
        if running { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 where !running { try? await Task.sleep(nanoseconds: 500_000_000) }
        if running { try? await Task.sleep(nanoseconds: 4_000_000_000) }
        return running
    }
    nonisolated public static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    nonisolated public static func string(_ node: AXUIElement, _ name: String) -> String {
        attribute(node, name) as? String ?? ""
    }
    nonisolated static func label(_ node: AXUIElement) -> String {
        let title = string(node, kAXTitleAttribute)
        if !title.isEmpty { return title }
        return string(node, string(node, kAXRoleAttribute) == kAXStaticTextRole ? kAXValueAttribute : kAXDescriptionAttribute)
    }
    nonisolated public static func parent(_ node: AXUIElement) -> AXUIElement? {
        guard let value = attribute(node, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    nonisolated public static func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 1500 {
            let node = queue.removeFirst(); result.append(node)
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            queue.append(contentsOf: children.prefix(1500 - result.count))
        }
        return result
    }
    public static func window() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw Blocker.permission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { throw Blocker.offline }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard windows.count == 1 else { step("Grok Bot shows \(windows.count) windows, not one"); throw Blocker.conversation }
        return windows[0]
    }
    static func currentConversation() throws -> String {
        // Seen on the installed app (09-19 drive): the window is always titled
        // "Grok Bot", whichever Bot is open. The open Bot is the conversation.
        let selected = nodes(try window()).filter {
            string($0, kAXRoleAttribute) == kAXButtonRole
                && (attribute($0, kAXSelectedAttribute) as? Bool) == true
        }
        // The installed app marks no sidebar button as selected (09-20). The
        // open chat is the conversation; its name is only a label for the person.
        guard selected.count == 1 else { return "Grok Bot" }
        let name = label(selected[0])
        return name.isEmpty ? "Grok Bot" : name
    }
    /// Seen on the installed app (09-20): the box has no placeholder attribute;
    /// an empty box reports "Message <chat name>" as its value. Match only the
    /// verified destination's exact placeholder, never a generic prose prefix.
    static func isEmptyBox(_ value: String, conversation: String = "grok") -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (!conversation.isEmpty && text == "Message " + conversation)
            || ["Ask anything", "Ask anything…", "Ask anything..."].contains(text)
    }
    /// Grok Bot builds its accessibility tree only while it is in front and has
    /// been told a reader is present. Every read of its window starts here.
    static let log = Logger(subsystem: "NativeAgent", category: "GrokBot")
    /// Which check stopped setup: the one message the person sees covers six.
    /// The last one is kept so a desktop send can name it.
    static func step(_ name: String) { lastStep = name; log.error("grok setup stopped at \(name, privacy: .public)") }
    static var lastStep: String?
    /// How far the last send got. Before `.typing` nothing reached the box, so
    /// sending again is safe; from `.submitted` on, Return was pressed.
    enum SendStage { case opening, conversation, typing, submitted }
    static var reached = SendStage.opening
    /// Read just before the paste, with Grok in front: how many user turns
    /// already carry this exact text (the reply watch takes the answer after
    /// the next one only), and where the transcript sits in the window (the
    /// passive read behind other windows looks only there).
    static var sentLayout: GrokDesktopReply.Layout?
    static func awake() async throws -> NSRunningApplication {
        guard await ensureRunning(),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) else { throw Blocker.offline }
        guard AXIsProcessTrusted() else { throw Blocker.permission }
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first,
              AXUIElementSetAttributeValue(AXUIElementCreateApplication(runningApp.processIdentifier),
                  "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success else { throw Blocker.accessibility }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        do { try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier } }
        catch { step("Grok Bot never came to the front"); throw error }
        do { try await waitUntil { try nodes(window()).contains { string($0, kAXRoleAttribute) == "AXWebArea" } } }
        catch { throw Blocker.accessibility }
        return app
    }
    /// No model-driven screen access while a secret-bearing panel is open.
    static func requireChatOnly() throws {
        // The secret-bearing panel shows its values in text fields; a chat
        // message that merely says "key" or carries a link is not that panel.
        let tree = nodes(try window()).filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }
        guard !tree.contains(where: { node in
            let labels = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { string(node, $0).lowercased() }
            return labels.contains { $0 == "post to" || $0 == "key" || $0 == "webhook key" || $0.hasPrefix("https://") }
        }) else { step("a routine panel showing its webhook values is open"); throw Blocker.secrets }
    }
    static func isCurrentBotChat(_ bot: String) throws -> Bool {
        try nodes(window()).contains { string($0, kAXRoleAttribute) == "AXHeading"
            && (string($0, kAXTitleAttribute) == bot || string($0, kAXDescriptionAttribute) == bot) }
    }
    static func prepareConversation(bot: String) throws -> AXUIElement {
        try requireChatOnly()
        guard try isCurrentBotChat(bot) else { step("chat \"\(bot)\" is not the open chat"); throw Blocker.conversation }
        let tree = nodes(try window())
        let boxes = tree.filter { string($0, kAXRoleAttribute) == kAXTextAreaRole
            && string($0, kAXDescriptionAttribute).lowercased() == "prompt" }
        guard boxes.count == 1 else {
            step("found \(boxes.count) message boxes, not one"); throw Blocker.conversation
        }
        guard let value = attribute(boxes[0], kAXValueAttribute) as? String else {
            step("the message box's text could not be read"); throw Blocker.conversation
        }
        guard isEmptyBox(value, conversation: bot) else {
            step("the message box already holds a draft, left untouched"); throw Blocker.conversation
        }
        return boxes[0]
    }
    static func centre(_ node: AXUIElement) throws -> CGPoint {
        guard let position = attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { throw Blocker.conversation }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { throw Blocker.conversation }
        return CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
    }
    static func clickEvents(at point: CGPoint) throws -> [CGEvent] {
        try [CGEventType.leftMouseDown, .leftMouseUp].map {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: $0, mouseCursorPosition: point, mouseButton: .left) else { throw Blocker.submission }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: NativeAgentMacEventIdentity.sourceUserData)
            return event
        }
    }
    public static func keyEvents(_ key: CGKeyCode, flags: CGEventFlags = []) throws -> [CGEvent] {
        try [true, false].map {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: $0) else { throw Blocker.submission }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: NativeAgentMacEventIdentity.sourceUserData)
            return event
        }
    }
    public static func copyPasteboard(_ pasteboard: NSPasteboard) throws -> [NSPasteboardItem] {
        try (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { throw Blocker.submission }
            }
            return copy
        }
    }
    /// Bounded observation only; actions are never retried.
    static func waitUntil(_ ready: () throws -> Bool) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if try ready() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Blocker.submission
    }
    /// Seen on the installed app (09-20): a routine can only be created in the
    /// 1:1 chat with a Bot ("needs Auto-review, which this bridge room can't
    /// do"). The sidebar lists that chat as a button titled with the Bot's name,
    /// or "<name>, Unread activity"; once open, the heading is the name.
    static func openBotChat(_ bot: String) async throws {
        func heading() throws -> Bool {
            try isCurrentBotChat(bot)
        }
        if try heading() { return }
        let chats = nodes(try window()).filter {
            guard string($0, kAXRoleAttribute) == kAXButtonRole else { return false }
            let title = label($0)
            return title == bot || title.hasPrefix(bot + ", ")
        }
        guard chats.count == 1, AXUIElementPerformAction(chats[0], kAXPressAction as CFString) == .success else {
            step("chat \"\(bot)\" matched \(chats.count) sidebar entries, not one"); throw Blocker.conversation
        }
        do { try await waitUntil { try heading() } } catch { step("chat \"\(bot)\" did not open"); throw Blocker.conversation }
    }
    static func send(_ text: String, bot: String, watchReply: Bool = false) async throws {
        guard !text.isEmpty else { throw Blocker.submission }
        reached = .opening; lastStep = nil; sentLayout = nil
        let previous = NSWorkspace.shared.frontmostApplication
        do {
            try await sendInForeground(text, bot: bot, watchReply: watchReply, previous: previous)
        } catch {
            await GrokDesktopReply.abandon(sentLayout?.watchID)
            await restoreForeground(previous)
            throw error
        }
        if sentLayout?.watchID == nil { await restoreForeground(previous) }
    }
    /// Workspace activation works from a background app where activate() can be
    /// ignored. Await cleanup on success and failure; never steal focus back
    /// after the person has switched to another application during setup.
    static func restoringForeground(_ operation: () async throws -> Void) async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        do {
            try await operation()
        } catch {
            await restoreForeground(previous)
            throw error
        }
        await restoreForeground(previous)
    }
    static func shouldRestoreForeground(previousPID: pid_t?, previousTerminated: Bool,
                                        currentPID: pid_t?, currentBundleID: String?) -> Bool {
        previousPID != nil && !previousTerminated && previousPID != currentPID
            && currentBundleID == GrokBotRoute.bundleID
    }
    static func restoreForeground(_ previous: NSRunningApplication?) async {
        let current = NSWorkspace.shared.frontmostApplication
        guard shouldRestoreForeground(previousPID: previous?.processIdentifier,
                                      previousTerminated: previous?.isTerminated ?? true,
                                      currentPID: current?.processIdentifier,
                                      currentBundleID: current?.bundleIdentifier),
              let url = previous?.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    private static func sendInForeground(_ text: String, bot: String, watchReply: Bool, previous: NSRunningApplication?) async throws {
        let app = try await awake()
        reached = .conversation
        func requireFrontmost() throws {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                step("another app (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) took the front"); throw Blocker.submission
            }
        }
        try await openBotChat(bot)
        let box = try prepareConversation(bot: bot)
        let click = try clickEvents(at: centre(box))
        let paste = try keyEvents(9, flags: .maskCommand)
        let submit = try keyEvents(36)
        try requireFrontmost()
        click.forEach { NativeAgentMotorEpoch.notePostedHIDEvent(); $0.post(tap: .cghidEventTap) }
        do {
            try await waitUntil {
                try requireFrontmost()
                return (attribute(box, kAXFocusedAttribute) as? Bool) == true
            }
        } catch { step("the message box never took focus"); throw error }
        // Recheck after focus: never replace a draft or paste into a changed chat.
        guard CFEqual(box, try prepareConversation(bot: bot)) else { step("the message box changed after focus"); throw Blocker.conversation }
        guard let baseline = GrokDesktopReply.outgoingOccurrences(text, chat: bot) else { throw Blocker.conversation }
        sentLayout = GrokDesktopReply.layout(text, chat: bot)
        let pasteboard = NSPasteboard.general
        let saved = try copyPasteboard(pasteboard)
        pasteboard.clearContents()
        var ours = pasteboard.changeCount
        defer {
            // Only put the person's clipboard back if nothing new was copied meanwhile.
            if pasteboard.changeCount == ours {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        guard pasteboard.setString(text, forType: .string) else { throw Blocker.submission }
        ours = pasteboard.changeCount
        try requireFrontmost()
        reached = .typing
        paste.forEach { NativeAgentMotorEpoch.notePostedHIDEvent(); $0.post(tap: .cghidEventTap) }
        do { try await waitUntil {
            try requireFrontmost()
            // The box reports the pasted text with its own trailing newline.
            let value = (attribute(box, kAXValueAttribute) as? String) ?? ""
            func flat(_ t: String) -> String { t.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            return !isEmptyBox(value, conversation: bot) && flat(value) == flat(text)
        } } catch { step("the pasted text never appeared in the message box"); throw error }
        try requireFrontmost()
        if watchReply, let layout = sentLayout {
            sentLayout?.watchID = try GrokDesktopReply.start(message: text, chat: bot, layout: layout, previous: previous)
        }
        reached = .submitted
        submit.forEach { NativeAgentMotorEpoch.notePostedHIDEvent(); $0.post(tap: .cghidEventTap) }
        do { try await verifySubmission(text, bot: bot, baseline: baseline) }
        catch { step("Return was pressed, but the message was not seen in the chat"); throw Blocker.submission }
    }
    static func verifySubmission(_ message: String, bot: String, baseline: Int) async throws {
        for _ in 0..<20 {
            guard try isCurrentBotChat(bot) else { throw Blocker.conversation }
            let tree = nodes(try window())
            let boxes = tree.filter { string($0, kAXRoleAttribute) == kAXTextAreaRole
                && string($0, kAXDescriptionAttribute).lowercased() == "prompt" }
            if boxes.count == 1, let value = attribute(boxes[0], kAXValueAttribute) as? String,
               isEmptyBox(value, conversation: bot),
               let count = GrokDesktopReply.outgoingOccurrences(message, chat: bot), count > baseline { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Blocker.submission
    }
    static func importRoutine(peer: String, dataRoot: URL, waitForCreation: Bool) async throws {
        try await restoringForeground {
            do { try await importRoutineInForeground(peer: peer, dataRoot: dataRoot, waitForCreation: waitForCreation) }
            catch {
                guard await closeRoutinePanel() else { throw Blocker.cleanup }
                throw error
            }
            guard await closeRoutinePanel() else { throw Blocker.cleanup }
        }
    }
    private static func closeRoutinePanel() async -> Bool {
        // This bounded cleanup has its own cancellation lifetime so a canceled
        // import still hides the credential fields before restoring focus.
        await Task { @MainActor in
            for _ in 0..<6 {
                guard let window = try? window() else { return !running }
                let tree = nodes(window)
                @MainActor func button(_ name: String) -> AXUIElement? {
                    let found = tree.filter {
                        string($0, kAXRoleAttribute) == kAXButtonRole
                            && label($0) == name
                    }
                    return found.count == 1 ? found[0] : nil
                }
                let routineOpen = tree.contains { string($0, kAXRoleAttribute) == "AXHeading" && label($0).hasPrefix("NativeAgent reply ") }
                    || (try? requireChatOnly()) == nil
                let control = button("Back to Routines") ?? button("Back to details") ?? button("Close details")
                    ?? (routineOpen ? button("Close") : nil)
                if let control { _ = AXUIElementPerformAction(control, kAXPressAction as CFString) }
                else if (try? requireChatOnly()) != nil {
                    // An import may have scrolled the chat back to its routine link.
                    if let bottom = button("Scroll to bottom") { _ = AXUIElementPerformAction(bottom, kAXPressAction as CFString) }
                    return true
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            step("the routine panel could not be closed")
            return false
        }.value
    }
    private static func importRoutineInForeground(peer: String, dataRoot: URL, waitForCreation: Bool) async throws {
        _ = try await awake()
        // A routine panel left open is closed first rather than stopping setup.
        if (try? requireChatOnly()) == nil {
            guard await closeRoutinePanel() else { throw Blocker.cleanup }
        }
        do { try await openBotChat("Grok Bot") } catch { throw Blocker.mainBot }
        try AgentPeerStore(dataRoot: dataRoot).updateGrok(peer) { $0.grokConversation = "Grok Bot" }
        func section() throws -> AXUIElement? {
            let found = nodes(try window()).filter {
                [kAXListRole, kAXGroupRole, "AXHeading", kAXStaticTextRole].contains(string($0, kAXRoleAttribute)) && label($0) == "Routines"
                    && !(parent($0).map { label($0) == "Routines" } ?? false)
            }
            // The heading text and the list both say "Routines"; the list is the section.
            let lists = found.filter { string($0, kAXRoleAttribute) == kAXListRole }
            let picked = lists.count == 1 ? lists : found
            guard picked.count <= 1 else { throw Blocker.routines }
            guard let node = picked.first else { return nil }
            return [kAXListRole, kAXGroupRole].contains(string(node, kAXRoleAttribute)) ? node : parent(node)
        }
        func field(_ tree: [AXUIElement], _ name: String) -> String? {
            let found = tree.filter { string($0, kAXRoleAttribute) == kAXTextFieldRole && label($0) == name }
            guard found.count == 1, let value = attribute(found[0], kAXValueAttribute) as? String, !value.isEmpty else { return nil }
            return value
        }
        func press(_ node: AXUIElement) -> Bool { AXUIElementPerformAction(node, kAXPressAction as CFString) == .success }
        let routine = GrokBotRoute.routineName(peer)
        // Grok's own chat links the routine it created; that button is unambiguous.
        // Its Details row no longer opens on press, and later messages push the
        // link out of the tree, so scroll the chat back until it renders.
        func link() throws -> AXUIElement? {
            let found = nodes(try window()).filter { string($0, kAXRoleAttribute) == kAXButtonRole && label($0) == "Open routine " + routine }
            return found.count == 1 ? found[0] : nil
        }
        var found = try link()
        if found == nil, let box = nodes(try window()).first(where: {
            string($0, kAXRoleAttribute) == kAXTextAreaRole && string($0, kAXDescriptionAttribute).lowercased() == "prompt"
        }) {
            let below = try centre(box)
            let point = CGPoint(x: below.x, y: below.y - 200)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                move.setIntegerValueField(.eventSourceUserData, value: NativeAgentMacEventIdentity.sourceUserData)
                NativeAgentMotorEpoch.notePostedHIDEvent(); move.post(tap: .cghidEventTap)
            }
            for _ in 0..<40 {
                guard found == nil, let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 600, wheel2: 0, wheel3: 0) else { break }
                wheel.setIntegerValueField(.eventSourceUserData, value: NativeAgentMacEventIdentity.sourceUserData)
                NativeAgentMotorEpoch.notePostedHIDEvent(); wheel.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(300))
                found = try link()
            }
        }
        if !(found.map(press) ?? false) {
            let tabs = nodes(try window()).filter {
                [kAXButtonRole, kAXRadioButtonRole, "AXTab"].contains(string($0, kAXRoleAttribute)) && label($0) == "Details"
            }
            guard tabs.count == 1, press(tabs[0]) else { throw Blocker.details }
            do { try await waitUntil { try section() != nil } } catch { throw Blocker.routines }
            // A newly requested routine is asynchronous: Grok Bot took about a
            // minute to create one. Look for up to two minutes.
            var rows: [AXUIElement] = []
            for _ in 0..<(waitForCreation ? 120 : 1) {
                try Task.checkCancellation()
                guard let list = try section() else { throw Blocker.routines }
                let tree = nodes(list)
                guard tree.count < 1500 else { throw Blocker.routines }
                let titles = tree.filter { label($0) == routine || label($0).hasPrefix(routine + " ") || label($0).hasPrefix(routine + "\n") }
                for title in titles {
                    var node: AXUIElement? = title
                    while let candidate = node, !CFEqual(candidate, list) {
                        var actions: CFArray?
                        if [kAXButtonRole, kAXRowRole, kAXGroupRole].contains(string(candidate, kAXRoleAttribute)),
                           AXUIElementCopyActionNames(candidate, &actions) == .success,
                           (actions as? [String] ?? []).contains(kAXPressAction) {
                            if !rows.contains(where: { CFEqual($0, candidate) }) { rows.append(candidate) }
                            break
                        }
                        node = parent(candidate)
                    }
                    guard let node, !CFEqual(node, list) else { throw Blocker.routine }
                }
                guard rows.count <= 1 else { throw Blocker.routine }
                if !rows.isEmpty { break }
                if !waitForCreation { throw Blocker.missingRoutine }
                try await Task.sleep(for: .seconds(1))
            }
            guard let row = rows.first else { throw Blocker.missingRoutine }
            guard press(row) else { throw Blocker.routine }
        }
        var url: String?, key: String?
        do { try await waitUntil {
            let tree = nodes(try window())
            // The updated panel has no heading named after the routine; its Delete button marks it.
            guard tree.contains(where: { string($0, kAXRoleAttribute) == kAXButtonRole && label($0) == "Delete routine" }) else { return false }
            url = field(tree, "Webhook URL"); key = field(tree, "Webhook key")
            return url != nil && key != nil
        } } catch { throw Blocker.secrets }
        guard let url, let key else { throw Blocker.secrets }
        try AgentPeerStore(dataRoot: dataRoot).updateGrok(peer) { contact in
            var credential = try GrokLinkCredential.read(peer: peer)
            try credential.importWebhook(url: url, key: key)
            try credential.write(peer: peer)
            contact.grokSetup = "set up"
            contact.grokBootstrapConfirmed = true
        }
    }
}
