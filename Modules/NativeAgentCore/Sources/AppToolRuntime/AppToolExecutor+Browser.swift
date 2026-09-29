import Foundation
import ChromeControl
import Browser
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import MacControl
import NativeAgentCore
import PersistenceCore
import ToolRegistry

/// The browser family: Chrome through the extension, and the visible
/// NativeAgent browser. Every page act rereads the page on the same lease and
/// clears the same Trust gate her own call would.
extension AppToolExecutor {
    /// Page actions whose result carries the fresh page (Phase 3).
    private static let chromePageActions: Set<String> = [
        "browser.chrome_navigate", "browser.chrome_click", "browser.chrome_fill", "browser.chrome_type",
        "browser.chrome_select", "browser.chrome_keypress", "browser.chrome_set_checked",
        "browser.chrome_double_click", "browser.chrome_drag", "browser.chrome_scroll",
    ]
    /// Acts that can start a navigation: wait for it to settle before reading.
    private static let chromeMayNavigate: Set<String> = [
        "browser.chrome_click", "browser.chrome_keypress", "browser.chrome_double_click",
    ]

    public func runBrowserTool(actionId: String, input: [String: JSONValue], surface: String, host: any ToolLoading) async throws -> JSONValue {
        let dryRun = Self.inputBool(input["dryRun"] ?? input["dry_run"], default: false)
        // The browser's own back/forward chords are history, not page keys.
        if actionId == "browser.chrome_keypress",
           let history = ["Meta+[": "back", "BrowserBack": "back", "Meta+]": "forward", "BrowserForward": "forward"][Self.inputString(input["key"]) ?? ""],
           await chromeFollowUpAllowed("browser.chrome_navigate", input: input, surface: surface) {
            var go: [String: JSONValue] = ["url": .string(history)]
            if let lease = input["lease_id"] { go["lease_id"] = lease }
            return try await runBrowserTool(actionId: "browser.chrome_navigate", input: go, surface: surface, host: host)
        }
        // 09-24: a key pressed at no row. Page keys mean "move the page": that
        // is a scroll (verified by how far it moved); any other key needs a row.
        if actionId == "browser.chrome_keypress", (Self.inputString(input["node_id"]) ?? "").isEmpty {
            let key = Self.inputString(input["key"]) ?? ""
            let steps: [String: Int] = ["PageDown": 1_200, "Space": 1_200, " ": 1_200, "PageUp": -1_200, "ArrowDown": 120, "ArrowUp": -120]
            guard let delta = steps[key], await chromeFollowUpAllowed("browser.chrome_scroll", input: input, surface: surface) else {
                return .object(["ok": .bool(false), "error": .string("key_needs_row"),
                    "reason": .string("A key is pressed in a row: add node_id (its number or label, like the search box). "
                        + "To move down the page, call browser.chrome_scroll{delta_y: 1200}. Nothing was sent.")])
            }
            var scroll: [String: JSONValue] = ["delta_x": .int(0), "delta_y": .int(Int64(delta))]
            if let lease = input["lease_id"] { scroll["lease_id"] = lease }
            return try await runBrowserTool(actionId: "browser.chrome_scroll", input: scroll, surface: surface, host: host)
        }
        let origin = AppChatToolDispatcher.securityOrigin(input: input, surface: surface)
        func run(_ id: String, _ input: [String: JSONValue]) async throws -> JSONValue {
            try await ChromeControlInvocationContext.$origin.withValue(origin) {
                try await ChromeControlInvocationContext.$tool.withValue(id) {
                    try await browserActionRunner(id, dryRun, input)
                }
            }
        }
        // Her-screen Phase 3 (2026-09-23): one call instead of acquire →
        // navigate → snapshot → release. The workspace projects from the
        // structured snapshot and reads back after its own acts, so it keeps
        // the raw results.
        let direct = !dryRun && MacLookFrameStore.source != "workspace"
        var input = input
        // No tab yet (or its lease lapsed): open one for this navigate. Same
        // lease model — Chrome owns the lease, and it lapses (closing this
        // untouched tab) ~60s after the last call, so no release call is
        // needed. An X/Twitter post is given at creation: the extension opens
        // posts in its unfocused work window only from the creation URL
        // (09-24: X profiles were refused here and she had to acquire by hand).
        func openTab() async throws -> JSONValue? {
            let url = Self.inputString(input["url"]) ?? ""
            var create: [String: JSONValue] = ["mode": .string("create")]
            if ChromeControlRuntime.isXPostURL(url) { create["initial_url"] = .string(url) }
            let lease = try await run("browser.chrome_acquire", create)
            await chrome().noteAcquired(lease)
            guard case .object(let granted) = lease, case .string(let id)? = granted["leaseId"] else { return lease }
            input["lease_id"] = .string(id)
            input["expected_user_sequence"] = granted["userSequence"] ?? .int(0)
            return nil
        }
        // 09-24: the workspace's `browser.go` / `tab.N.go` open a tab the same way.
        if !dryRun, actionId == "browser.chrome_navigate", (Self.inputString(input["lease_id"]) ?? "").isEmpty,
           await !chrome().conversationTabIsLive(ChatToolSessionContext.verifiedSessionId) {
            // Opening the tab clears acquire's own gate; when that would ask,
            // say so instead of "navigate with a url opens one" to a navigate with a url.
            guard await chromeFollowUpAllowed("browser.chrome_acquire", input: input, surface: surface) else {
                return .object(["ok": .bool(false), "error": .string("tab_needs_approval"),
                    "reason": .string("This conversation has no Chrome tab, and opening one needs approval here: "
                        + "call browser.chrome_acquire, then browser.chrome_navigate{url}. Nothing was sent.")])
            }
            if ["back", "forward"].contains(Self.inputString(input["url"]) ?? "") {
                return .object(["ok": .bool(false), "error": .string("no_tab_history"),
                    "reason": .string("This conversation has no Chrome tab yet, so there is no page to go back or forward to. Nothing was sent.")])
            }
            if let refused = try await openTab() { return refused }
        }
        if direct, actionId == "browser.chrome_snapshot", input["max_nodes"] == nil || input["max_nodes"] == .null {
            input["max_nodes"] = .int(150)
        }
        // Never act on an X/Twitter post from a background lease (Sol, 09-23):
        // the page may have navigated or redirected there after creation.
        if Self.chromePageActions.contains(actionId), actionId != "browser.chrome_navigate",
           await chrome().actionBlockedOnPost(
               leaseID: Self.inputString(input["lease_id"]), verifiedSessionID: ChatToolSessionContext.verifiedSessionId) {
            return .object(["ok": .bool(false), "error": .string("post_needs_visible_window"),
                            "reason": .string(Self.postOnBackgroundNote + " Nothing was sent.")])
        }
        // 09-24: a row by its label, a missing snapshot_id, option labels —
        // from the last page read on this tab; a form in one call (fields).
        if let refusal = Self.resolveChromeTarget(actionId, &input) { return refusal }
        if !dryRun, ["browser.chrome_fill", "browser.chrome_navigate"].contains(actionId), let fields = Self.chromeFields(input) {
            return try await runChromeFieldsCall(actionId: actionId, input: input, fields: fields, direct: direct, surface: surface, host: host, run: run)
        }
        // A keypress is judged by what it did: the page it acted on, as read.
        // and a scroll shows only the rows it brought into view.
        let lastRead = ChromePageMirror.page(lease: Self.inputString(input["lease_id"]), session: ChatToolSessionContext.verifiedSessionId)
        let before = ["browser.chrome_keypress", "browser.chrome_click", "browser.chrome_double_click"].contains(actionId)
            ? lastRead.flatMap { $0.snapshotID == Self.inputString(input["snapshot_id"]) ? $0 : nil }
            : actionId == "browser.chrome_scroll" ? lastRead : nil
        // A lease that lapsed fails with its reason and the one next call
        // (ChromeControlRuntimeError); it is never swapped for a fresh tab.
        let result = try await run(actionId, input)
        Self.mirrorChromePage(result, releasedBy: actionId, input: input)
        if actionId == "browser.chrome_acquire" { await chrome().noteAcquired(result) }
        if !dryRun, ["browser.chrome_navigate", "browser.chrome_acquire"].contains(actionId) {
            await preloadBrowserTools(input, surface: surface, host: host)
        }
        guard case .object(var obj) = result else {
            return result
        }
        // Navigate and snapshot results carry the page's current URL.
        var postWarning = ""
        if case .string(let url)? = obj["url"], case .string(let lease)? = obj["leaseId"],
           await chrome().notePage(url: url, leaseID: lease) {
            postWarning = "\n" + Self.postOnBackgroundNote
        }
        if direct, actionId == "browser.chrome_snapshot", let page = ChromePageText.render(result) {
            return .string(page + postWarning)
        }
        if direct, Self.chromePageActions.contains(actionId), case .object(let receipt)? = obj["receipt"],
           case .string(let lease)? = receipt["leaseId"] {
            var page = await freshChromePage(after: actionId, lease: lease,
                sequence: receipt["userSequence"], input: input, surface: surface, run: run)
            if actionId == "browser.chrome_scroll", let before {
                // A feed can lag the scroll: a move that shows nothing new
                // re-reads for up to 1.5 s before saying so.
                let moved: Bool = switch obj["movedY"] { case .int(let n)?: n != 0; case .double(let n)?: n != 0; default: false }
                var diff = Self.onlyNewRows(page, before: before.text)
                for _ in 0..<3 where moved && diff.new == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    page = await freshChromePage(after: actionId, lease: lease,
                        sequence: receipt["userSequence"], input: input, surface: surface, run: run)
                    diff = Self.onlyNewRows(page, before: before.text)
                }
                page = moved && diff.new == 0 ? Self.onlyNewRows(page, before: before.text, stalled: true, personHere: !macPersonAway()).text : diff.text
            }
            // A plain success reads as the receipt line then the page; any
            // other outcome keeps its object so failure classing still sees it.
            if obj["outcome"] == .string("succeeded") {
                if actionId != "browser.chrome_scroll", let before, Self.chromePageUnchanged(before: before.text, after: page) {
                    let verb = actionId.replacingOccurrences(of: "browser.chrome_", with: "").replacingOccurrences(of: "_", with: " ")
                    // The read is the main content in view: a cart count or toast
                    // elsewhere may have changed, so never an invitation to repeat.
                    return .string(verb + " unverified: it reached the page but nothing in the part read moved or changed; "
                        + "it may have acted elsewhere, so check before repeating it"
                        + (actionId == "browser.chrome_keypress" ? ". To move down the page, call browser.chrome_scroll{delta_y}." : ".") + "\n\n" + page)
                }
                return .string(Self.chromeReceiptLine(actionId, obj) + "\n\n" + page)
            }
            // The page is attached: "take a fresh snapshot" no longer applies.
            if !page.hasPrefix("No page attached"), !page.hasPrefix("The fresh page could not"),
               case .object(var receipt)? = obj["receipt"], receipt["retry"] == .string("fresh_snapshot_required") {
                receipt.removeValue(forKey: "retry"); obj["receipt"] = .object(receipt)
            }
            obj["page"] = .string(page)
        }
        obj["tool"] = .string(actionId)
        obj["provider_alias"] = .string(Self.providerAlias(for: actionId))
        obj["surface"] = .string(surface)
        return .object(obj)
    }

    /// The slim page after an act, read on the same lease.
    public func freshChromePage(
        after actionId: String, lease: String, sequence: JSONValue?, input: [String: JSONValue], surface: String,
        run: (String, [String: JSONValue]) async throws -> JSONValue
    ) async -> String {
        guard await chromeFollowUpAllowed("browser.chrome_snapshot", input: input, surface: surface) else {
            return "No page attached: reading the page needs your approval here. Call browser.chrome_snapshot."
        }
        if Self.chromeMayNavigate.contains(actionId),
           await chromeFollowUpAllowed("browser.chrome_wait", input: input, surface: surface) {
            // Twice at most: a quiet window can close before a slow load starts.
            for _ in 0..<2 {
                let waited = try? await run("browser.chrome_wait", [
                    "lease_id": .string(lease), "expected_user_sequence": sequence ?? .null,
                    "condition": .string("navigation_settled"), "settle_ms": .int(400), "timeout_ms": .int(8_000),
                ])
                guard case .object(let wait)? = waited, wait["outcome"] == .string("not_settled") else { break }
            }
        }
        do {
            // 09-24: the page's main content by default (the benches re-read
            // it after every navigate); the whole page when it has none. A
            // scope she named is read as named.
            let scope = Self.inputString(input["scope"])
            let read: [String: JSONValue] = ["lease_id": .string(lease), "max_nodes": .int(150),
                "scope": .string(scope == "page" ? "page" : "main_content")]
            func readPage() async throws -> JSONValue {
                let main = try await run("browser.chrome_snapshot", read)
                return scope == nil ? try await Self.wholePageIfNoMain(main, input: read, run: run) : main
            }
            var snapshot = try await readPage()
            // 09-24 (X profile): a first read that is only a spinner waits for
            // real content, 3 s at most.
            for _ in 0..<4 where Self.chromeStillLoading(snapshot) {
                try? await Task.sleep(nanoseconds: 750_000_000)
                snapshot = try await readPage()
            }
            Self.mirrorChromePage(snapshot)
            guard let page = ChromePageText.render(snapshot) else {
                return "The fresh page could not be read. Call browser.chrome_snapshot."
            }
            if case .object(let read) = snapshot, case .string(let url)? = read["url"],
               await chrome().notePage(url: url, leaseID: lease) {
                return page + "\n" + Self.postOnBackgroundNote
            }
            return page
        } catch {
            return "The fresh page could not be read (" + ChromePageText.safe(error.localizedDescription)
                + "). Call browser.chrome_snapshot."
        }
    }

    public static let postOnBackgroundNote = "This background tab is now on an X/Twitter post; actions on it are refused. "
        + "To act on the post, open it with browser.chrome_acquire (mode create, initial_url = the post), "
        + "which uses the visible work window."

    /// A read the app makes on her behalf clears the same Trust gate her own
    /// call would; anything that would ask or is blocked is simply not made.
    public func chromeFollowUpAllowed(_ tool: String, input: [String: JSONValue], surface: String) async -> Bool {
        let envelope = await securityCenter.evaluateTool(
            tool: tool, input: [:], origin: AppChatToolDispatcher.securityOrigin(input: input, surface: surface),
            enforceAutonomy: enforceAutonomySecurity)
        try? await securityCenter.record(envelope)
        return envelope.decision != .block && !envelope.requiresApproval
    }

    /// A page is open: its hands (click/fill/type/select/keypress) load now, so
    /// the next reply can use them without a tool_load call.
    public func preloadBrowserTools(_ input: [String: JSONValue], surface: String, host: any ToolLoading) async {
        let session = [ChatToolSessionContext.verifiedSessionId, LLMCallContext.sessionId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? Self.extractSessionId(input)
        guard !session.isEmpty, let group = ToolPreloadHeuristics.loadGroup(forCategory: "browser") else { return }
        await host.loadTools(group.tools.sorted(), sessionId: session, surface: surface)
    }

    public static func providerAlias(for name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    public static func defaultBrowserActionRunner(
        actionId: String,
        dryRun: Bool,
        input: [String: JSONValue],
        chrome: @Sendable () -> ChromeControlRuntime,
        macPersonAway: @Sendable () -> Bool,
        motorActionObserver: @Sendable (MotorActionReadModel) async -> Void,
        platform: BrowserToolPlatformPort
    ) async throws -> JSONValue {
        if actionId == "browser.chrome_status" || actionId == "browser.chrome_setup" {
            var result: [String: JSONValue] = [:]
            if actionId == "browser.chrome_setup", !dryRun {
                let setup = await platform.setUpChrome()
                result["folder"] = setup.folder.map { .string($0.path) } ?? .null
                result["extensions_page_opened"] = .bool(setup.extensionsPageOpened)
                result["message"] = .string(setup.message)
            }
            let status = await chrome().setupConnectionStatus()
            result.merge(chromeSetupStatusJSON(state: status.state, enabled: status.enabled)) { _, new in new }
            result["dry_run"] = .bool(dryRun)
            return .object(result)
        }
        if actionId.hasPrefix("browser.chrome_") {
            guard !dryRun else {
                return .object(["status": .string("dry_run"), "action": .string(actionId)])
            }
            return try await runChromeControlTool(actionId: actionId, input: input, chrome: chrome, macPersonAway: macPersonAway, motorActionObserver: motorActionObserver)
        }
        if actionId == "browser.status" {
            return try await platform.readStatus()
        }
        return try await platform.runNativeAction(actionId, dryRun, input)
    }

    public static func chromeSetupStatusJSON(state: ChromeControlConnectionState, enabled: Bool) -> [String: JSONValue] {
        let connection: String
        switch state {
        case .connected: connection = "connected"
        case .disconnected: connection = "previously_connected"
        case .extensionNotLoaded: connection = "not_yet_connected"
        }
        return [
            "next": state == .connected ? .null : .string("raise request_interaction kind=connector target=chrome"),
            "connection": .string(connection),
            "connected": .bool(state == .connected),
            "chrome_control_enabled": .bool(enabled),
            "permissions_changed": .bool(false),
            "status_note": .string("Only a live connection confirms availability. A prepared folder or previous connection does not prove the extension is currently loaded. Chrome control permission remains unchanged."),
        ]
    }

    public static func runChromeControlTool(
        actionId: String,
        input: [String: JSONValue],
        chrome: @Sendable () -> ChromeControlRuntime,
        macPersonAway: @Sendable () -> Bool,
        motorActionObserver: @Sendable (MotorActionReadModel) async -> Void
    ) async throws -> JSONValue {
        if actionId == "browser.chrome_select" {
            guard case .array(let values)? = input["values"],
                  values.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                return .object([
                    "ok": .bool(false), "error": .string("invalid_values"),
                    "reason": .string("values must be an array of strings; no selection was dispatched."),
                ])
            }
        }
        // 2026-09-22: a loading tab's title is legitimately "", so only the URL is required.
        if actionId == "browser.chrome_acquire", inputString(input["mode"]) == "claim",
           (inputString(input["expected_url"]) ?? "").isEmpty {
            return .object([
                "ok": .bool(false), "error": .string("invalid_payload"),
                "reason": .string("Claiming a tab needs expected_url, that tab's exact address. To just open a page, use browser.chrome_navigate{url}; nothing was sent."),
            ])
        }
        let (effect, requestPayload) = try chromeControlRequest(actionId: actionId, input: input, macPersonAway: macPersonAway)
        var payload = requestPayload
        // Missing optional proof may use this chat's observed sequence. An
        // explicit invalid value remains invalid; never repair a supplied proof.
        if (input["expected_user_sequence"] == nil || input["expected_user_sequence"] == .null),
           payload["expectedUserSequence"] != nil {
            payload.removeValue(forKey: "expectedUserSequence")
        }
        let response = try await chrome().performInConversation(
            effect, payload: payload, verifiedSessionID: ChatToolSessionContext.verifiedSessionId)
        guard case .object(let object) = response,
              let result = object["result"] else { throw ChromeControlRuntimeError.invalidResponse }
        // Admit the extension's actual action receipt as a motor consequence.
        if let model = chromeReceiptMotorActionReadModel(result) {
            await motorActionObserver(model)
        }
        return result
    }

    /// Pure provider-input boundary; optional empty strings mean omitted, not
    /// a request to override the extension's route selection.
    public static func chromeControlRequest(
        actionId: String,
        input: [String: JSONValue],
        macPersonAway: @Sendable () -> Bool
    ) throws -> (ChromeControlEffect, [String: JSONValue]) {
        let effect: ChromeControlEffect
        var payload: [String: JSONValue] = [:]
        func string(_ key: String) -> String? {
            // Phase 3: the slim page numbers rows by node id, so `12` (or
            // "12") names node "n12". Anything else passes through unchanged.
            if key.hasSuffix("node_id") {
                if case .int(let row)? = input[key] { return "n\(row)" }
                if let raw = inputString(input[key]), !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber) {
                    return "n" + raw
                }
            }
            return inputString(input[key])
        }
        func integer(_ key: String) -> Int? {
            switch input[key] {
            case .int(let value): return Int(value)
            case .double(let value): return Int(exactly: value.rounded(.towardZero))
            case .string(let value): return Int(value)
            default: return nil
            }
        }
        switch actionId {
        case "browser.chrome_acquire":
            effect = .acquire
            let mode = string("mode") ?? "create"
            payload["mode"] = .string(mode)
            // 09-24: acquire{url} opened a blank tab (the page agent then had no
            // top frame); `url` is the address she means. An empty pair is absent.
            if let value = [string("initial_url"), string("url")].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                payload["initialUrl"] = .string(value)
                // Only initial_url takes the X-post visible window by default;
                // `url` stays a background tab unless she asks for a visible one.
                if (string("initial_url") ?? "").isEmpty, mode == "create" {
                    payload["renderingMode"] = .string("grouped_background")
                }
            }
            if let value = string("rendering_mode"),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Preserve nonempty values exactly: the extension owns enum
                // validation and must still reject invalid explicit choices.
                payload["renderingMode"] = .string(value)
            }
            // 09-24: five minutes, sliding (every call renews it), so a live
            // task never loses its tab; an idle tab still lapses on its own.
            payload["leaseDurationMs"] = .int(Int64(integer("lease_duration_ms") ?? 300_000))
            if mode == "claim" {
                if let value = integer("tab_id") { payload["tabId"] = .int(Int64(value)) }
                payload["expectedTab"] = .object([
                    "url": .string(string("expected_url") ?? ""),
                    "title": .string(string("expected_title") ?? ""),
                ])
            }
        case "browser.chrome_renew":
            effect = .renew
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
            ]
            if let value = integer("lease_duration_ms") { payload["leaseDurationMs"] = .int(Int64(value)) }
        case "browser.chrome_navigate":
            effect = .navigate
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "url": .string(string("url") ?? ""),
            ]
        case "browser.chrome_snapshot":
            effect = .snapshot
            payload["leaseId"] = .string(string("lease_id") ?? "")
            // 2026-09-22: sent explicitly so an already-installed extension
            // (old 500 / 50,000 defaults) also gets the smaller page.
            // 2026-09-23 (Phase 3): up to 200 for the slim text page (~90
            // bytes a row); a caller that omits it still gets 80.
            payload["maxNodes"] = .int(Int64(min(integer("max_nodes") ?? 80, 200)))
            payload["maxTextChars"] = .int(Int64(min(integer("max_text_chars") ?? 12_000, 40_000)))
            if let value = string("scope") { payload["scope"] = .string(value) }
        case "browser.chrome_click":
            effect = .click
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
            ]
        case "browser.chrome_fill":
            effect = .fill
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "value": .string(string("value") ?? ""),
            ]
        case "browser.chrome_type":
            effect = .type
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "text": .string(string("text") ?? ""),
            ]
            if let value = integer("delay_ms") { payload["delayMs"] = .int(Int64(value)) }
        case "browser.chrome_select":
            effect = .select
            guard case .array(let values)? = input["values"],
                  values.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "values": .array(values),
            ]
        case "browser.chrome_keypress":
            effect = .keypress
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "key": .string(string("key") ?? ""),
            ]
        case "browser.chrome_set_checked":
            effect = .setChecked
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "checked": .bool(inputBool(input["checked"], default: false)),
            ]
        case "browser.chrome_double_click":
            effect = .doubleClick
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
            ]
        case "browser.chrome_drag":
            effect = .drag
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "targetNodeId": .string(string("target_node_id") ?? ""),
            ]
        case "browser.chrome_wait":
            effect = .wait
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "condition": .string(string("condition") ?? ""),
            ]
            if let value = string("snapshot_id") { payload["snapshotId"] = .string(value) }
            if let value = string("node_id") { payload["nodeId"] = .string(value) }
            if let value = string("state") { payload["state"] = .string(value) }
            // 09-24: a long wait asked for is the longest one allowed, not a refusal.
            if let value = integer("timeout_ms") { payload["timeoutMs"] = .int(Int64(min(max(value, 100), 10_000))) }
            if let value = integer("settle_ms") { payload["settleMs"] = .int(Int64(min(max(value, 0), 2_000))) }
        case "browser.chrome_scroll":
            effect = .scroll
            payload = [
                // 09-24 (User): a background tab renders for a scroll only while
                // he is away — its debugging bar never shows while he works.
                "renderHidden": .bool(macPersonAway()),
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "deltaX": .int(Int64(integer("delta_x") ?? 0)),
                "deltaY": .int(Int64(integer("delta_y") ?? 0)),
            ]
            // Some provider calls serialize absent optional strings as an empty
            // pair. Normalize only that pair; never discard a partial target.
            let snapshotID = string("snapshot_id")
            let targetID = string("target_node_id")
            if !(snapshotID ?? "").isEmpty || !(targetID ?? "").isEmpty {
                if let snapshotID { payload["snapshotId"] = .string(snapshotID) }
                if let targetID { payload["targetNodeId"] = .string(targetID) }
            }
        case "browser.chrome_release":
            effect = .release
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "closeCreatedTab": .bool(inputBool(input["close_created_tab"], default: true)),
            ]
        default:
            throw ChromeControlRuntimeError.invalidResponse
        }
        return (effect, payload)
    }

    /// The Chrome per-action receipt, in the shared motor vocabulary.
    ///
    /// `domainState` keeps the extension's exact word, because the phase
    /// vocabulary has no "partially completed" and collapsing that into either
    /// succeeded or failed would erase the one distinction the receipt exists
    /// to make.
    public static func chromeReceiptMotorActionReadModel(_ result: JSONValue) -> MotorActionReadModel? {
        guard case .object(let payload) = result,
              case .object(let receipt)? = payload["receipt"],
              case .string(let actionIdentity)? = receipt["id"],
              !actionIdentity.isEmpty,
              case .string(let outcome)? = receipt["outcome"] else { return nil }
        // The phases are MacControl's own mapping, deliberately
        // (`MacControlOperationStore.motorPhase`): refused is `.blocked`, and
        // an unknown outcome is `.waitingExternal` — evidence is owed, the act
        // is not finished. `.unknown` is NOT available here: the cognitive
        // event factory returns nil for it, which would silently drop the very
        // receipts this fix exists to admit.
        let phase: MotorActionPhase
        switch outcome {
        case "succeeded": phase = .succeeded
        case "refused": phase = .blocked
        default: phase = .waitingExternal
        }
        let verification: MotorVerificationState
        switch receipt["verification"] {
        // 2026-09-06: `page_acknowledged` is the page saying it received the
        // act, not anybody observing that it happened — the extension's own
        // protocol keeps the two apart. A click on a control that ignored it
        // acknowledges just as loudly, so this is evidence still owed
        // (`.pending`), never verification satisfied.
        case .string("page_acknowledged"): verification = .pending
        case .string("not_verified"):
            // 2026-09-06: `not_quiet` is a navigation that was still moving
            // when the wait's deadline arrived — evidence still OWED, not a
            // checked negative. `.pending`, so the turn reads it as unfinished
            // and looks again rather than concluding the page did not settle.
            verification = outcome == "not_quiet" ? .pending : .unverified
        default: verification = .unknown
        }
        let expectedNextEvidence: String
        switch receipt["retry"] {
        case .string("never_automatic"):
            expectedNextEvidence = "A human look at the page. This outcome is unknown and must "
                + "never be retried automatically."
        case .string("fresh_snapshot_then_remaining_text_only"):
            expectedNextEvidence = "A fresh Chrome snapshot, then only the characters that did "
                + "not land."
        default:
            expectedNextEvidence = "A fresh Chrome snapshot; node ids from the old one are stale."
        }
        var updatedAt: String?
        if case .string(let completedAt)? = receipt["completedAt"] { updatedAt = completedAt }
        return MotorActionReadModel(
            domain: "chrome_control",
            // Hashed, like every other domain's identity: the cognitive event
            // factory only accepts a 64-char digest, and the raw receipt id is
            // a UUID. Handing it over unhashed would have been dropped in
            // silence — the same failure with a longer path.
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(actionIdentity),
            phase: phase,
            domainState: outcome,
            verification: verification,
            expectedNextEvidence: expectedNextEvidence,
            updatedAt: updatedAt
        )
    }

    private static func inputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        switch raw {
        case .bool(let b):
            return b
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                return defaultValue
            }
        case .int(let i):
            return i != 0
        case .double(let d):
            return d != 0
        default:
            return defaultValue
        }
    }
}
