import AppKit
import Foundation
import os
import ApplicationServices
import AgentConversations
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import Synchronization
// Blueprint: | `GrokRoutineAccessibility.swift` | Non-main native setup and sends; secret values and clipboard settlement stay native. |
/// Secret values stay inside native code, never model, screenshot, result, log, preview or transcript. Use only the field’s own Copy control and release its
/// clipboard.
public enum GrokRoutineAccessibility {
    public enum Blocker: String, Error, LocalizedError {
        case offline = "Grok Bot desktop app is not running. Open Grok Bot and sign in, then Connect again."
        case permission = "Allow NativeAgent Accessibility access to set up the Grok Bot routine."
        case conversation = """
            Grok Bot does not expose one unambiguous current chat and empty composer. Open the intended chat with no draft, then Connect again.
            """
        case accessibility = "Grok Bot's web Accessibility tree could not be enabled or read. Check NativeAgent Accessibility access, then Connect again."
        case missingRoutine = """
            The NativeAgent reply routine is missing from Grok Bot's Routines panel. Check its creation request and approve it in Grok Bot if \
            asked, then Connect again.
            """
        case recipe = """
            Grok Bot's recipe has no routine navigation (host.grokRoutine). Read agents/recipes/grok-bot.json with agent.recipe and update it with \
            agent.recipe_write, then Connect again.
            """
        case frontmost = "Grok Bot is not the front app. Bring Grok Bot forward, then Connect again."
        case busy = "The desktop is handling another conversation. Connect again when that operation finishes; this request has not started."
        case input = "NativeAgent could not create the mouse or keyboard input for Grok Bot; no submission is confirmed."
        case clipboard = "NativeAgent could not preserve or fill the clipboard for Grok Bot. Check the clipboard before continuing; no request was submitted."
        case geometry = "Grok Bot's control position could not be read through Accessibility. Open the intended chat in Grok Bot, then Connect again."
        case transcript = """
            Grok Bot's current conversation transcript could not be read to establish the outgoing-message boundary. Open the intended chat in Grok \
            Bot, then Connect again; no request was submitted.
            """
        case panelOpen = "A Grok Bot routine panel showing webhook values is open. Close that panel in Grok Bot before continuing."
        public var errorDescription: String? { rawValue }
    }
    public struct Failure: Error, LocalizedError {
        public let detail: String
        let stopped: Bool
        init(detail: String, stopped: Bool = false) { self.detail = detail; self.stopped = stopped }
        public var errorDescription: String? { detail }
    }
    static func observationFailure(_ error: Error, operation: String) -> Failure {
        let reason = (error as? SenseFailure)?.message ?? error.localizedDescription
        let remedy = (error as? SenseFailure)?.code == "source_denied"
            ? "Allow NativeAgent Accessibility access in System Settings → Privacy & Security → Accessibility, then continue."
            : "Bring the app forward with its Accessibility tree available, then continue."
        return Failure(detail: "Accessibility observation \(operation): \(reason) \(remedy)")
    }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).isEmpty }
    /// Open and await the target app so setup does not require a separate manual launch.
    @concurrent public static func ensureRunning(mac: MacOperationContext) async throws {
        try Task.checkCancellation()
        let events = try await DesktopRouteObservation(bundleID: GrokBotRoute.bundleID, context: mac, accessibility: false)
        defer { events.stop() }
        if running { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) else { throw Blocker.offline }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try Task.checkCancellation()
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure(detail: "Grok Bot could not be opened: \(error.localizedDescription) Open Grok Bot and sign in, then Connect again.") }
        try Task.checkCancellation()
        while !running { try await events.next() }
    }
    public static func window(mac: MacOperationContext) throws -> AXUIElement {
        guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { throw Blocker.offline }
        let windows = try SystemMacAXElementSource().nativeWindows(pid: app.processIdentifier, context: mac)
        guard windows.count == 1, let window = windows.first else {
            throw Failure(
                detail: "Grok Bot exposes \(windows.count) windows; setup needs exactly one. Leave one Grok Bot chat window open, then Connect again.")
        }
        return window
    }
    /// Navigation belongs to the window shell, never to historical messages. The log itself remains visible to selectors; only its body is excluded.
    private static func outsideTranscript(mac: MacOperationContext, _ node: AXUIElement) -> Bool {
        MacAXAttributeRead.text(node, kAXSubroleAttribute, context: mac) != "AXApplicationLog"
    }
    static func navigationNodes(mac: MacOperationContext, searching: String = "Grok Bot's navigation controls") throws -> [AXUIElement] {
        try MacAccessibilityReader.elements(in: window(mac: mac), searching: searching,
                    context: mac, descendInto: { outsideTranscript(mac: mac, $0) })
    }
    /// An empty box reports "Message <chat name>" as its value. Match only the verified destination's exact placeholder, never a generic prose prefix.
    static func isEmptyBox(_ value: String, conversation: String = "grok") -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (!conversation.isEmpty && text == "Message " + conversation)
            || ["Ask anything", "Ask anything…", "Ask anything..."].contains(text)
    }
    /// Activate accessibility before window reads because the target app builds its tree only in front with a reader present.
    static let log = Logger(subsystem: "NativeAgent", category: "GrokBot")
    static func step(_ name: String) { log.error("grok setup stopped at \(name, privacy: .public)") }
    /// Before typing, resend is safe; after submission, Return makes the outcome uncertain.
    enum SendStage: Sendable { case opening, conversation, typing, submitted }
    private struct SendState: Sendable {
        var reached = SendStage.opening
        var layout: GrokDesktopReply.Layout?
        var observation: JSONValue?
    }
    // The existing send owner survives executor hops; no lock is held during AX or an await.
    private static let sendState = Mutex(SendState())
    static var reached: SendStage {
        get { sendState.withLock { $0.reached } }
        set { sendState.withLock { $0.reached = newValue } }
    }
    /// Capture exact outgoing occurrences and transcript location while foreground so reply watches correlate the new send.
    static var sentLayout: GrokDesktopReply.Layout? {
        get { sendState.withLock { $0.layout } }
        set { sendState.withLock { $0.layout = newValue } }
    }
    static var submissionObservation: JSONValue? {
        get { sendState.withLock { $0.observation } }
        set { sendState.withLock { $0.observation = newValue } }
    }
    @concurrent static func awake(turn: Turn, mac: MacOperationContext) async throws -> NSRunningApplication {
        do { try await MacScreenLock.wakeIfCovered(turn: turn, context: mac) }
        catch let covered as MacScreenLock.Covered { throw Failure(detail: covered.detail) }
        try await ensureRunning(mac: mac)
        try Task.checkCancellation()
        guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
        try requireDriver(mac: mac)
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { throw Blocker.accessibility }
        // Settle a cold renderer here before the synchronous reads on this non-main path.
        try await SystemMacAXElementSource.prepareRenderer(pid: runningApp.processIdentifier, context: mac)
        try await bringForward(mac: mac, pid: runningApp.processIdentifier)
        try await waitUntil(mac: mac, accessibility: false) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == runningApp.processIdentifier
        }
        try await waitUntil(mac: mac) {
            (try navigationNodes(mac: mac)).contains { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == "AXWebArea" }
        }
        return runningApp
    }
    /// App activation must use ordering only; window AX reads belong to the later settled read.
    nonisolated private static func bringForward(mac: MacOperationContext, pid: pid_t) async throws {
        try Task.checkCancellation()
        let source = SystemMacAXActSource()
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "The requested app"
        let outcome = await source.activate(pid: pid, context: mac)
        try Task.checkCancellation()
        guard mac.driver?.allowsEmission(context: mac) == true else { throw Failure(detail: MacAttentionSessionStore.sendRefusal(context: mac)) }
        guard outcome != .invalidTarget else {
            throw Failure(detail: "\(appName) is no longer running. Open it before continuing.")
        }
        guard outcome == .performed else {
            throw Failure(detail: source.raiseDiagnostic
                ?? "\(appName) was not confirmed as the front app. Bring it forward before continuing.")
        }
    }
    static func requireDriver(mac: MacOperationContext) throws {
        try Task.checkCancellation()
        guard mac.driver?.allowsEmission(context: mac) == true else { throw Failure(detail: MacAttentionSessionStore.sendRefusal(context: mac)) }
    }
    private static func withDriver<Value>(mac: MacOperationContext, _ operation: (MacOperationContext) async throws -> Value) async throws -> Value {
        if mac.driver != nil { return try await operation(mac) }
        let binding = try await MacAttentionSessionStore.shared.bindDriver()
        return try await withTaskCancellationHandler {
            try await withAgentMacDriver(mac, driver: binding) { mac in try await operation(mac) }
        } onCancel: { binding.cancel() }
    }
    /// No model-driven screen access while a secret-bearing panel is open.
    static func requireChatOnly(mac: MacOperationContext, _ nodes: [AXUIElement]) throws {
        // The secret-bearing panel shows its values in text fields; a chat message that merely says "key" or carries a link is not that panel.
        let tree = nodes.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXTextFieldRole }
        guard !tree.contains(where: { node in
            let labels = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { MacAXAttributeRead.text(node, $0, context: mac).lowercased() }
            return labels.contains { $0 == "post to" || $0 == "key" || $0 == "webhook key" || $0.hasPrefix("https://") }
        }) else { throw Blocker.panelOpen }
    }
    static func isCurrentBotChat(mac: MacOperationContext, _ bot: String, in tree: [AXUIElement]) -> Bool {
        tree.contains { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == "AXHeading"
            && (MacAXAttributeRead.text($0, kAXTitleAttribute, context: mac) == bot || MacAXAttributeRead.text($0, kAXDescriptionAttribute,
                context: mac) == bot) }
    }
    static func prepareConversation(mac: MacOperationContext, bot: String) throws -> AXUIElement {
        let tree = try navigationNodes(mac: mac)
        try requireChatOnly(mac: mac, tree)
        guard isCurrentBotChat(mac: mac, bot, in: tree) else {
            throw Failure(detail: "Chat \"\(bot)\" is not the open Grok Bot chat. Open that exact chat, then Connect again.")
        }
        let boxes = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXTextAreaRole
            && MacAXAttributeRead.text($0, kAXDescriptionAttribute, context: mac).lowercased() == "prompt" }
        guard boxes.count == 1, let box = boxes.first else {
            throw Failure(detail: """
                Grok Bot exposes \(boxes.count) message boxes; setup needs exactly one empty composer. Open the intended chat with no draft, then \
                Connect again.
                """)
        }
        let value = try composerValue(mac: mac, box)
        guard isEmptyBox(value, conversation: bot) else {
            throw Failure(detail: "Grok Bot's message box already holds a draft, left untouched. Finish or clear that draft before continuing.")
        }
        return box
    }
    nonisolated static func composerValue(mac: MacOperationContext, _ node: AXUIElement) throws -> String {
        guard let value = MacAXAttributeRead.copyRaw(node, kAXValueAttribute, context: mac) as? String else {
            throw Failure(detail: "The exact message box text could not be read through Accessibility. Its draft was left untouched; nothing was typed.")
        }
        return value
    }

    static func centre(mac: MacOperationContext, _ node: AXUIElement) throws -> CGPoint {
        guard let frame = MacAXAttributeRead.frame(node, context: mac) else { throw Blocker.geometry }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    public static func copyPasteboard(_ pasteboard: NSPasteboard) throws -> [[(type: String, data: Data)]] {
        try (pasteboard.pasteboardItems ?? []).map { item in
            let checked = NSPasteboardItem()
            var copy: [(type: String, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type), checked.setData(data, forType: type) else { throw Blocker.clipboard }
                copy.append((type.rawValue, data))
            }
            return copy
        }
    }
    /// Carry clipboard bytes across settlement, not AppKit objects shared between executors.
    static func restorePasteboard(_ saved: [[(type: String, data: Data)]], to pasteboard: NSPasteboard) -> Bool {
        var items: [NSPasteboardItem] = []
        for contents in saved {
            let item = NSPasteboardItem()
            for (type, data) in contents {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else { return false }
            }
            items.append(item)
        }
        return pasteboard.writeObjects(items)
    }
    /// Source changes resume the same predicate; silence remains cancellable and actions are never repeated.
    @concurrent @discardableResult static func waitUntil(mac: MacOperationContext, accessibility: Bool = true,
                          _ ready: () throws -> Bool) async throws -> JSONValue {
        let events = try await DesktopRouteObservation(bundleID: GrokBotRoute.bundleID, context: mac, accessibility: accessibility)
        defer { events.stop() }
        repeat {
            try Task.checkCancellation()
            if try ready() { return await events.receipt(readBy: accessibility ? "accessibility" : "workspace") }
            try await events.next()
        } while true
    }
    /// Routine creation needs the one-to-one bot chat with Auto-review; confirm its list entry and open heading.
    @concurrent static func openBotChat(turn: Turn, mac: MacOperationContext, _ bot: String) async throws {
        func heading() throws -> Bool {
            isCurrentBotChat(mac: mac, bot, in: try navigationNodes(mac: mac))
        }
        if try heading() { return }
        let chats = (try navigationNodes(mac: mac)).filter {
            guard MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXButtonRole else { return false }
            let title = MacAXAttributeRead.label($0, context: mac)
            return title == bot || title.hasPrefix(bot + ", ")
        }
        try requireDriver(mac: mac)
        guard chats.count == 1, let chat = chats.first else {
            throw Failure(
                detail: "Chat \"\(bot)\" matches \(chats.count) Grok Bot sidebar entries; setup needs exactly one. Open that exact chat, then Connect again.")
        }
        guard try SystemMacAXActSource().performNative(chat, action: kAXPressAction, turn: turn, context: mac).get() == .success else {
            throw Failure(detail: "Grok Bot refused the Accessibility action to open chat \"\(bot)\". Open that chat in Grok Bot, then Connect again.")
        }
        try await waitUntil(mac: mac) { try heading() }
    }
    @concurrent static func send(turn: Turn, mac: MacOperationContext, _ text: String, bot: String, watchReply: Bool = false,
                     beforeSubmission: @Sendable () throws -> Void = {}) async throws {
        try await withDriver(mac: mac) { mac in
            try await sendWithDriver(turn: turn, mac: mac, text, bot: bot, watchReply: watchReply, beforeSubmission: beforeSubmission)
        }
    }
    private static func sendWithDriver(turn: Turn, mac: MacOperationContext, _ text: String, bot: String, watchReply: Bool,
                                       beforeSubmission: @Sendable () throws -> Void) async throws {
        guard !text.isEmpty else { throw Failure(detail: "The Grok Bot request is empty. Supply message text before sending; nothing was submitted.") }
        reached = .opening; sentLayout = nil; submissionObservation = nil
        let previous = NSWorkspace.shared.frontmostApplication
        let driver = mac.driver?.settlementBinding()
        do {
            try await sendInForeground(turn: turn, mac: mac, text, bot: bot, watchReply: watchReply, previous: previous, beforeSubmission: beforeSubmission)
        } catch {
            if let watch = sentLayout?.watchID { await GrokDesktopReply.abandon(watch) }
            else { await settle {
                await withAgentMacDriver(mac, driver: driver) { mac in await restoreForeground(mac: mac, previous) }
            } }
            let failure: Error
            if reached == .submitted {
                let primary = error is CancellationError ? "Grok Bot send stopped." : error.localizedDescription
                failure = Failure(detail: primary + " Return was posted; message submission is unconfirmed. No automatic resend.",
                                  stopped: error is CancellationError || (error as? Failure)?.stopped == true)
            } else { failure = error }
            step(failure.localizedDescription)
            throw failure
        }
        if sentLayout?.watchID == nil { await settle {
            await withAgentMacDriver(mac, driver: driver) { mac in await restoreForeground(mac: mac, previous) }
        } }
    }
    /// Await cleanup on success and failure; never steal focus back after the person has switched to another application during setup.
    static func restoringForeground<Value>(mac: MacOperationContext, _ operation: (MacOperationContext) async throws -> Value) async throws -> Value {
        try await withDriver(mac: mac) { mac in try await restoringForegroundWithDriver(mac: mac, operation) }
    }
    private static func restoringForegroundWithDriver<Value>(mac: MacOperationContext, _ operation: (
        MacOperationContext) async throws -> Value) async throws -> Value {
        let previous = NSWorkspace.shared.frontmostApplication
        let driver = mac.driver?.settlementBinding()
        let result: Result<Value, Error>
        do { result = .success(try await operation(mac)) } catch { result = .failure(error) }
        await settle {
            await withAgentMacDriver(mac, driver: driver) { mac in await restoreForeground(mac: mac, previous) }
        }
        return try result.get()
    }
    static func shouldRestoreForeground(previousPID: pid_t?, previousTerminated: Bool,
                                        currentPID: pid_t?, currentBundleID: String?) -> Bool {
        previousPID != nil && !previousTerminated && previousPID != currentPID
            && currentBundleID == GrokBotRoute.bundleID
    }
    @concurrent static func restoreForeground(mac: MacOperationContext, _ previous: NSRunningApplication?) async {
        let current = NSWorkspace.shared.frontmostApplication
        guard shouldRestoreForeground(previousPID: previous?.processIdentifier,
                                      previousTerminated: previous?.isTerminated ?? true,
                                      currentPID: current?.processIdentifier,
                                      currentBundleID: current?.bundleIdentifier),
              let previous, mac.driver?.allowsEmission(context: mac) == true else { return }
        do { try await bringForward(mac: mac, pid: previous.processIdentifier) }
        catch { log.error("foreground restoration stopped: \(error.localizedDescription, privacy: .public)") }
    }
    private static func sendInForeground(turn: Turn, mac: MacOperationContext, _ text: String, bot: String, watchReply: Bool, previous: NSRunningApplication?,
                                         beforeSubmission: @Sendable () throws -> Void) async throws {
        let app = try await awake(turn: turn, mac: mac)
        reached = .conversation
        func requireFrontmost() throws {
            try requireDriver(mac: mac)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw Blocker.frontmost
            }
        }
        try await openBotChat(turn: turn, mac: mac, bot)
        let box = try prepareConversation(mac: mac, bot: bot)
        let sink = CGEventSink()
        guard let click = sink.clickEvents(at: try centre(mac: mac, box)),
              let paste = sink.keyEvents(9, flags: .maskCommand),
              let submit = sink.keyEvents(36) else { throw Blocker.input }
        try requireFrontmost()
        for event in click { try await sink.postNative(event, context: mac) }
        try await waitUntil(mac: mac) {
            try requireFrontmost()
            return (MacAXAttributeRead.copyRaw(box, kAXFocusedAttribute, context: mac) as? Bool) == true
        }
        // Recheck after focus: never replace a draft or paste into a changed chat.
        guard CFEqual(box, try prepareConversation(mac: mac, bot: bot)) else {
            throw Failure(detail: "Grok Bot's message box changed after focus. Open the intended chat with no draft before continuing; no text was pasted.")
        }
        guard let submission = try GrokDesktopReply.submission(mac: mac, text, chat: bot) else { throw Blocker.transcript }
        sentLayout = submission.layout
        try await DesktopClipboard.shared.acquire()
        defer { DesktopClipboard.shared.release() }
        try requireFrontmost()
        let pasteboard = NSPasteboard.general
        let saved = try copyPasteboard(pasteboard)
        pasteboard.clearContents()
        var ours = pasteboard.changeCount
        defer {
            // Only put the person's clipboard back if nothing new was copied meanwhile.
            if pasteboard.changeCount == ours {
                pasteboard.clearContents()
                if !saved.isEmpty { _ = restorePasteboard(saved, to: pasteboard) }
            }
        }
        guard pasteboard.setString(text, forType: .string) else { throw Blocker.clipboard }
        ours = pasteboard.changeCount
        try requireFrontmost()
        reached = .typing
        for event in paste { try await sink.postNative(event, context: mac) }
        try await waitUntil(mac: mac) {
            try requireFrontmost()
            // Accept the composer’s own trailing newline as part of its pasted representation.
            let value = (MacAXAttributeRead.copyRaw(box, kAXValueAttribute, context: mac) as? String) ?? ""
            return !isEmptyBox(value, conversation: bot) && GrokDesktopReply.same(value, text)
        }
        try requireFrontmost()
        if watchReply, var layout = sentLayout {
            layout.watchID = try await GrokDesktopReply.start(mac: mac, message: text, chat: bot, layout: layout, previous: previous)
            sentLayout = layout
        }
        try beforeSubmission()
        try requireFrontmost()
        reached = .submitted
        for event in submit { try await sink.postNative(event, context: mac) }
        try await verifySubmission(mac: mac, text, bot: bot, baseline: submission.baseline)
    }
    @concurrent static func verifySubmission(mac: MacOperationContext, _ message: String, bot: String, baseline: Int) async throws {
        submissionObservation = try await waitUntil(mac: mac) {
            let tree = try navigationNodes(mac: mac)
            guard isCurrentBotChat(mac: mac, bot, in: tree) else { throw Blocker.conversation }
            let boxes = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXTextAreaRole
                && MacAXAttributeRead.text($0, kAXDescriptionAttribute, context: mac).lowercased() == "prompt" }
            if boxes.count == 1, let box = boxes.first, let value = try MacAXAttributeRead.checkedRaw(box, kAXValueAttribute, context: mac) as? String,
               isEmptyBox(value, conversation: bot),
               let read = try GrokDesktopReply.submission(mac: mac, message, chat: bot), read.baseline > baseline { return true }
            return false
        }
    }
    private typealias RoutineRecipe = AgentHostRow.GrokRoutine

    private static func recipeFailure(_ detail: String, dataRoot: URL, uiMismatch: Bool = true) -> Failure {
        Failure(detail: detail + (uiMismatch ? " Grok Bot's UI differs from the recipe. " : " ")
            + dataRoot.appendingPathComponent("agents/recipes/grok-bot.json").path
            + " is yours to update: read agent.recipe {host:\"grok-bot\"}, update host.grokRoutine with agent.recipe_write, then Connect again.")
    }
    private static func actionFailure(_ result: Result<AXError, MacNativeActionFailure>, action: String, step: String, dataRoot: URL) -> any Error {
        let error: AXError
        switch result {
        case .failure(let refusal): return refusal
        case .success(let status): error = status
        }
        if error == .apiDisabled || !SystemMacAXElementSource().isTrusted() { return Blocker.permission }
        let detail = "Grok Bot returned Accessibility error \(error.rawValue) performing \(action) at \"\(step)\"."
        if error == .actionUnsupported { return recipeFailure(detail, dataRoot: dataRoot) }
        return Failure(detail: detail + " The native control did not respond successfully. Check that control in Grok Bot before continuing.")
    }
    private static func matches(mac: MacOperationContext, _ node: AXUIElement, _ control: RoutineRecipe.Control) -> Bool {
        control.roles.contains(MacAXAttributeRead.text(node, kAXRoleAttribute, context: mac))
            && (control.subrole.map { MacAXAttributeRead.text(node, kAXSubroleAttribute, context: mac) == $0 } ?? true)
            && (control.label.map { MacAXAttributeRead.label(node, context: mac) == $0 } ?? true)
    }
    private static func unique(_ values: [AXUIElement]) -> [AXUIElement] {
        values.reduce(into: []) { result, value in
            if !result.contains(where: { CFEqual($0, value) }) { result.append(value) }
        }
    }
    /// Resolve section lists from their own labels so historical message titles cannot select navigation.
    private static func routineList(mac: MacOperationContext, _ recipe: RoutineRecipe, dataRoot: URL) throws -> AXUIElement? {
        guard let list = recipe.list else { throw Blocker.recipe }
        let root = try window(mac: mac)
        let tree = try MacAccessibilityReader.elements(in: root, searching: "the Routines anchor", context: mac) { node in
            outsideTranscript(mac: mac, node) && MacAXAttributeRead.label(node, context: mac) != recipe.routines
        }
        let anchors = tree.filter {
            [kAXListRole, kAXGroupRole, "AXHeading", kAXStaticTextRole].contains(MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac))
                && MacAXAttributeRead.label($0, context: mac) == recipe.routines
        }
        var lists: [AXUIElement] = []
        for anchor in anchors {
            var node: AXUIElement? = anchor
            while let candidate = node, !CFEqual(candidate, root) {
                let found = try MacAccessibilityReader.elements(in: candidate, searching: "the Routines section", context: mac,
                    descendInto: { outsideTranscript(mac: mac, $0) })
                    .filter { matches(mac: mac, $0, list) }
                if !found.isEmpty { lists += found; break }
                node = MacAXAttributeRead.parent(candidate, context: mac)
            }
        }
        lists = unique(lists)
        guard lists.count <= 1 else {
            throw recipeFailure("The \"\(recipe.routines)\" section identifies \(lists.count) content lists; setup needs one.", dataRoot: dataRoot)
        }
        return lists.first
    }
    private static func routineRow(mac: MacOperationContext, _ recipe: RoutineRecipe, title: String, dataRoot: URL) throws -> AXUIElement? {
        guard let pause = recipe.pause else { throw Blocker.recipe }
        guard let list = try routineList(mac: mac, recipe, dataRoot: dataRoot) else { return nil }
        let tree = try MacAccessibilityReader.elements(in: list, searching: "the Routines row", context: mac)
        let titles = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXStaticTextRole && MacAXAttributeRead.label($0,
            context: mac) == title }
        var rows: [AXUIElement] = []
        for title in titles {
            var node = MacAXAttributeRead.parent(title, context: mac)
            while let candidate = node, !CFEqual(candidate, list) {
                if try MacAccessibilityReader.elements(in: candidate, searching: "the Routines section", context: mac, descendInto: { outsideTranscript(
                    mac: mac, $0) }).contains(
                    where: { matches(mac: mac, $0, pause) }) { rows.append(candidate); break }
                node = MacAXAttributeRead.parent(candidate, context: mac)
            }
        }
        rows = unique(rows)
        guard rows.count <= 1 else {
            throw recipeFailure("The Routines list has \(rows.count) rows with this exact title and the Pause switch; setup needs one.", dataRoot: dataRoot)
        }
        if !titles.isEmpty && rows.isEmpty {
            throw recipeFailure("The named Routines row has no \"\(pause.label ?? "Pause")\" switch matching the recipe.", dataRoot: dataRoot)
        }
        return rows.first
    }
    private static func menus(mac: MacOperationContext) throws -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { throw Blocker.offline }
        let source = SystemMacAXElementSource()
        return source.transientMenuRoots(pid: app.processIdentifier, context: mac).compactMap(source.element)
    }
    /// Secret panels may be sheets, popovers or native windows; keep all nodes inside the native credential boundary.
    private static func nativeViewNodes(mac: MacOperationContext) throws -> [AXUIElement] {
        guard SystemMacAXElementSource().isTrusted() else { throw Blocker.permission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotRoute.bundleID).first else { throw Blocker.offline }
        let windows = try SystemMacAXElementSource().nativeWindows(pid: app.processIdentifier, context: mac)
        return try windows.flatMap { try MacAccessibilityReader.elements(in: $0, searching: "the native routine view", context: mac,
            descendInto: { outsideTranscript(mac: mac, $0) }) }
    }
    /// The recipe contains selectors and navigation only. Credential handling and clipboard lifetime remain native and cannot be changed by the file.
    @concurrent static func importRoutine(turn: Turn, mac: MacOperationContext, peer: String, dataRoot: URL, waitForCreation: Bool) async throws -> String {
        let recipe: RoutineRecipe
        do { recipe = try await Task.detached { try AgentRecipeStore.grokRoutine(dataRoot: dataRoot) }.value }
        catch { throw recipeFailure("Grok Bot's routine recipe could not be read: \(error.localizedDescription)", dataRoot: dataRoot, uiMismatch: false) }
        guard let navigation = recipe.navigation, !navigation.isEmpty, recipe.list != nil, recipe.pause != nil else {
            throw recipeFailure("host.grokRoutine has no navigation, list or Pause selector.", dataRoot: dataRoot, uiMismatch: false)
        }
        return try await restoringForeground(mac: mac) { mac in
            _ = try await awake(turn: turn, mac: mac)
            // Do not close an unrelated panel or invent one after awakening.
            try requireChatOnly(mac: mac, navigationNodes(mac: mac))
            var opened: [RoutineRecipe.Step] = []
            let result: Result<String, Error>
            do {
                result = .success(try await importRoutineInForeground(turn: turn, mac: mac, peer: peer, dataRoot: dataRoot, waitForCreation: waitForCreation,
                    recipe: recipe, navigation: navigation, opened: &opened))
            } catch { result = .failure(error) }
            let driver = mac.driver?.settlementBinding()
            let ownedSteps = opened
            let cleanup: [String] = await settle {
                await withAgentMacDriver(mac, driver: driver) { mac in
                    var failures: [String] = []
                    for step in ownedSteps.reversed() {
                        guard let dismissal = step.dismissal else { continue }
                        do { try await dismiss(turn: turn, mac: mac, dismissal, step: step.name, openMarker: step.alreadyOpen, dataRoot: dataRoot) }
                        catch { failures.append(error.localizedDescription); break }
                    }
                    return failures
                }
            }
            let cleanupDetail = cleanup.isEmpty ? "" : " Cleanup: " + cleanup.joined(separator: " ")
            switch result {
            case .failure(let original):
                guard !cleanup.isEmpty else { throw original }
                let primary = original is CancellationError ? "Grok Bot setup stopped." : original.localizedDescription
                throw Failure(detail: primary + cleanupDetail,
                    stopped: original is CancellationError || (original as? Failure)?.stopped == true)
            case .success(let exposure):
                // Cleanup failure accompanies setup success without replacing its committed outcome.
                return exposure + cleanupDetail
            }
        }
    }
    @concurrent private static func dismiss(turn: Turn, mac: MacOperationContext, _ dismissal: RoutineRecipe.Dismissal, step: String,
        openMarker: RoutineRecipe.Control?, dataRoot: URL) async throws {
        let tree = dismissal.control.roles.contains(kAXMenuRole) ? try menus(mac: mac) : try nativeViewNodes(mac: mac)
        let controls = tree.filter { matches(mac: mac, $0, dismissal.control) }
        if controls.isEmpty && dismissal.ifPresent { return }
        // The panel’s own absent open marker proves closure.
        if controls.isEmpty, let openMarker, !tree.contains(where: { matches(mac: mac, $0, openMarker) }) { return }
        guard controls.count == 1, let node = controls.first else {
            throw recipeFailure("""
                After \(step), closure is unconfirmed: found \(controls.count) controls matching \
                \"\(dismissal.control.label ?? dismissal.control.roles.joined(separator: "/"))\".
                """, dataRoot: dataRoot)
        }
        try requireDriver(mac: mac)
        let outcome = SystemMacAXActSource().performNative(node, action: dismissal.action.rawValue, turn: turn, context: mac)
        guard case .success(.success) = outcome else {
            throw actionFailure(outcome, action: dismissal.action.rawValue, step: "closing " + step, dataRoot: dataRoot)
        }
        let events = try await DesktopRouteObservation(bundleID: GrokBotRoute.bundleID, context: mac)
        defer { events.stop() }
        repeat {
            try Task.checkCancellation()
            let remaining = dismissal.control.roles.contains(kAXMenuRole) ? try menus(mac: mac) : try nativeViewNodes(mac: mac)
            if !remaining.contains(where: { matches(mac: mac, $0, dismissal.control) }) { return }
            try await events.next()
        } while true
    }
    @concurrent private static func importRoutineInForeground(turn: Turn, mac: MacOperationContext, peer: String, dataRoot: URL, waitForCreation: Bool,
        recipe: RoutineRecipe, navigation: [RoutineRecipe.Step], opened: inout [RoutineRecipe.Step]) async throws -> String {
        let store = AgentPeerStore(dataRoot: dataRoot)
        let contacts = try await Task.detached { try store.list() }.value
        guard let contact = contacts.first(where: { $0.id == peer && $0.transport == .grokBot }) else {
            throw Failure(detail: "This Grok Bot contact is unavailable. Connect Grok Bot again before continuing.")
        }
        let bot = contact.grokConversation ?? contact.conversationLabel ?? recipe.mainChat
        try await openBotChat(turn: turn, mac: mac, bot)
        try await Task.detached { try store.updateGrok(peer) { $0.grokConversation = bot } }.value
        let routine = GrokBotRoute.routineName(peer)
        for step in navigation {
            // An already visible section belongs to the person, not our cleanup.
            if let marker = step.alreadyOpen,
               try navigationNodes(mac: mac, searching: "the already-open \(step.name) marker").filter({ matches(mac: mac, $0, marker) })
                   .count == 1 { continue }
            let events = try await DesktopRouteObservation(bundleID: GrokBotRoute.bundleID, context: mac)
            defer { events.stop() }
            let selected: AXUIElement
            repeat {
                try Task.checkCancellation()
                let tree: [AXUIElement]
                switch step.scope {
                case .window: tree = try navigationNodes(mac: mac, searching: "the \(step.name) control in Grok Bot's window")
                case .routineRow:
                    tree = try routineRow(mac: mac, recipe, title: routine, dataRoot: dataRoot).map { try MacAccessibilityReader.elements(in: $0,
                        searching: "the routine navigation control", context: mac) } ?? []
                case .menu:
                    let open = try menus(mac: mac)
                    guard open.count <= 1 else {
                        throw recipeFailure("The Routines row exposed \(open.count) menus; setup needs one.", dataRoot: dataRoot)
                    }
                    tree = try open.first.map { try MacAccessibilityReader.elements(in: $0, searching: "the routine navigation control", context: mac) } ?? []
                }
                let controls = try tree.filter { node in
                    guard matches(mac: mac, node, step.control), try MacAXAttributeRead.copyActions(node, context: mac).contains(step.action.rawValue),
                          try MacAXAttributeRead.checkedBool(node, kAXEnabledAttribute, context: mac) == true else { return false }
                    if step.scope != .routineRow { return true }
                    return try MacAccessibilityReader.elements(in: node, searching: "the routine control", context: mac).contains {
                        MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXStaticTextRole && MacAXAttributeRead.label($0,
                            context: mac) == routine
                    }
                }
                guard controls.count <= 1 else {
                    throw recipeFailure(
                        "Step \"\(step.name)\" found \(controls.count) matching controls supporting \(step.action.rawValue); setup needs one.",
                            dataRoot: dataRoot)
                }
                if let control = controls.first { selected = control; break }
                if step.scope == .routineRow, tree.isEmpty, !waitForCreation,
                   try routineList(mac: mac, recipe, dataRoot: dataRoot) != nil { throw Blocker.missingRoutine }
                try await events.next()
            } while true
            try requireDriver(mac: mac)
            let outcome = SystemMacAXActSource().performNative(selected, action: step.action.rawValue, turn: turn, context: mac)
            guard case .success(.success) = outcome else {
                throw actionFailure(outcome, action: step.action.rawValue, step: step.name, dataRoot: dataRoot)
            }
            opened.append(step)
        }
        let events = try await DesktopRouteObservation(bundleID: GrokBotRoute.bundleID, context: mac)
        defer { events.stop() }
        var urlFields: [AXUIElement] = [], keyFields: [AXUIElement] = []
        repeat {
            try Task.checkCancellation()
            let fields = try nativeViewNodes(mac: mac).filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXTextFieldRole }
            urlFields = fields.filter { MacAXAttributeRead.label($0, context: mac) == recipe.webhookURL }
            keyFields = fields.filter { MacAXAttributeRead.label($0, context: mac) == recipe.webhookKey }
            if urlFields.count == 1 && keyFields.count == 1 { break }
            try await events.next()
        } while true
        guard urlFields.count == 1, keyFields.count == 1, let urlField = urlFields.first, let keyField = keyFields.first else {
            throw recipeFailure("""
                Webhook view exposed \(urlFields.count) text fields labeled \"\(recipe.webhookURL)\" and \(keyFields.count) labeled \
                \"\(recipe.webhookKey)\"; setup needs one of each. No field values were reported.
                """, dataRoot: dataRoot)
        }
        let url = try await nativeField(turn: turn, mac: mac, urlField, copyLabel: recipe.copyURL, name: recipe.webhookURL, dataRoot: dataRoot)
        let key = try await nativeField(turn: turn, mac: mac, keyField, copyLabel: recipe.copyKey, name: recipe.webhookKey, dataRoot: dataRoot)
        try await Task.detached {
            try store.updateGrok(peer) { contact in
                var credential = try GrokLinkCredential.read(peer: peer)
                try credential.importWebhook(url: url.value, key: key.value)
                try credential.write(peer: peer)
                contact.grokSetup = "set up"
                contact.grokBootstrapConfirmed = true
            }
        }.value
        return "Webhook view exposed one URL text field (\(url.exposure)) and one key text field (\(key.exposure)); no values were reported."
    }
    private static func masked(_ value: String) -> Bool {
        value.contains("•") || value.contains("●") || value.hasPrefix("***")
            || (!value.isEmpty && value.allSatisfy { "*·".contains($0) })
    }
    @concurrent private static func nativeField(turn: Turn, mac: MacOperationContext, _ field: AXUIElement, copyLabel: String?, name: String,
                                   dataRoot: URL) async throws -> (value: String, exposure: String) {
        try requireDriver(mac: mac)
        let value = MacAXAttributeRead.copyRaw(field, kAXValueAttribute, context: mac) as? String
        let isMasked = MacAXAttributeRead.text(field, kAXSubroleAttribute, context: mac) == kAXSecureTextFieldSubrole || value.map(masked) == true
        if let value, !value.isEmpty, !isMasked { return (value, "readable through Accessibility") }
        let exposure = isMasked ? "masked" : "empty or unreadable through Accessibility"
        guard isMasked else {
            throw recipeFailure(
                "Webhook field \"\(name)\" is \(exposure); Copy is only used for masked fields. No Copy action ran and no credentials were saved.",
                    dataRoot: dataRoot)
        }
        // A Copy control must belong to this field's own group, never an arbitrary Copy elsewhere in the window.
        var container = MacAXAttributeRead.parent(field, context: mac), copy: AXUIElement?
        while let candidate = container, MacAXAttributeRead.text(candidate, kAXRoleAttribute, context: mac) != kAXWindowRole {
            let tree = try MacAccessibilityReader.elements(in: candidate, searching: "the webhook field's own Copy control", context: mac)
            let fields = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXTextFieldRole }
            guard fields.count == 1, let candidateField = fields.first, CFEqual(candidateField, field) else { break }
            let buttons = tree.filter { MacAXAttributeRead.text($0, kAXRoleAttribute, context: mac) == kAXButtonRole && MacAXAttributeRead.label($0,
                context: mac) == copyLabel }
            if buttons.count == 1, let button = buttons.first { copy = button; break }
            if buttons.count > 1 { break }
            container = MacAXAttributeRead.parent(candidate, context: mac)
        }
        guard let copy else {
            throw recipeFailure("""
                Webhook field \"\(name)\" is \(exposure); its own group has no unambiguous \"\(copyLabel ?? "(not configured)")\" button. No \
                credentials were saved.
                """, dataRoot: dataRoot)
        }
        try requireDriver(mac: mac)
        try await DesktopClipboard.shared.acquire()
        defer { DesktopClipboard.shared.release() }
        try requireDriver(mac: mac)
        let pasteboard = NSPasteboard.general
        let saved = try copyPasteboard(pasteboard)
        pasteboard.clearContents()
        let baseline = pasteboard.changeCount
        let copyOutcome = SystemMacAXActSource().performNative(copy, action: kAXPressAction, turn: turn, context: mac)
        let ours = pasteboard.changeCount
        // The native Copy returns before settlement can restore its clipboard; Stop cannot interrupt adoption or release.
        let transfer: Result<(value: String, cleared: Bool), Error> = await settle {
            let pasteboard = NSPasteboard.general
            let result: Result<String, Error> = Result {
                guard case .success(.success) = copyOutcome else {
                    throw actionFailure(copyOutcome, action: kAXPressAction, step: name + " own Copy control (" + exposure + ")", dataRoot: dataRoot)
                }
                guard ours != baseline else {
                    throw recipeFailure("Webhook field \"\(name)\" is \(exposure); its Copy action completed without publishing clipboard text.",
                        dataRoot: dataRoot)
                }
                let conflict = Failure(detail: """
                    The clipboard changed after Grok Bot's field Copy. Import stopped; the newer clipboard was left in place. Connect again \
                    when the clipboard is free.
                    """)
                guard pasteboard.changeCount == ours else { throw conflict }
                let copied = pasteboard.string(forType: .string)
                guard pasteboard.changeCount == ours else { throw conflict }
                guard let value = copied, !value.isEmpty, !masked(value) else {
                    throw recipeFailure("Webhook field \"\(name)\" is \(exposure); its Copy action exposed no readable text.", dataRoot: dataRoot)
                }
                return value
            }
            do {
                let cleared = pasteboard.changeCount == ours
                if cleared {
                    pasteboard.clearContents()
                    if !saved.isEmpty, !restorePasteboard(saved, to: pasteboard) {
                        let primary: String
                        switch result {
                        case .success: primary = "The native copy completed."
                        case .failure(let error): primary = error.localizedDescription
                        }
                        throw Failure(detail: primary + " Cleanup: the temporary clipboard was cleared, but its previous contents could not be restored.")
                    }
                }
                return .success((try result.get(), cleared))
            } catch { return .failure(error) }
        }
        if Task.isCancelled, case .failure(let error) = transfer {
            throw Failure(detail: "Grok Bot setup stopped. Native Copy settlement: " + error.localizedDescription, stopped: true)
        }
        let copied = try transfer.get()
        try Task.checkCancellation()
        return (copied.value, exposure + "; own Copy control used natively; "
            + (copied.cleared ? "temporary clipboard cleared" : "newer clipboard preserved"))
    }
}

/// Copy/import and desktop sends share the pasteboard until their own cleanup completes.
final class DesktopClipboard: Sendable {
    static let shared = DesktopClipboard()

    private struct State: Sendable {
        var held = false
        var waiters: [(UUID, ScopedWaiter)] = []
    }
    private let state = Mutex(State())

    @concurrent func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let waiter = ScopedWaiter()
        let queued = state.withLock {
            if !$0.held { $0.held = true; return false }
            $0.waiters.append((id, waiter))
            return true
        }
        if queued { await waiter.park() }
        if Task.isCancelled {
            let next = state.withLock { state -> ScopedWaiter? in
                if let index = state.waiters.firstIndex(where: { $0.0 == id }) {
                    state.waiters.remove(at: index)
                    return nil
                }
                // A cancelled recipient passes on a slot already transferred to it.
                return Self.release(&state)
            }
            next?.resume()
            throw CancellationError()
        }
    }

    func release() {
        let next = state.withLock { Self.release(&$0) }
        next?.resume()
    }

    private static func release(_ state: inout State) -> ScopedWaiter? {
        guard !state.waiters.isEmpty else { state.held = false; return nil }
        return state.waiters.removeFirst().1
    }
}
