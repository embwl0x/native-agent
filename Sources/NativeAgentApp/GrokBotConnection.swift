import AppKit
import os
import ApplicationServices
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// Native-only secret transfer. AX values never cross a model, screenshot,
/// tool result, clipboard, log, approval preview or transcript boundary.
@MainActor enum GrokRoutineAccessibility {
    enum Blocker: String, Error {
        case offline = "Grok Bot desktop app not running."
        case permission = "Allow NativeAgent Accessibility access to set up the Grok Bot routine."
        case conversation = "Grok Bot does not expose one unambiguous current chat and empty composer. Open the intended chat with no draft, then Connect again."
        case submission = "Routine request submission is unconfirmed. Check Grok Bot; this app will not resend it automatically."
        case secrets = "Grok Bot's Routines panel did not expose one unambiguous webhook URL and readable key through Accessibility. Close any open routine panel before sending a setup or cleanup request."
    }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).isEmpty }
    /// Opens Grok Bot when it is closed and waits for it to be up, so a person
    /// never has to launch it first.
    static func ensureRunning() async -> Bool {
        if running { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 where !running { try? await Task.sleep(nanoseconds: 500_000_000) }
        if running { try? await Task.sleep(nanoseconds: 4_000_000_000) }
        return running
    }
    static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ node: AXUIElement, _ name: String) -> String {
        attribute(node, name) as? String ?? ""
    }
    static func parent(_ node: AXUIElement) -> AXUIElement? {
        guard let value = attribute(node, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    static func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 1500 {
            let node = queue.removeFirst(); result.append(node)
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            queue.append(contentsOf: children.prefix(1500 - result.count))
        }
        return result
    }
    static func window() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw Blocker.permission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { throw Blocker.offline }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement],
              windows.count == 1 else { throw Blocker.conversation }
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
        let name = string(selected[0], kAXTitleAttribute).isEmpty
            ? string(selected[0], kAXDescriptionAttribute) : string(selected[0], kAXTitleAttribute)
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
    static func step(_ name: String) { log.error("grok setup stopped at \(name, privacy: .public)") }
    static func awake() async throws -> NSRunningApplication {
        guard await ensureRunning(),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) else { throw Blocker.offline }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        do { try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier } }
        catch { step("awake: Grok Bot never became frontmost"); throw error }
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for _ in 0..<3 {
            if (try? await waitUntil { try nodes(window()).contains { string($0, kAXRoleAttribute) == "AXWebArea" } }) != nil { return app }
        }
        step("awake: no web area in the window (AX tree not readable)")
        throw Blocker.conversation
    }
    /// No model-driven screen access while a secret-bearing panel is open.
    static func requireChatOnly() throws {
        // The secret-bearing panel shows its values in text fields; a chat
        // message that merely says "key" or carries a link is not that panel.
        let tree = nodes(try window()).filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }
        guard !tree.contains(where: { node in
            let labels = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { string(node, $0).lowercased() }
            return labels.contains { $0 == "post to" || $0 == "key" || $0 == "webhook key" || $0.hasPrefix("https://") }
        }) else { throw Blocker.secrets }
    }
    static func isCurrentBotChat(_ bot: String) throws -> Bool {
        try nodes(window()).contains { string($0, kAXRoleAttribute) == "AXHeading"
            && (string($0, kAXTitleAttribute) == bot || string($0, kAXDescriptionAttribute) == bot) }
    }
    static func prepareConversation(bot: String) throws -> AXUIElement {
        try requireChatOnly()
        guard try isCurrentBotChat(bot) else { throw Blocker.conversation }
        let tree = nodes(try window())
        let boxes = tree.filter { string($0, kAXRoleAttribute) == kAXTextAreaRole
            && string($0, kAXDescriptionAttribute).lowercased() == "prompt" }
        guard boxes.count == 1 else {
            step("prepare: prompt box count \(boxes.count)"); throw Blocker.conversation
        }
        guard let value = attribute(boxes[0], kAXValueAttribute) as? String else {
            step("prepare: prompt value unavailable, box count \(boxes.count)"); throw Blocker.conversation
        }
        guard isEmptyBox(value, conversation: bot) else {
            step("prepare: prompt not empty, box count \(boxes.count)"); throw Blocker.conversation
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
            return event
        }
    }
    static func keyEvents(_ key: CGKeyCode, flags: CGEventFlags = []) throws -> [CGEvent] {
        try [true, false].map {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: $0) else { throw Blocker.submission }
            event.flags = flags
            return event
        }
    }
    static func copyPasteboard(_ pasteboard: NSPasteboard) throws -> [NSPasteboardItem] {
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
            let title = string($0, kAXTitleAttribute).isEmpty ? string($0, kAXDescriptionAttribute) : string($0, kAXTitleAttribute)
            return title == bot || title.hasPrefix(bot + ", ")
        }
        guard chats.count == 1, AXUIElementPerformAction(chats[0], kAXPressAction as CFString) == .success else { throw Blocker.conversation }
        do { try await waitUntil { try heading() } } catch { throw Blocker.conversation }
    }
    static func send(_ text: String, bot: String) async throws {
        guard !text.isEmpty else { throw Blocker.submission }
        try await restoringForeground { try await sendInForeground(text, bot: bot) }
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
    private static func restoreForeground(_ previous: NSRunningApplication?) async {
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
    private static func sendInForeground(_ text: String, bot: String) async throws {
        let app = try await awake()
        func requireFrontmost() throws {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                step("frontmost lost to \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")"); throw Blocker.submission
            }
        }
        try await openBotChat(bot)
        let box = try prepareConversation(bot: bot)
        let click = try clickEvents(at: centre(box))
        let paste = try keyEvents(9, flags: .maskCommand)
        let submit = try keyEvents(36)
        try requireFrontmost()
        click.forEach { $0.post(tap: .cghidEventTap) }
        do {
            try await waitUntil {
                try requireFrontmost()
                return (attribute(box, kAXFocusedAttribute) as? Bool) == true
            }
        } catch { step("message box never took focus after click"); throw error }
        // Recheck after focus: never replace a draft or paste into a changed chat.
        guard CFEqual(box, try prepareConversation(bot: bot)) else { step("box changed after focus"); throw Blocker.conversation }
        let pasteboard = NSPasteboard.general
        let saved = try copyPasteboard(pasteboard)
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        guard pasteboard.setString(text, forType: .string) else { throw Blocker.submission }
        try requireFrontmost()
        paste.forEach { $0.post(tap: .cghidEventTap) }
        do { try await waitUntil {
            try requireFrontmost()
            // The box reports the pasted text with its own trailing newline.
            let value = (attribute(box, kAXValueAttribute) as? String) ?? ""
            func flat(_ t: String) -> String { t.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            return !isEmptyBox(value, conversation: bot) && flat(value).contains(String(flat(text).prefix(40)))
        } } catch { step("pasted text never appeared in the box"); throw error }
        try requireFrontmost()
        submit.forEach { $0.post(tap: .cghidEventTap) }
        do { try await verifySubmission(text, bot: bot) }
        catch { step("sent, but the message was not seen in the chat (\(error))"); throw Blocker.submission }
    }
    static func verifySubmission(_ message: String, bot: String) async throws {
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        for _ in 0..<20 {
            guard try isCurrentBotChat(bot) else { throw Blocker.conversation }
            let tree = nodes(try window())
            let boxes = tree.filter { string($0, kAXRoleAttribute) == kAXTextAreaRole
                && string($0, kAXDescriptionAttribute).lowercased() == "prompt" }
            let visible = tree.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }
                .map { string($0, kAXValueAttribute) }
            if boxes.count == 1, let value = attribute(boxes[0], kAXValueAttribute) as? String,
               isEmptyBox(value, conversation: bot), visible.contains(where: { normalized($0).contains(normalized(String(message.prefix(40)))) }) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Blocker.submission
    }
    static func importRoutine(peer: String, dataRoot: URL) async throws {
        try await restoringForeground { try await importRoutineInForeground(peer: peer, dataRoot: dataRoot) }
    }
    private static func importRoutineInForeground(peer: String, dataRoot: URL) async throws {
        _ = try await awake()
        let contact = try? AgentPeerStore(dataRoot: dataRoot).list().first { $0.id == peer }
        try await openBotChat(contact?.grokConversation ?? "grok")
        // The path seen on the installed app (09-20), by exact label:
        //   "View conversation details" -> list "Routines" -> the routine's
        //   button -> text fields "Webhook URL" and "Webhook key" ->
        //   "Back to Routines" -> "Close details".
        // Grok Bot itself cannot read these values; this panel is the only source.
        // A control is pressed only when the state it leads to is not already
        // showing, so nothing is toggled shut. Unknown UI stops; nothing is guessed.
        func label(_ node: AXUIElement) -> String {
            string(node, kAXTitleAttribute).isEmpty ? string(node, kAXDescriptionAttribute) : string(node, kAXTitleAttribute)
        }
        func buttons(_ tree: [AXUIElement], _ name: String) -> [AXUIElement] {
            tree.filter { string($0, kAXRoleAttribute) == kAXButtonRole && label($0) == name }
        }
        func field(_ tree: [AXUIElement], _ name: String) -> String? {
            let found = tree.filter { string($0, kAXRoleAttribute) == kAXTextFieldRole && label($0) == name }
            guard found.count == 1, let value = attribute(found[0], kAXValueAttribute) as? String, !value.isEmpty else { return nil }
            return value
        }
        func press(_ node: AXUIElement) -> Bool { AXUIElementPerformAction(node, kAXPressAction as CFString) == .success }
        let routine = GrokBotRoute.routineName(peer)
        var url: String?, key: String?
        var opened = false
        // A newly requested routine is asynchronous: Grok Bot took about a
        // minute to create one. Look for up to two minutes.
        for _ in 0..<120 {
            try Task.checkCancellation()
            let tree = nodes(try window())
            if let foundURL = field(tree, "Webhook URL"), let foundKey = field(tree, "Webhook key"),
               tree.contains(where: { string($0, kAXRoleAttribute) == kAXGroupRole && label($0) == routine }) {
                url = foundURL; key = foundKey; break
            }
            let lists = tree.filter { string($0, kAXRoleAttribute) == kAXListRole && label($0) == "Routines" }
            if lists.count == 1 {
                let mine = nodes(lists[0]).filter { string($0, kAXRoleAttribute) == kAXButtonRole && label($0).contains(routine) }
                if mine.count == 1 { _ = press(mine[0]) }
            } else if let back = buttons(tree, "Back to details").first ?? buttons(tree, "Back to Routines").first {
                _ = press(back)
            } else if !opened, let details = buttons(tree, "View conversation details").first, buttons(tree, "Close details").isEmpty {
                opened = press(details)
            }
            try await Task.sleep(for: .seconds(1))
        }
        // Leave Grok Bot as it was found: the secrets never stay on screen.
        let after = nodes(try window())
        if let back = buttons(after, "Back to Routines").first { _ = press(back) }
        if let close = buttons(nodes(try window()), "Close details").first { _ = press(close) }
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

enum GrokBotConnection {
    static func perform(plan: [String: JSONValue], dataRoot: URL, inner: any ToolDispatchClient, surface: String) async -> JSONValue {
        guard case .string(let peerID)? = plan["peer_id"],
              let contact = try? AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peerID && $0.transport == .grokBot }) else {
            return result("unavailable", "Grok Bot contact unavailable.")
        }
        let store = AgentPeerStore(dataRoot: dataRoot)
        do {
            switch plan["status"] {
            case .string("grok_send"):
                guard await GrokRoutineAccessibility.ensureRunning() else { return result("desktop app not running", "Grok Bot desktop app not running. No message was sent.") }
                guard case .string(let text)? = plan["text"], case .string(let id)? = plan["message_id"],
                      case .string(let conversation)? = plan["conversation_id"] else { return result("invalid", "Missing message.") }
                return try await GrokBotRoute.send(peer: contact, text: text, conversation: conversation,
                    messageID: id, dataRoot: dataRoot, credential: GrokLinkCredential.read(peer: peerID))
            case .string("grok_disconnect"):
                guard contact.grokBootstrapConfirmed == true, contact.grokConversation != nil else {
                    _ = try store.remove(peerID)
                    return result("disconnected", "Local keys revoked and contact removed. Routine creation was never confirmed; no cleanup request was sent.")
                }
                // Disconnecting always finishes here; the cleanup ask is best effort.
                let asked = (try? await DesktopAgentConversationRoute.shared.grokBootstrap(
                    "Delete only the routine named \(GrokBotRoute.routineName(peerID)) that NativeAgent asked you to create in this conversation. Do not delete or change any other routine. Never show its URL or key in chat.",
                    bot: contact.grokConversation ?? "grok")) != nil
                _ = try store.remove(peerID)
                return result("disconnected", asked
                    ? "Local keys revoked. Asked Grok Bot to delete only this app's routine; deletion is not yet confirmed. Approve it in Grok Bot if asked."
                    : "Local keys revoked and contact removed. I could not ask Grok Bot to delete the routine named \(GrokBotRoute.routineName(peerID)); delete it in Grok Bot's Routines if it exists.")
            default:
                if contact.grokSetup == "set up" { return result("set up", "Set up. Send a message to check the reply path.") }
                guard contact.grokSetup != "disconnected" else { return result("disconnected", "Finish disconnecting before creating a new connection.") }
                var saved = contact
                // An unconfirmed request is asked again: the request itself
                // tells the Bot not to create a second routine, so a repeat
                // can only finish the first one, never duplicate it.
                if contact.grokConversation == nil || contact.grokBootstrapConfirmed != true {
                    let conversation: String
                    // The Bot's own 1:1 chat; Grok Bot's built-in Bot is "grok".
                    if let chosen = contact.grokConversation ?? contact.conversationLabel, !chosen.isEmpty { conversation = chosen } else { conversation = "grok" }
                    saved = try store.updateGrok(peerID) {
                        guard $0.grokConversation == nil || $0.grokConversation == conversation else { throw GrokLinkCredential.Failure.invalid }
                        $0.grokConversation = conversation
                    }
                    guard let command = contact.approvedExecutablePath else { throw GrokLinkCredential.Failure.invalid }
                    let message = "Create one Active webhook routine named \(GrokBotRoute.routineName(peerID)) for NativeAgent. Use the exact instruction below. If it already exists, do not create another. Never print the webhook URL or key in chat or command output; NativeAgent reads them from the Routines panel itself. Do not change local execution policy or any other routine.\n\n" + GrokBotRoute.instruction(peer: peerID, command: command)
                    try await DesktopAgentConversationRoute.shared.grokBootstrap(message, bot: conversation)
                    saved = try store.updateGrok(peerID) { $0.grokBootstrapConfirmed = true }
                }
                guard saved.grokBootstrapConfirmed == true else { throw GrokRoutineAccessibility.Blocker.submission }
                // Read the routine's address and key from Grok Bot's Routines panel;
                // the secure field is the fallback when that panel cannot be read.
                var blocker: String?
                do {
                    try await DesktopAgentConversationRoute.shared.importGrokRoutine(peer: peerID, dataRoot: dataRoot)
                    saved.grokSetup = "set up"
                } catch {
                    saved.grokSetup = "secure-paste"
                    blocker = (error as? GrokRoutineAccessibility.Blocker)?.rawValue
                }
                _ = try store.updateGrok(peerID) { $0.grokSetup = saved.grokSetup }
                return result(saved.grokSetup == "set up" ? "set up" : "needs_secure_setup",
                    saved.grokSetup == "set up" ? "Routine credentials saved in Keychain. Set up; no answer checked yet."
                        : (blocker.map { $0 + " " } ?? "") + GrokBotRoute.securePasteBlocker)
            }
        } catch let blocker as GrokRoutineAccessibility.Blocker {
            return result("needs_attention", blocker.rawValue + (contact.grokSetup == "disconnected" ? " Local keys are already revoked; only routine cleanup remains." : ""))
        } catch { return result("needs_attention", "Grok Bot setup or delivery could not be confirmed. No automatic resend. Check the Connect card.") }
    }
    static func result(_ state: String, _ detail: String) -> JSONValue {
        .object(["status": .string(state), "detail": .string(detail), "completed": .bool(false), "automatic_resend": .bool(false)])
    }
}
