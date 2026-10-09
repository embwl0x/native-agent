import Foundation
import AppKit
import ChromeControl
import Browser
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import MacControl
import NativeAgentCore
import PersistenceCore
import Privacy
import ToolRegistry
import Senses
import SQLite3
import TrustCenter

/// The browser family: Chrome through the extension, and the visible
/// NativeAgent browser. Every page act rereads the page on the same tab and
/// clears the same Trust gate her own call would.
extension AppToolExecutor {
    @MainActor
    func runChromeHistory(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard let mode = Self.inputString(input["mode"]), ["top_domains", "search", "recent"].contains(mode) else {
            return Self.failure("invalid_mode", "mode must be top_domains, search or recent.")
        }
        let query = Self.inputString(input["query"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mode == "search", query.isEmpty { return Self.failure("missing_query", "search requires nonempty query text to match titles or URLs.") }
        var since: Date?
        if let value = input["since"] {
            guard case .string(let text) = value, let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) else {
                return Self.failure("invalid_since", "since must be an ISO 8601 timestamp with a timezone.")
            }
            since = date
        }
        if mode == "top_domains", since == nil { return Self.failure("missing_since", "top_domains requires since, the inclusive start of the visit-count period.") }
        let limit: Int64
        switch input["limit"] {
        case nil: limit = 15
        case .int(let value)? where value > 0: limit = min(value, 50)
        default: return Self.failure("invalid_limit", "limit must be a positive integer; default 15, maximum 50.")
        }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        let origin = AppChatToolDispatcher.securityOrigin(input: input, surface: surface)
        let envelope = await securityCenter.evaluateTool(tool: "read_file", input: ["path": .string(source.path)],
            origin: origin, enforceAutonomy: enforceAutonomySecurity)
        try await securityCenter.record(envelope)
        let admission = await securityCenter.fullMacYoloAuthority(tool: "mac_control", origin: origin)
        guard admission.admitted, envelope.fullMacYoloAuthority == .admitted,
              envelope.decision != .block, !envelope.requiresApproval else {
            return Self.failure("history_read_denied", "Chrome history requires admitted Full Mac and file-read permission. Check Trust and file access at the Mac; no history was read and no card was raised.")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil else {
            return .object(["status": .string("absent"), "detail": .string("Google Chrome is not installed on this Mac.")])
        }
        let start = since.map { ($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000 } ?? 0
        return try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            func checked(_ url: URL) throws -> URL {
                let resolved = url.resolvingSymlinksInPath()
                if let reason = MacControlSensitivePathFence.reason(forPath: url.path)
                    ?? MacControlSensitivePathFence.reason(forPath: resolved.path) {
                    throw MacControlError.sensitivePathDenied(reason)
                }
                let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw MacControlError.ioFailure("Chrome History must be a regular file.") }
                return resolved
            }
            // Attribute reads distinguish absence from a permission failure.
            let history: URL
            do { history = try checked(source) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return .object(["status": .string("absent"), "detail": .string("Chrome's Default profile History is absent on this Mac.")])
            }
            let folder = fm.temporaryDirectory.appendingPathComponent("chrome-history-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            func readCopy() throws -> JSONValue {
                let copy = folder.appendingPathComponent("History")
                try fm.copyItem(at: history, to: copy)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                // WAL holds committed visits that may not yet be in History.
                let wal = URL(fileURLWithPath: source.path + "-wal")
                do {
                    let checkedWAL = try checked(wal)
                    try fm.copyItem(at: checkedWAL, to: URL(fileURLWithPath: copy.path + "-wal"))
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path + "-wal")
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
                var db: OpaquePointer?
                let opened = sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                defer { sqlite3_close(db) }
                func failure(_ code: Int32) -> Error {
                    MacControlError.ioFailure(code == SQLITE_INTERRUPT
                        ? "Chrome history query exceeded its 2-second deadline; narrow since or query."
                        : "Chrome history could not be read: " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"))
                }
                guard opened == SQLITE_OK else { throw failure(opened) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let domainFunction = sqlite3_create_function_v2(db, "history_domain", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
                    guard let text = sqlite3_value_text(values?[0]), let url = URL(string: String(cString: text)),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else {
                        sqlite3_result_null(context); return
                    }
                    sqlite3_result_text(context, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }, nil, nil, nil)
                guard domainFunction == SQLITE_OK else { throw failure(domainFunction) }
                let matchFunction = sqlite3_create_function_v2(db, "history_matches", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
                    func text(_ index: Int) -> String { sqlite3_value_text(values?[index]).map { String(cString: $0) } ?? "" }
                    let query = text(2)
                    sqlite3_result_int(context, text(0).range(of: query, options: .caseInsensitive) != nil
                        || text(1).range(of: query, options: .caseInsensitive) != nil ? 1 : 0)
                }, nil, nil, nil)
                guard matchFunction == SQLITE_OK else { throw failure(matchFunction) }
                let sql = mode == "top_domains"
                    ? "SELECT history_domain(u.url) AS domain, count(*), max(v.visit_time) FROM visits v JOIN urls u ON u.id = v.url WHERE v.visit_time >= ?1 AND domain IS NOT NULL GROUP BY domain ORDER BY count(*) DESC, max(v.visit_time) DESC, domain LIMIT ?3"
                    : "SELECT title, url, last_visit_time, visit_count FROM urls WHERE last_visit_time > 0 AND last_visit_time >= ?1"
                        + (mode == "search" ? " AND history_matches(title, url, ?2)" : "") + " ORDER BY last_visit_time DESC, id DESC LIMIT ?3"
                var statement: OpaquePointer?
                let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
                defer { sqlite3_finalize(statement) }
                guard prepared == SQLITE_OK else { throw failure(prepared) }
                sqlite3_bind_double(statement, 1, start)
                if mode == "search" { sqlite3_bind_text(statement, 2, query, -1, transient) }
                sqlite3_bind_int64(statement, 3, limit)
                let iso = ISO8601DateFormatter()
                iso.timeZone = .current
                func date(_ column: Int32) -> JSONValue {
                    .string(iso.string(from: Date(timeIntervalSince1970: sqlite3_column_double(statement, column) / 1_000_000 - 11_644_473_600)))
                }
                func text(_ column: Int32) -> JSONValue {
                    .string(UntrustedText.neutralized(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""))
                }
                var deadline = ProcessInfo.processInfo.systemUptime + 2
                return try withUnsafeMutablePointer(to: &deadline) { deadline in
                    sqlite3_progress_handler(db, 1000, { context in
                        guard let context else { return 1 }
                        return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
                    }, deadline)
                    defer { sqlite3_progress_handler(db, 0, nil, nil) }
                    var rows: [JSONValue] = []
                    var step = sqlite3_step(statement)
                    while step == SQLITE_ROW {
                        rows.append(mode == "top_domains"
                            ? .object(["domain": text(0), "visit_count": .int(sqlite3_column_int64(statement, 1)), "last_visit": date(2)])
                            : .object(["title": text(0), "url": text(1), "last_visit": date(2), "visit_count": .int(sqlite3_column_int64(statement, 3))]))
                        step = sqlite3_step(statement)
                    }
                    guard step == SQLITE_DONE else { throw failure(step) }
                    return .object(["status": .string("ok"), "mode": .string(mode), "rows": .array(rows),
                        "count": .int(Int64(rows.count)), "limit": .int(limit), "at_limit": .bool(rows.count == limit),
                        "coverage": .string("Copied Chrome Default profile history; excludes incognito and deleted history. Top-domain counts cover visits since since; page visit counts are lifetime totals. Times are local ISO 8601; at_limit means more rows may exist.")])
                }
            }
            let result: JSONValue
            do { result = try readCopy() }
            catch { try fm.removeItem(at: folder); throw error }
            try fm.removeItem(at: folder)
            return result
        }.value
    }

    /// Page actions whose result carries the fresh page (Phase 3).
    private static let chromePageActions: Set<String> = [
        "browser.chrome_navigate", "browser.chrome_click", "browser.chrome_fill", "browser.chrome_type",
        "browser.chrome_select", "browser.chrome_keypress", "browser.chrome_set_checked",
        "browser.chrome_double_click", "browser.chrome_drag", "browser.chrome_scroll",
    ]
    /// Acts that can start a navigation: wait for it to settle before reading.
    private static let chromeMayNavigate: Set<String> = [
        "browser.chrome_navigate", "browser.chrome_click", "browser.chrome_keypress", "browser.chrome_double_click",
    ]

    public func runBrowserTool(actionId: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let dryRun = Self.inputBool(input["dryRun"] ?? input["dry_run"], default: false)
        // The browser's own back/forward chords are history, not page keys.
        if actionId == "browser.chrome_keypress",
           let history = ["Meta+[": "back", "BrowserBack": "back", "Meta+]": "forward", "BrowserForward": "forward"][Self.inputString(input["key"]) ?? ""],
           await chromeFollowUpAllowed("browser.chrome_navigate", input: input, surface: surface) {
            var go: [String: JSONValue] = ["url": .string(history)]
            for key in ["tab_id", "dryRun", "dry_run", "expected_user_sequence"] { go[key] = input[key] }
            return try await runBrowserTool(actionId: "browser.chrome_navigate", input: go, surface: surface)
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
            for key in ["tab_id", "dryRun", "dry_run", "expected_user_sequence"] { scroll[key] = input[key] }
            return try await runBrowserTool(actionId: "browser.chrome_scroll", input: scroll, surface: surface)
        }
        let origin = AppChatToolDispatcher.securityOrigin(input: input, surface: surface)
        func run(_ id: String, _ input: [String: JSONValue]) async throws -> JSONValue {
            let result = try await ChromeControlInvocationContext.$origin.withValue(origin) {
                try await ChromeControlInvocationContext.$tool.withValue(id) {
                    try await browserActionRunner(id, dryRun, input)
                }
            }
            let read = id == "browser.chrome_snapshot" && !dryRun ? try await ChromePageText.readDocument(result) : result
            if !dryRun, id == "browser.chrome_snapshot", ChromePageText.render(read) != nil {
                PeerDataTaint.markConsumed(peer: "web content", attested: false)
            }
            return read
        }
        // Direct calls include the fresh page; workspace calls keep structured results.
        let direct = !dryRun && MacLookFrameStore.source != "workspace"
        var input = input
        if actionId == "browser.chrome_snapshot", let more = Self.inputString(input["more"]), more.hasPrefix("site:") {
            let scope = ChatToolSessionContext.verifiedSessionId ?? ""
            let grown = SenseDoorViews.shared.latest.reversed().first {
                $0.scope == scope && $0.record.language != .native && $0.page.more == more
                    && (input["tab_id"] == nil || $0.readInput["tab_id"] == input["tab_id"])
            }
            if let grown, let current = try await SensesHub.shared.registry?.sense(for: grown.page.corner),
               current.id == grown.record.id, current.version == grown.record.version, current.status == .on {
                input = grown.readInput.filter { !$0.key.hasPrefix("__") && !["raw", "wrong", "why"].contains($0.key) }
                    .merging(input) { _, supplied in supplied }
                let saved = try SenseNativePages.chromeContinuationArguments(more, scope: scope, tab: Self.chromeTabID(input["tab_id"]))
                input.merge(saved) { _, stored in stored }
                input["__sense_address"] = .string(more)
            } else {
                let saved = try SenseNativePages.chromeContinuationArguments(more, scope: scope, tab: Self.chromeTabID(input["tab_id"]))
                input.merge(saved) { _, stored in stored }
            }
        }
        if direct, actionId == "browser.chrome_snapshot", input["max_nodes"] == nil || input["max_nodes"] == .null {
            if await chrome().conversationSnapshotView(ChatToolSessionContext.verifiedSessionId,
                tabID: Self.chromeTabID(input["tab_id"])) == nil {
                input["max_nodes"] = .int(150)
            }
        }
        // 09-24: a row by its label, a missing snapshot_id, option labels —
        // from the last page read on this tab; a form in one call (fields).
        if let refusal = Self.resolveChromeTarget(actionId, &input) { return refusal }
        if !dryRun, ["browser.chrome_fill", "browser.chrome_navigate"].contains(actionId), let fields = Self.chromeFields(input) {
            return try await runChromeFieldsCall(actionId: actionId, input: input, fields: fields, direct: direct, surface: surface, run: run)
        }
        // A keypress is judged by what it did: the page it acted on, as read.
        // and a scroll shows only the rows it brought into view.
        let lastRead = ChromePageMirror.page(tab: Self.chromeTabID(input["tab_id"]), session: ChatToolSessionContext.verifiedSessionId)
        let before = ["browser.chrome_keypress", "browser.chrome_click", "browser.chrome_double_click"].contains(actionId)
            ? lastRead.flatMap { $0.snapshotID == Self.inputString(input["snapshot_id"]) ? $0 : nil }
            : actionId == "browser.chrome_scroll" ? lastRead : nil
        let visibleRead = !dryRun && ["browser.read_text", "browser.read_links"].contains(actionId)
            ? RetainedBrowserRead() : nil
        // A stale click refuses as the extension said ("the page changed"): a
        // fresh node matched only by role and label is not the same control.
        let result = try await BrowserActionRoutes.$retainRead.withValue(visibleRead.map { retained in
            { @Sendable capture in retained.remember(capture) }
        }) { try await run(actionId, input) }
        Self.mirrorChromePage(result, closedBy: actionId, input: input)
        guard case .object(var obj) = result else {
            return result
        }
        if direct, actionId == "browser.chrome_snapshot", let page = ChromePageText.render(result) {
            return try await browserSenseRead(snapshot: result, raw: .string(page), input: input)
        }
        if direct, Self.chromePageActions.contains(actionId), case .object(let receipt)? = obj["receipt"],
           case .int(let tab)? = receipt["tabId"] {
            var latestSnapshot: JSONValue?
            func readRun(_ id: String, _ args: [String: JSONValue]) async throws -> JSONValue {
                if id == "browser.chrome_snapshot" { latestSnapshot = nil }
                let result = try await run(id, args)
                if id == "browser.chrome_snapshot" { latestSnapshot = result }
                return result
            }
            var page = await freshChromePage(after: actionId, tab: tab,
                sequence: receipt["userSequence"], input: input, surface: surface,
                scrollCursor: actionId == "browser.chrome_scroll" ? obj["readCursor"] : nil, run: readRun)
            if actionId == "browser.chrome_scroll", let before {
                // Text already read is not proof that the viewport stayed the
                // same. The page compares the exact scrolled viewport during
                // this read, including any load after the action's reply.
                let viewportChanged: Bool?
                if case .object(let snapshot)? = latestSnapshot,
                   case .object(let reading)? = snapshot["reading"],
                   case .bool(let changed)? = reading["viewportChanged"] {
                    viewportChanged = changed
                } else {
                    viewportChanged = nil
                }
                page = Self.onlyNewRows(page, before: before.text, viewportChanged: viewportChanged).text
            }
            // Verification compares the original page. Senses change only the
            // view returned to her, after those comparisons have been made.
            let displayed: JSONValue
            if let latestSnapshot {
                displayed = try await browserSenseRead(snapshot: latestSnapshot, raw: .string(page), input: input)
            } else {
                displayed = SenseDoor.signedRaw(.string(page), line: "raw view · builtin-chrome · action readback unavailable")
            }
            // Keep the page envelope intact, including its exact continuation.
            if obj["outcome"] == .string("succeeded") {
                if actionId != "browser.chrome_scroll", let before, Self.chromePageUnchanged(before: before.text, after: page) {
                    let verb = actionId.replacingOccurrences(of: "browser.chrome_", with: "").replacingOccurrences(of: "_", with: " ")
                    // The read is the main content in view: a cart count or toast
                    // elsewhere may have changed, so never an invitation to repeat.
                    obj["readback_note"] = .string(verb + " unverified: it reached the page but nothing in the part read moved or changed; "
                        + "it may have acted elsewhere, so check before repeating it"
                        + (actionId == "browser.chrome_keypress" ? ". To move down the page, call browser.chrome_scroll{delta_y}." : "."))
                } else {
                    obj["readback_note"] = .string(Self.chromeReceiptLine(actionId, obj))
                }
            }
            // The page is attached: "take a fresh snapshot" no longer applies.
            if !page.hasPrefix("No page attached"), !page.hasPrefix("The fresh page could not"),
               case .object(var receipt)? = obj["receipt"], receipt["retry"] == .string("fresh_snapshot_required") {
                receipt.removeValue(forKey: "retry"); obj["receipt"] = .object(receipt)
            }
            obj["page"] = displayed
        }
        obj["tool"] = .string(actionId)
        obj["provider_alias"] = .string(Self.providerAlias(for: actionId))
        obj["surface"] = .string(surface)
        if !dryRun, ["browser.read_text", "browser.read_links"].contains(actionId) {
            return try await browserSenseRead(snapshot: result, raw: .object(obj), input: input,
                actionID: actionId, visibleCapture: visibleRead?.capture)
        }
        if !dryRun, actionId == "browser.chrome_snapshot" {
            return try await browserSenseRead(snapshot: result, raw: .object(obj), input: input)
        }
        return .object(obj)
    }

    /// The slim page after an act, read on the same tab.
    public func freshChromePage(
        after actionId: String, tab: Int64, sequence: JSONValue?, input: [String: JSONValue], surface: String,
        scrollCursor: JSONValue? = nil,
        run: (String, [String: JSONValue]) async throws -> JSONValue
    ) async -> String {
        guard await chromeFollowUpAllowed("browser.chrome_snapshot", input: input, surface: surface) else {
            return "No page attached: reading the page needs your approval here. Call browser.chrome_snapshot."
        }
        var settled = false
        if Self.chromeMayNavigate.contains(actionId),
           await chromeFollowUpAllowed("browser.chrome_wait", input: input, surface: surface) {
            // Twice at most: a quiet window can close before a slow load starts.
            for _ in 0..<2 {
                let waited = try? await run("browser.chrome_wait", [
                    "tab_id": .int(tab), "expected_user_sequence": sequence ?? .null,
                    "condition": .string("navigation_settled"), "settle_ms": .int(400), "timeout_ms": .int(8_000),
                ])
                guard case .object(let wait)? = waited else { break }
                settled = wait["outcome"] == .string("succeeded")
                guard wait["outcome"] == .string("not_settled") else { break }
            }
        }
        if actionId == "browser.chrome_navigate", !settled {
            return "No page attached: navigation has not settled. Call browser.chrome_snapshot."
        }
        do {
            // Read the page's semantic content by default, or the named scope.
            let scope = Self.inputString(input["scope"])
            var read: [String: JSONValue] = ["tab_id": .int(tab), "max_nodes": .int(150),
                "scope": .string(scope == "page" ? "page" : "main_content")]
            if actionId == "browser.chrome_scroll" {
                guard let scrollCursor, case .object(let cursor) = scrollCursor,
                      case .string? = cursor["viewportObservationId"] else {
                    return "The scroll viewport could not be read: the action supplied no viewport address. Call browser.chrome_snapshot."
                }
                read["more"] = .string(try scrollCursor.serialize(pretty: false))
            }
            func readPage() async throws -> JSONValue {
                try await run("browser.chrome_snapshot", read)
            }
            var snapshot = try await readPage()
            // 09-24 (X profile): a first read that is only a spinner waits for
            // real content, 3 s at most.
            for _ in 0..<4 where actionId != "browser.chrome_scroll" && Self.chromeStillLoading(snapshot) {
                try? await Task.sleep(nanoseconds: 750_000_000)
                snapshot = try await readPage()
            }
            Self.mirrorChromePage(snapshot)
            guard let page = ChromePageText.render(snapshot) else {
                return "The fresh page could not be read. Call browser.chrome_snapshot."
            }
            return page
        } catch {
            return "The fresh page could not be read (" + ChromePageText.safe(error.localizedDescription)
                + "). Call browser.chrome_snapshot."
        }
    }

    private func browserSenseRead(snapshot: JSONValue, raw: JSONValue, input: [String: JSONValue],
                                  actionID: String = "browser.chrome_snapshot",
                                  visibleCapture: BrowserVisibleCapture? = nil) async throws -> JSONValue {
        guard case .object(let fields) = snapshot else {
            return SenseDoor.signedRaw(raw, line: "raw view · \(actionID) · snapshot unavailable")
        }
        let output: [String: JSONValue] = if case .object(let output)? = fields["output"] { output } else { fields }
        let visibleBrowser = ["browser.read_text", "browser.read_links"].contains(actionID)
        let servedRaw: JSONValue
        if visibleBrowser { servedRaw = raw }
        else {
            // The supplied text already uses ChromePageText and may be a scroll
            // delta with its stalled-feed warning. Keep that exact presentation.
            let rendered = if case .string(let text) = raw { text } else { ChromePageText.render(snapshot) }
            guard let rendered else {
                return SenseDoor.signedRaw(raw, line: "raw view · builtin-chrome · snapshot unavailable")
            }
            let receipt = try ChromePageText.envelope(snapshot, rendered: rendered)
            if case .object(let original) = raw, original["nodes"] != nil, case .object(let fields) = receipt {
                servedRaw = .object(original.merging(fields) { _, new in new })
            } else { servedRaw = receipt }
            if output["document"] != nil {
                return SenseDoor.signedRaw(servedRaw, line: "raw view · builtin-document · independent HTTP PDF read; unverified against Chrome")
            }
            if case .object(let receiptFields) = receipt, receiptFields["ok"] == .bool(false) {
                return SenseDoor.signedRaw(servedRaw, line: "raw view · builtin-chrome · no readable content in this window")
            }
        }
        let url = Self.inputString(output["url"])
        let host = url.flatMap { URL(string: $0)?.host?.lowercased() }
        guard host != nil else {
            return SenseDoor.signedRaw(raw, line: "raw view · \(actionID) · snapshot has no site host")
        }
        var senseInput = input
        senseInput["__sense_action"] = ToolNameAliases.appAction(actionID).map(JSONValue.string)
        if !visibleBrowser {
            senseInput["tab_id"] = fields["tabId"] ?? input["tab_id"]
            senseInput["expected_user_sequence"] = fields["userSequence"] ?? input["expected_user_sequence"]
        }
        let corner = SenseCorner.site(host: host!)
        let retained: JSONValue
        if visibleBrowser {
            guard let capture = visibleCapture, capture.url.absoluteString == url else {
                throw SenseFailure(code: "source_unavailable", message: "The visible browser read did not retain its captured material.")
            }
            let action = actionID == "browser.read_text" ? "browser.text" : "browser.links"
            var document: [String: JSONValue] = ["url": .string(capture.url.absoluteString),
                "title": .string(NativeAppSecretRedactor.redactText(capture.nav.title)),
                "source_action": .string(action), "source_receipt": snapshot]
            if actionID == "browser.read_text", let text = capture.text {
                document["text"] = .string(NativeAppSecretRedactor.redactText(text))
            } else if actionID == "browser.read_links", let links = capture.links {
                let retainedLinks = links.map { BrowserLink(url: NativeAppSecretRedactor.redactText($0.url),
                    text: NativeAppSecretRedactor.redactText($0.text)) }
                document["links"] = try JSONValue.fromEncodable(retainedLinks)
                document["text"] = .string(retainedLinks.map { $0.text + "\n" + $0.url }.joined(separator: "\n"))
            } else {
                throw SenseFailure(code: "source_unavailable", message: "The visible browser read did not retain its captured material.")
            }
            if case .string(let text)? = document["text"], !text.isEmpty {
                PeerDataTaint.markConsumed(peer: "web content", attested: false)
            }
            retained = .object(document)
        } else { retained = snapshot }
        if !visibleBrowser { await NativeChromeNews.shared.read(snapshot, chrome: chrome()) }
        let view = try await SenseDoor.read(corner: corner, address: url, input: senseInput,
            scope: ChatToolSessionContext.verifiedSessionId ?? "",
            nativeCorner: visibleBrowser ? .stream(id: "browser") : nil,
            raw: { servedRaw }, material: { _ in
                .pageSnapshot(retained)
            })
        return view
    }


    /// A read the app makes on her behalf clears the same Trust gate her own
    /// call would; anything that would ask or is blocked is simply not made.
    public func chromeFollowUpAllowed(_ tool: String, input: [String: JSONValue], surface: String, enforceAutonomy: Bool? = nil) async -> Bool {
        let envelope = await securityCenter.evaluateTool(
            tool: tool, input: [:], origin: AppChatToolDispatcher.securityOrigin(input: input, surface: surface),
            enforceAutonomy: enforceAutonomy ?? enforceAutonomySecurity)
        try? await securityCenter.record(envelope)
        if enforceAutonomy == true,
           AutonomyGate.map(level: envelope.autonomyLevel, toolName: tool) != .allow { return false }
        return envelope.decision != .block && !envelope.requiresApproval
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
        if actionId == "browser.chrome_reload_extension" {
            if dryRun {
                let status = await chrome().setupConnectionStatus()
                return .object(status.diagnostics.merging(["dry_run": .bool(true)]) { _, new in new })
            }
            return try await chrome().reloadExtension(source: SenseActionContext.perform == nil ? .manual : .verb)
        }
        if actionId == "browser.chrome_status" || actionId == "browser.chrome_setup" {
            if actionId == "browser.chrome_status" {
                var tabs = await chrome().conversationTabStatus(ChatToolSessionContext.verifiedSessionId)
                guard tabs["extension_connected"] != .bool(true) else {
                    tabs["note"] = .string("The extension is connected. These tabs are hers in the NativeAgent group; tabs outside it are the person's own.")
                    return .object(tabs)
                }
                // Why it is down, and the next step (set up, reconnecting, refused).
                tabs.merge(await chrome().setupConnectionStatus().diagnostics) { current, _ in current }
                tabs["note"] = .string("The extension is disconnected. These are her last seen tabs; their current ownership is unverified.")
                return .object(tabs)
            }
            var result: [String: JSONValue] = [:]
            if actionId == "browser.chrome_setup", !dryRun {
                let setup = await platform.setUpChrome()
                result["folder"] = setup.folder.map { .string($0.path) } ?? .null
                result["extensions_page_opened"] = .bool(setup.extensionsPageOpened)
                result["message"] = .string(setup.message)
            }
            let status = await chrome().setupConnectionStatus()
            result.merge(chromeSetupStatusJSON(state: status.state, enabled: status.enabled)) { _, new in new }
            result.merge(status.diagnostics) { _, new in new }
            result.merge(await chrome().conversationTabStatus(ChatToolSessionContext.verifiedSessionId)) { _, new in new }
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
            "next": state == .extensionNotLoaded ? .string("raise request_interaction kind=connector target=chrome") : .null,
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
        let explicitClose = actionId == "browser.chrome_close_tab"
        let effect: ChromeControlEffect
        let requestPayload: [String: JSONValue]
        do {
            (effect, requestPayload) = try chromeControlRequest(actionId: actionId, input: input, macPersonAway: macPersonAway)
        } catch {
            guard explicitClose, case .object(var failure) = ChatToolOutcome.failure(error: error, tool: actionId) else { throw error }
            failure["effects"] = .string("none")
            failure["provenance"] = .string("raw view · Chrome explicit tab ownership control; no page was served")
            return .object(failure)
        }
        var payload = requestPayload
        // Missing optional proof may use this chat's observed sequence. An
        // explicit invalid value remains invalid; never repair a supplied proof.
        if (input["expected_user_sequence"] == nil || input["expected_user_sequence"] == .null),
           payload["expectedUserSequence"] != nil {
            payload.removeValue(forKey: "expectedUserSequence")
        }
        do {
            let response = try await chrome().performInConversation(
                effect, payload: payload, verifiedSessionID: ChatToolSessionContext.verifiedSessionId)
            guard case .object(let object) = response,
                  let result = object["result"] else { throw ChromeControlRuntimeError.invalidResponse }
            // Admit the extension's actual action receipt as a motor consequence.
            if let model = chromeReceiptMotorActionReadModel(result) {
                await motorActionObserver(model)
            }
            if effect == .navigate {
                await NativeChromeNews.shared.opened(result, chrome: chrome())
            }
            if explicitClose {
                return SenseDoor.signedRaw(result, line: "raw view · Chrome explicit tab ownership control; no page was served")
            }
            return result
        } catch {
            if explicitClose, case .object(var failure) = ChatToolOutcome.failure(error: error, tool: actionId) {
                failure["provenance"] = .string("raw view · Chrome explicit tab ownership control; no page was served")
                return .object(failure)
            }
            // A page read can fail after dispatch without changing the page.
            guard effect == .snapshot || effect == .wait else { throw error }
            if case ChromeControlRuntimeError.outcomeUnknown = error { throw error }
            guard case .object(var failure) = ChatToolOutcome.failure(error: error, tool: actionId) else { throw error }
            failure["effects"] = .string("none")
            failure["provenance"] = .string("raw view · Chrome native messaging read reply; no page was served")
            if (error as? ChromeControlRuntimeError)?.recoverySuggestion == nil {
                failure["remedy"] = .object([
                    "kind": .string("inspect"),
                    "instruction": .string("The read did not change the page. Resolve the reported prerequisite before reading again."),
                    "next_call": .null,
                ])
            }
            return .object(failure)
        }
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
            // Visible row numbers are resolved from the served page before
            // this boundary. A bare number is never an internal node identity.
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
        case "browser.chrome_media":
            effect = .media
            payload["operation"] = input["operation"]
            if let seconds = input["seconds"], seconds != .null { payload["seconds"] = seconds }
        case "browser.chrome_close_tab":
            effect = .closeTab
            if let sequence = input["expected_user_sequence"], sequence != .null { payload["expectedUserSequence"] = sequence }
        case "browser.chrome_navigate":
            effect = .navigate
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "url": .string(string("url") ?? ""),
            ]
        case "browser.chrome_snapshot":
            effect = .snapshot
            // Explicit limits remain capped. Omitted limits use this tab's
            // last reading view; its first raw read retains the 80 / 12,000
            // app defaults, and its first direct read still gets 150 nodes.
            if let value = integer("max_nodes") { payload["maxNodes"] = .int(Int64(min(value, 200))) }
            if let value = integer("max_text_chars") { payload["maxTextChars"] = .int(Int64(min(value, 40_000))) }
            if let value = string("scope") { payload["scope"] = .string(value) }
            if let value = string("more") {
                guard case .object(let cursor) = try JSONValue.parse(Data(value.utf8)) else {
                    throw SenseFailure(code: "invalid_address", message: "Chrome more must be the supplied structural continuation.")
                }
                payload["readCursor"] = .object(cursor)
            }
        case "browser.chrome_click":
            effect = .click
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
            ]
        case "browser.chrome_fill":
            effect = .fill
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "value": .string(string("value") ?? ""),
            ]
        case "browser.chrome_type":
            effect = .type
            payload = [
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
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "values": .array(values),
            ]
        case "browser.chrome_keypress":
            effect = .keypress
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "key": .string(string("key") ?? ""),
            ]
        case "browser.chrome_set_checked":
            effect = .setChecked
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "checked": .bool(inputBool(input["checked"], default: false)),
            ]
        case "browser.chrome_double_click":
            effect = .doubleClick
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
            ]
        case "browser.chrome_drag":
            effect = .drag
            payload = [
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "targetNodeId": .string(string("target_node_id") ?? ""),
            ]
        case "browser.chrome_wait":
            effect = .wait
            payload = [
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
        default:
            throw ChromeControlRuntimeError.invalidResponse
        }
        if let supplied = input["tab_id"], supplied != .null {
            guard case .int(let id) = supplied, id >= 0 else {
                throw SenseFailure(code: "invalid_tab", message: "tab_id must be the integer tab number from chrome.status. Nothing was sent.")
            }
            payload["tabId"] = .int(id)
        }
        if let sequence = input["expected_user_sequence"], sequence != .null {
            payload["expectedUserSequence"] = sequence
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
        case .string("verified"): verification = .satisfied
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

/// One invocation owns one capture; task-local delivery cannot mix concurrent
/// reads or borrow evidence from a previous tab or disposable artifact path.
private final class RetainedBrowserRead: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BrowserVisibleCapture?
    var capture: BrowserVisibleCapture? { lock.withLock { value } }
    func remember(_ capture: BrowserVisibleCapture) { lock.withLock { value = capture } }
}
