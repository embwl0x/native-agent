import Foundation
import Darwin
import NativeAgentShared
import AppKit
import ChromeControl
import Browser
import Dispatcher
import ChatTurnRuntime
import ChatTurnContracts
import AgentWorkspace
import ChatToolParsing
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
// Blueprint: | `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpCheck`, `runChromeHistory`; follow-ups stop on Trust receipt failure; Chrome internal reads return one text line with read_mode none; chrome.look and DOM-inaccessible Chrome/PDF snapshot reads deliver the owned tab's bounded picture through the shared file-reader image slot, with source dimensions, explicit picture mode, independent debugger cleanup errors and raw Chrome provenance; PDF text remains unread with no independent fetch; action readback preserves non-DOM receipts; history reads only a stable private copy of the admitted Default profile History/WAL/journal under Full Mac/file-read authority, independent of extension connection; SQLite opens only the copy read-only, aggregates all qualifying visits before limiting domains, and bounds returned rows and query work; `RetainedBrowserRead` keeps the visible read's full capture and receipt beside its rejected view; scroll readback carries the tab-bound viewport observation, with no timed delta retries |

/// Browser acts reread the same tab and clear the same Trust gate as direct calls.
extension AppToolExecutor {
    @MainActor
    func runChromeHistory(input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        let mode = input["mode"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "recent"
        guard ["top_domains", "search", "recent"].contains(mode) else {
            return Self.failure("invalid_mode", "mode must be top_domains, search or recent (recent when omitted).")
        }
        let query = input["query"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mode == "search", query.isEmpty { return Self.failure("missing_query", "search requires nonempty query text to match titles or URLs.") }
        var since: Date?
        if let value = input["since"] {
            guard case .string(let text) = value, let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) else {
                return Self.failure("invalid_since", "since must be an ISO 8601 timestamp with a timezone.")
            }
            since = date
        }
        if mode == "top_domains", since == nil { return Self.failure("missing_since",
            "top_domains requires since, the inclusive start of the visit-count period.") }
        let limit: Int64
        switch input["limit"] {
        case nil: limit = 15
        case .int(let value)? where value > 0: limit = min(value, 50)
        default: return Self.failure("invalid_limit", "limit must be a positive integer; default 15, maximum 50.")
        }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        let origin = AppChatToolDispatcher.securityOrigin(turn: turn, surface: surface)
        let envelope = await securityCenter.evaluateTool(tool: "read_file", input: ["path": .string(source.path)],
            origin: origin, enforceAutonomy: enforceAutonomySecurity, turn: turn)
        try await securityCenter.record(envelope)
        let admission = await securityCenter.fullMacYoloAuthority(origin: origin, turn: turn)
        guard admission.admitted, envelope.fullMacYoloAuthority == .admitted,
              envelope.decision != .block, !envelope.requiresApproval else {
            return Self.failure("history_read_denied", """
                Chrome history requires admitted Full Mac and file-read permission. Check Trust and file access at the Mac; no history was read and no card \
                was raised.
                """)
        }
        // Read exactly the profile admitted above, regardless of which profile owns an extension connection. The live database stays Chrome's.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil else {
            return .object(["status": .string("absent"), "detail": .string("Google Chrome is not installed on this Mac."),
                "source": .string("sqlite_snapshot")])
        }
        let start = since.map { ($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000 } ?? 0
        return try await Task.detached(priority: .utility) {
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
                return .object(["status": .string("absent"), "detail": .string("Chrome's Default profile History is absent on this Mac."),
                    "source": .string("sqlite_snapshot")])
            }
            // One optimistic capture of the whole SQLite file set. Any write, replacement or sidecar arrival/removal during the copy refuses the capture; never
            // query a torn copy or retry another source.
            func identity(_ url: URL) throws -> [Int64]? {
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    let code = errno
                    if code == ENOENT { return nil }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                _ = try checked(url)
                guard info.st_mode & S_IFMT == S_IFREG else {
                    throw MacControlError.ioFailure("Chrome history snapshot members must be regular files, not links.")
                }
                return [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size,
                    Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                    Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
            }
            let members = [history, URL(fileURLWithPath: history.path + "-wal"), URL(fileURLWithPath: history.path + "-journal")]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-history-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            func readSnapshot(_ copy: URL) throws -> JSONValue {
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
                    ? """
                        SELECT history_domain(u.url) AS domain, count(*), max(v.visit_time) FROM visits v JOIN urls u ON u.id = v.url WHERE v.visit_time >= \
                        ?1 AND domain IS NOT NULL GROUP BY domain ORDER BY count(*) DESC, max(v.visit_time) DESC, domain LIMIT ?3
                        """
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
                        "source": .string("sqlite_snapshot"),
                        "coverage": .string("""
                            Stable private SQLite snapshot of the admitted Chrome Default profile History and its WAL/journal, independent of extension \
                            connection; excludes incognito and deleted history. Top-domain counts aggregate all qualifying visits since since before limiting \
                            returned domains; page visit counts are lifetime totals. Times are local ISO 8601; at_limit means more rows may exist.
                            """)])
                }
            }
            let result = Result<JSONValue, Error> {
                let before = try members.map(identity)
                guard before[0] != nil else { throw MacControlError.ioFailure("Chrome History disappeared before snapshot capture.") }
                for (member, stamp) in zip(members, before) where stamp != nil {
                    try FileManager.default.copyItem(at: member, to: directory.appendingPathComponent(member.lastPathComponent))
                }
                guard try members.map(identity) == before else {
                    throw MacControlError.ioFailure("""
                        Chrome history changed during snapshot capture; no history was read. Read again when the profile is quiet.
                        """)
                }
                return try readSnapshot(directory.appendingPathComponent(history.lastPathComponent))
            }
            do { try FileManager.default.removeItem(at: directory) }
            catch {
                let cause = if case .failure(let failure) = result { " Read also failed: " + failure.localizedDescription } else { "" }
                throw MacControlError.ioFailure("Chrome history temporary snapshot could not be deleted: \(error.localizedDescription)." + cause)
            }
            return try result.get()
        }.value
    }

    private static let chromePageActions: Set<String> = [
        "browser.chrome_navigate", "browser.chrome_click", "browser.chrome_fill", "browser.chrome_type",
        "browser.chrome_select", "browser.chrome_keypress", "browser.chrome_set_checked",
        "browser.chrome_double_click", "browser.chrome_drag", "browser.chrome_scroll",
    ]
    /// Wait for navigation-capable acts to settle before readback.
    private static let chromeMayNavigate: Set<String> = [
        "browser.chrome_navigate", "browser.chrome_click", "browser.chrome_keypress", "browser.chrome_double_click",
    ]

    public func runBrowserTool(actionId: String, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        let dryRun = Self.inputBool(input["dry_run"], default: false)
        let fields: ChromeFields?
        if ["browser.chrome_fill", "browser.chrome_navigate"].contains(actionId) { fields = try Self.chromeFields(input) }
        else { fields = nil }
        // Keys keep their advertised observed-row contract all the way to Chrome's trusted input owner; no key is rewritten as another action.
        let origin = AppChatToolDispatcher.securityOrigin(turn: turn, surface: surface)
        let visibleRead = !dryRun && ["browser.read_text", "browser.read_links"].contains(actionId)
            ? RetainedBrowserRead() : nil
        var readExecution = execution
        readExecution.retainBrowserRead = visibleRead.map { retained in
            { @Sendable capture in retained.remember(capture) }
        }
        let invocation = readExecution
        let browserTurn = turn.with(\.chromeOrigin, origin)
        func run(_ id: String, _ input: [String: JSONValue]) async throws -> JSONValue {
            try await browserActionRunner(id, dryRun, input, browserTurn, invocation)
        }
        // Direct calls include the fresh page; workspace calls keep structured results.
        let direct = !dryRun && execution.lookSource != "workspace"
        var input = input
        if actionId == "browser.chrome_snapshot", let more = input["more"]?.scalarText, more.hasPrefix("site:") {
            let scope = turn.verifiedSessionID ?? ""
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
            if await chrome().conversationSnapshotView(turn.verifiedSessionID,
                tabID: Self.chromeTabID(input["tab_id"])) == nil {
                input["max_nodes"] = .int(150)
            }
        }
        // Resolve labels, missing snapshot ids and field options only from this tab's last served page.
        if let refusal = resolveChromeTarget(actionId, &input, turn: turn, execution: execution) { return refusal }
        if !dryRun, let fields {
            return try await runChromeFieldsCall(actionId: actionId, input: input, fields: fields, direct: direct, surface: surface, turn: turn,
                execution: execution, run: run)
        }
        // Judge a keypress by the page it changed; scroll readback shows only newly visible rows.
        let lastRead = ChromePageMirror.page(tab: Self.chromeTabID(input["tab_id"]), dataRoot: securityCenter.dataRoot, session: turn.verifiedSessionID)
        let before = ["browser.chrome_keypress", "browser.chrome_click", "browser.chrome_double_click"].contains(actionId)
            ? lastRead.flatMap { $0.snapshotID == input["snapshot_id"]?.scalarText ? $0 : nil }
            : actionId == "browser.chrome_scroll" ? lastRead : nil
        // A stale click refuses as the extension said ("the page changed"): a fresh node matched only by role and label is not the same control.
        let result = try await run(actionId, input)
        let projection = ChromePageText.project(result, turn: turn)
        mirrorChromePage(result, projection: projection, turn: turn, closedBy: actionId)
        guard case .object(var obj) = result else {
            return result
        }
        if let mode = obj["read_mode"]?.scalarText, ["picture", "none"].contains(mode) { return result }
        if direct, actionId == "browser.chrome_snapshot", let page = projection.text {
            return try await browserSenseRead(snapshot: result, raw: .string(page), input: input, projection: projection, turn: turn, execution: execution)
        }
        if direct, Self.chromePageActions.contains(actionId), case .object(let receipt)? = obj["receipt"],
           case .int(let tab)? = receipt["tabId"] {
            let fresh = await freshChromePage(after: actionId, tab: tab,
                sequence: receipt["userSequence"], input: input, surface: surface,
                navigationVerified: actionId == "browser.chrome_navigate"
                    && receipt["outcome"] == .string("succeeded") && receipt["verification"] == .string("verified"),
                scrollCursor: actionId == "browser.chrome_scroll" ? obj["readCursor"] : nil, turn: turn, run: run)
            var page = fresh.text
            if actionId == "browser.chrome_scroll", let before {
                // Text already read is not proof that the viewport stayed the same. The page compares the exact scrolled viewport during this read, including
                // any load after the action's reply.
                let viewportChanged: Bool?
                if case .object(let snapshot)? = fresh.snapshot,
                   case .object(let reading)? = snapshot["reading"],
                   case .bool(let changed)? = reading["viewportChanged"] {
                    viewportChanged = changed
                } else {
                    viewportChanged = nil
                }
                page = Self.onlyNewRows(page, before: before.text, viewportChanged: viewportChanged).text
            }
            // Verification compares the original page. Senses change only the view returned to the agent, after those comparisons have been made.
            let displayed: JSONValue
            if case .object(let read)? = fresh.snapshot, let mode = read["read_mode"]?.scalarText, ["picture", "none"].contains(mode) {
                displayed = .object(read)
            } else if let snapshot = fresh.snapshot {
                displayed = try await browserSenseRead(snapshot: snapshot, raw: .string(page), input: input, projection: fresh.projection, turn: turn,
                    execution: execution)
            } else {
                displayed = SenseDoor.signedRaw(.string(page), line: "raw view · builtin-chrome · action readback unavailable")
            }
            // Keep the page envelope intact, including its exact continuation.
            if obj["outcome"] == .string("succeeded") {
                if actionId != "browser.chrome_scroll", let before, Self.chromePageUnchanged(before: before.text, after: page) {
                    let verb = actionId.replacingOccurrences(of: "browser.chrome_", with: "").replacingOccurrences(of: "_", with: " ")
                    // The read is the main content in view: a cart count or toast elsewhere may have changed, so never an invitation to repeat.
                    obj["readback_note"] = .string(verb + " unverified: it reached the page but nothing in the part read moved or changed; "
                        + "it may have acted elsewhere, so check before repeating it"
                        + (actionId == "browser.chrome_keypress" ? ". To move down the page, call browser.chrome_scroll{delta_y}." : "."))
                } else {
                    obj["readback_note"] = .string(Self.chromeReceiptLine(actionId, obj))
                }
            }
            // An attached page already supplies fresh-read recovery, so stale snapshot guidance must be removed.
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
                actionID: actionId, visibleCapture: visibleRead?.capture, turn: turn, execution: execution)
        }
        if !dryRun, actionId == "browser.chrome_snapshot" {
            return try await browserSenseRead(snapshot: result, raw: .object(obj), input: input, projection: projection, turn: turn, execution: execution)
        }
        return .object(obj)
    }

    /// Readback stays on the same tab as the act.
    func freshChromePage(
        after actionId: String, tab: Int64, sequence: JSONValue?, input: [String: JSONValue], surface: String,
        navigationVerified: Bool = false,
        scrollCursor: JSONValue? = nil, turn: Turn,
        run: (String, [String: JSONValue]) async throws -> JSONValue
    ) async -> (snapshot: JSONValue?, text: String, projection: ChromePageText.VisiblePageText?) {
        let followUp = await chromeFollowUpCheck("browser.chrome_snapshot", surface: surface, turn: turn)
        if let stop = followUp.stop { return (nil, "No page attached: " + stop, nil) }
        if !navigationVerified, Self.chromeMayNavigate.contains(actionId) {
            let waitAdmission = await chromeFollowUpCheck("browser.chrome_wait", surface: surface, turn: turn)
            if let stop = waitAdmission.stop { return (nil, "No page attached: " + stop, nil) }
            // Verified navigation already observed completion. Other acts can start a load after their reply, so retain that observation. Twice at most: a
            // quiet window can close before a slow load starts. The read itself waits for the load and says when it had not finished.
            for _ in 0..<2 {
                let waited: JSONValue
                do { waited = try await run("browser.chrome_wait", [
                    "tab_id": .int(tab), "expected_user_sequence": sequence ?? .null,
                    "condition": .string("navigation_settled"), "settle_ms": .int(400), "timeout_ms": .int(8_000),
                ]) } catch { return (nil, "The action already returned, but navigation observation failed: " + error.localizedDescription
                    + ". Read this tab before continuing; do not repeat the action.", nil) }
                guard case .object(let wait) = waited, wait["outcome"] == .string("not_settled") else { break }
            }
        }
        do {
            let scope = input["scope"]?.scalarText
            var read: [String: JSONValue] = ["tab_id": .int(tab), "max_nodes": .int(150),
                "scope": .string(scope == "page" ? "page" : "main_content")]
            if actionId == "browser.chrome_scroll" {
                guard let scrollCursor, case .object(let cursor) = scrollCursor,
                      case .string? = cursor["viewportObservationId"] else {
                    return (nil, "The scroll viewport could not be read: the action supplied no viewport address. Call browser.chrome_snapshot.", nil)
                }
                read["more"] = .string(try scrollCursor.serialize(pretty: false))
            }
            let snapshot = try await run("browser.chrome_snapshot", read)
            let projection = ChromePageText.project(snapshot, turn: turn)
            if case .object(let read) = snapshot {
                if read["read_mode"] == .string("none"), let text = read["text"]?.scalarText { return (snapshot, text, projection) }
                if read["read_mode"] == .string("picture") {
                    return (snapshot, read["note"]?.scalarText ?? "This page is read as a picture; no DOM text is available.", projection)
                }
            }
            mirrorChromePage(snapshot, projection: projection, turn: turn)
            guard let page = projection.text else {
                return (snapshot, "The fresh page could not be read. Call browser.chrome_snapshot.", projection)
            }
            return (snapshot, page, projection)
        } catch {
            return (nil, "The fresh page could not be read (" + ChromePageText.safe(error.localizedDescription)
                + "). Call browser.chrome_snapshot.", nil)
        }
    }

    private func browserSenseRead(snapshot: JSONValue, raw: JSONValue, input: [String: JSONValue],
                                  actionID: String = "browser.chrome_snapshot",
                                  visibleCapture: BrowserVisibleCapture? = nil,
                                  projection: ChromePageText.VisiblePageText? = nil, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        guard case .object(let fields) = snapshot else {
            return SenseDoor.signedRaw(raw, line: "raw view · \(actionID) · snapshot unavailable")
        }
        let output: [String: JSONValue] = if case .object(let output)? = fields["output"] { output } else { fields }
        let visibleBrowser = ["browser.read_text", "browser.read_links"].contains(actionID)
        let servedRaw: JSONValue
        if visibleBrowser { servedRaw = raw }
        else {
            // Supplied ChromePageText may be a scroll delta with warnings; preserve that exact presentation.
            let projection = projection ?? ChromePageText.project(snapshot, turn: turn)
            let rendered = if case .string(let text) = raw { text } else { projection.text }
            guard let rendered else {
                return SenseDoor.signedRaw(raw, line: "raw view · builtin-chrome · snapshot unavailable")
            }
            let receipt = try ChromePageText.envelope(snapshot, rendered: rendered, projection: projection, turn: turn)
            if case .object(let original) = raw, original["nodes"] != nil, case .object(let fields) = receipt {
                servedRaw = .object(original.merging(fields) { _, new in new })
            } else { servedRaw = receipt }
            if case .object(let receiptFields) = receipt, receiptFields["ok"] == .bool(false) {
                return SenseDoor.signedRaw(servedRaw, line: "raw view · builtin-chrome · no readable content in this window")
            }
        }
        let url = output["url"]?.scalarText
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
            retained = .object(document)
        } else { retained = snapshot }
        if !visibleBrowser {
            await NativeChromeNews.shared.read(snapshot, chrome: chrome(), context: execution.macOperation(dataRoot: securityCenter.dataRoot))
        }
        let view = try await SenseDoor.read(corner: corner, address: url, input: senseInput,
            scope: turn.verifiedSessionID ?? "",
            nativeCorner: visibleBrowser ? .stream(id: "browser") : nil,
            operation: execution.senseOperation(turn: turn),
            raw: { _ in servedRaw }, material: { _, _ in
                .pageSnapshot(retained)
            })
        return view
    }


    /// Supplementary reads clear the ordinary Trust gate; blocked or asking reads do not run.
    func chromeFollowUpCheck(_ tool: String, surface: String, turn: Turn, enforceAutonomy: Bool? = nil) async -> (stop: String?, refusal: JSONValue?) {
        let envelope = await securityCenter.evaluateTool(
            tool: tool, input: [:], origin: AppChatToolDispatcher.securityOrigin(turn: turn, surface: surface),
            enforceAutonomy: enforceAutonomy ?? enforceAutonomySecurity, turn: turn)
        do { try await securityCenter.record(envelope) }
        catch {
            let cause = "Trust could not record the follow-up receipt: " + error.localizedDescription
            let instruction = """
                Repair the reported storage failure in experiences/experiences.sqlite, preserving existing details, before reading this tab again; no \
                follow-up ran. \
                Do not repeat an action that already returned.
                """
            return ("browser_follow_up_receipt_failed: " + cause + " " + instruction,
                Self.failure("browser_follow_up_receipt_failed", cause,
                    extra: ["remedy": Repair.remedy(owner: "experiences/experiences.sqlite", nextCall: nil, tap: "Trust", instruction: instruction)]))
        }
        if envelope.decision == .block {
            let cause = envelope.primaryReason
            let instruction = "Ask the owner to review this block in Trust; no follow-up ran."
            let stop = "browser_follow_up_blocked: \(cause) \(instruction)"
            return (stop, Self.failure("browser_follow_up_blocked", cause, extra: ["remedy": envelope.remedy
                ?? Repair.why(owner: tool, tap: "Trust", instruction: instruction)]))
        }
        if envelope.requiresApproval {
            // Explicit autonomy enforcement presents its cause before any origin cause.
            let cause = (enforceAutonomy == true ? envelope.reasons.first(where: { $0.kind == .cause })?.sentence : nil)
                ?? envelope.primaryReason
            let instruction = "Call \(tool) explicitly to request approval; no follow-up ran."
            return ("browser_follow_up_approval_required: \(cause) \(instruction)",
                Self.doorRefusal("browser_follow_up_approval_required", cause,
                    remedy: "request_approval", instruction, next: ["action": .string(ToolNameAliases.appAction(tool) ?? tool)]))
        }
        return (nil, nil)
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
        platform: BrowserToolPlatformPort, dataRoot: URL, turn: Turn, execution: AppActionExecution
    ) async throws -> JSONValue {
        let context = execution.macOperation(dataRoot: dataRoot)
        if actionId == "browser.chrome_reload_extension" {
            if dryRun {
                let status = await chrome().setupConnectionStatus(context: context)
                return .object(status.diagnostics.merging(["dry_run": .bool(true)]) { _, new in new })
            }
            return try await chrome().reloadExtension(source: execution.senseAct ? .verb : .manual, turn: turn, context: context)
        }
        if actionId == "browser.chrome_status" || actionId == "browser.chrome_setup" {
            if actionId == "browser.chrome_status" {
                var tabs = await chrome().conversationTabStatus(turn.verifiedSessionID)
                tabs.merge(await chrome().setupConnectionStatus(context: context).diagnostics) { current, _ in current }
                tabs["note"] = tabs["extension_connected"] == .bool(true)
                    ? .string("The extension is connected. These tabs are the agent's in the NativeAgent group; tabs outside it are the person's own.")
                    : .string("The extension is disconnected. These are the agent's last seen tabs; their current ownership is unverified.")
                return .object(tabs)
            }
            var result: [String: JSONValue] = [:]
            if actionId == "browser.chrome_setup", !dryRun {
                let setup = try await platform.setUpChrome()
                result["folder"] = setup.folder.map { .string($0.path) } ?? .null
                result["message"] = .string(setup.message)
            }
            let status = await chrome().setupConnectionStatus(context: context)
            result.merge(chromeSetupStatusJSON(state: status.state, enabled: status.enabled)) { _, new in new }
            result.merge(status.diagnostics) { _, new in new }
            result.merge(await chrome().conversationTabStatus(turn.verifiedSessionID)) { _, new in new }
            result["dry_run"] = .bool(dryRun)
            return .object(result)
        }
        if actionId.hasPrefix("browser.chrome_") {
            guard !dryRun else {
                return .object(["status": .string("dry_run"), "action": .string(actionId)])
            }
            return try await runChromeControlTool(actionId: actionId, input: input, chrome: chrome, macPersonAway: macPersonAway,
                motorActionObserver: motorActionObserver, turn: turn, context: context, execution: execution)
        }
        if actionId == "browser.status" {
            return try await platform.readStatus()
        }
        return try await platform.runNativeAction(actionId, dryRun, input, turn, execution)
    }

    public static func chromeSetupStatusJSON(state: ChromeControlConnectionState, enabled: Bool) -> [String: JSONValue] {
        let connection: String
        switch state {
        case .connected: connection = "connected"
        case .disconnected: connection = "previously_connected"
        case .extensionNotLoaded: connection = "not_yet_connected"
        }
        return [
            "next": state == .extensionNotLoaded ? .string("app chrome.setup") : .null,
            "connection": .string(connection),
            "connected": .bool(state == .connected),
            "chrome_control_enabled": .bool(enabled),
            "status_note": .string("""
                Only a live connection confirms availability. A prepared folder or previous connection does not prove the extension is currently loaded. \
                Trust and macOS grants still apply.
                """),
        ]
    }

    public static func runChromeControlTool(
        actionId: String,
        input: [String: JSONValue],
        chrome: @Sendable () -> ChromeControlRuntime,
        macPersonAway: @Sendable () -> Bool,
        motorActionObserver: @Sendable (MotorActionReadModel) async -> Void, turn: Turn, context: MacOperationContext, execution: AppActionExecution
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
        let payload: [String: JSONValue]
        do {
            (effect, payload) = try chromeControlRequest(actionId: actionId, input: input, macPersonAway: macPersonAway)
        } catch {
            guard explicitClose, case .object(var failure) = ChatToolOutcome.failure(error: error, tool: actionId) else { throw error }
            failure["effects"] = .string("none")
            failure["provenance"] = .string("raw view · Chrome explicit tab ownership control; no page was served")
            return .object(failure)
        }
        do {
            let response = try await chrome().performInConversation(
                effect, payload: payload, verifiedSessionID: turn.verifiedSessionID, turn: turn, context: context)
            guard case .object(let object) = response,
                  let result = object["result"] else { throw ChromeControlRuntimeError.invalidResponse }
            if effect == .look {
                return try chromeReadResult(result, actionId: actionId, imageSink: execution.localImageSink, turn: turn)
            }
            if effect == .snapshot, case .object(let capture) = result {
                let mode: JSONValue? = if case .object(let reading)? = capture["reading"] { reading["mode"] } else { nil }
                if capture["format"] == .string("jpeg") || mode == .string("none") {
                    return try chromeReadResult(result, actionId: actionId, imageSink: execution.localImageSink, turn: turn)
                }
            }
            // Admit the extension's actual action receipt as a motor consequence.
            if let model = chromeReceiptMotorActionReadModel(result) {
                await motorActionObserver(model)
            }
            if effect == .navigate {
                await NativeChromeNews.shared.opened(result, chrome: chrome(), context: context)
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
            guard effect == .snapshot || effect == .look || effect == .wait else { throw error }
            if case ChromeControlRuntimeError.outcomeUnknown = error { throw error }
            guard case .object(var failure) = ChatToolOutcome.failure(error: error, tool: actionId) else { throw error }
            failure["effects"] = .string("none")
            failure["provenance"] = .string("raw view · Chrome native messaging read reply; no page was served")
            return effect == .look
                ? SenseDoor.signedRaw(.object(failure), line: "raw view · builtin-chrome · no picture was served")
                : .object(failure)
        }
    }

    private static func chromeReadResult(_ result: JSONValue, actionId: String, imageSink: LocalToolImage.Sink?, turn: Turn) throws -> JSONValue {
        if case .object(let capture) = result, case .object(let reading)? = capture["reading"], reading["mode"] == .string("none") {
            guard case .int(let tab)? = capture["tabId"], tab >= 0, reading["domAccessible"] == .bool(false),
                  case .string(let reason)? = reading["reason"], case .string(let url)? = capture["url"],
                  case .string(let title)? = capture["title"] else { throw ChromeControlRuntimeError.invalidResponse }
            let line = [title, url, reason].filter { !$0.isEmpty }.map(ChromePageText.safe).joined(separator: " — ")
            return SenseDoor.signedRaw(.object(["ok": .bool(true), "status": .string("completed"),
                "tool": .string(actionId), "read_mode": .string("none"), "reading": .object(reading),
                "text": .string(line), "url": .string(url), "title": .string(title), "tab_id": .int(tab),
                "user_sequence": capture["userSequence"] ?? .null, "effect": .string("read"), "read_only": .bool(true)]),
                line: "raw view · builtin-chrome · internal page has no reader")
        }
        guard case .object(let capture) = result,
              case .int(let tab)? = capture["tabId"], tab >= 0,
              capture["format"] == .string("jpeg"),
              case .string(let base64)? = capture["data"],
              let data = Data(base64Encoded: base64) else { throw ChromeControlRuntimeError.invalidResponse }
        let name = "chrome-tab-\(tab)-\(NativeTimestampFormat.plainZulu(Date())).jpg"
        let delivered = VerifiedImageRead.deliver(data: data, name: name, sink: imageSink)
        guard case .object(var fields) = delivered else { throw ChromeControlRuntimeError.invalidResponse }
        fields["tool"] = .string(actionId)
        fields["read_mode"] = .string("picture")
        fields["reading"] = capture["reading"]
        fields["cleanupError"] = capture["cleanupError"]
        fields["effect"] = .string("read")
        fields["read_only"] = .bool(true)
        fields["tab_id"] = .int(tab)
        fields["url"] = capture["url"]
        fields["title"] = capture["title"]
        fields["user_sequence"] = capture["userSequence"]
        if case .object(let document)? = capture["document"], document["kind"] == .string("pdf") {
            fields["document"] = .object(document)
            fields["text"] = ChromePageText.project(result, turn: turn).text.map(JSONValue.string)
            fields["chrome_view_verified"] = .bool(fields["status"] == .string("ok"))
        }
        if fields["status"] == .string("ok"), fields["image_pixels"] == .bool(true) {
            let reason: String = if case .object(let reading)? = capture["reading"], case .string(let reason)? = reading["reason"] { reason + " " } else { "" }
            fields["note"] = .string(reason + "Actual image follows this tool result: your tab as Chrome renders it now; not a text description.")
        } else if fields["status"] == .string("ok") {
            fields["note"] = .string("""
                Verified capture metadata only; this call has no image slot. To see the pixels, use chrome.look or chrome.snapshot from a turn.
                """)
        }
        return SenseDoor.signedRaw(.object(fields), line: "raw view · builtin-chrome · owned tab picture")
    }

    /// Empty optional strings mean omission at the provider boundary, not an override of extension routing.
    public static func chromeControlRequest(
        actionId: String,
        input: [String: JSONValue],
        macPersonAway: @Sendable () -> Bool
    ) throws -> (ChromeControlEffect, [String: JSONValue]) {
        let effect: ChromeControlEffect
        var payload: [String: JSONValue] = [:]
        func string(_ key: String) -> String? {
            // Visible row numbers are resolved from the served page before this boundary. A bare number is never an internal node identity.
            return input[key]?.scalarText
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
        case "browser.chrome_navigate":
            effect = .navigate
            payload["url"] = .string(string("url") ?? "")
        case "browser.chrome_snapshot":
            effect = .snapshot
            // Explicit limits remain capped. Omitted limits use this tab's last reading view; its first raw read retains the 80 / 12,000 app defaults, and its
            // first direct read still gets 150 nodes.
            if let value = integer("max_nodes") { payload["maxNodes"] = .int(Int64(min(value, 200))) }
            if let value = integer("max_text_chars") { payload["maxTextChars"] = .int(Int64(min(value, 40_000))) }
            if let value = string("scope") { payload["scope"] = .string(value) }
            if let value = string("more") {
                guard case .object(let cursor) = try JSONValue.parse(Data(value.utf8)) else {
                    throw SenseFailure(code: "invalid_address", message: "Chrome more must be the supplied page-position continuation.")
                }
                payload["readCursor"] = .object(cursor)
            }
        case "browser.chrome_look":
            effect = .look
        case "browser.chrome_click":
            effect = .click
        case "browser.chrome_fill":
            effect = .fill
            payload["value"] = .string(string("value") ?? "")
        case "browser.chrome_type":
            effect = .type
            payload["text"] = .string(string("text") ?? "")
            if let value = integer("delay_ms") { payload["delayMs"] = .int(Int64(value)) }
        case "browser.chrome_select":
            effect = .select
            guard case .array(let values)? = input["values"],
                  values.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            payload["values"] = .array(values)
        case "browser.chrome_keypress":
            effect = .keypress
            payload["key"] = .string(string("key") ?? "")
        case "browser.chrome_set_checked":
            effect = .setChecked
            payload["checked"] = .bool(inputBool(input["checked"], default: false))
        case "browser.chrome_double_click":
            effect = .doubleClick
        case "browser.chrome_drag":
            effect = .drag
            payload["targetNodeId"] = .string(string("target_node_id") ?? "")
        case "browser.chrome_wait":
            effect = .wait
            payload["condition"] = .string(string("condition") ?? "")
            if let value = string("snapshot_id") { payload["snapshotId"] = .string(value) }
            if let value = string("node_id") { payload["nodeId"] = .string(value) }
            if let value = string("state") { payload["state"] = .string(value) }
            // Requested waits are capped at the longest allowed duration.
            if let value = integer("timeout_ms") { payload["timeoutMs"] = .int(Int64(min(max(value, 100), 10_000))) }
            if let value = integer("settle_ms") { payload["settleMs"] = .int(Int64(min(max(value, 0), 2_000))) }
        case "browser.chrome_scroll":
            effect = .scroll
            payload = [
                // A background scroll renders only while the person is away.
                "renderHidden": .bool(macPersonAway()),
                "deltaX": .int(Int64(integer("delta_x") ?? 0)),
                "deltaY": .int(Int64(integer("delta_y") ?? 0)),
            ]
            // Some provider calls serialize absent optional strings as an empty pair. Normalize only that pair; never discard a partial target.
            let snapshotID = string("snapshot_id")
            let targetID = string("target_node_id")
            if !(snapshotID ?? "").isEmpty || !(targetID ?? "").isEmpty {
                if let snapshotID { payload["snapshotId"] = .string(snapshotID) }
                if let targetID { payload["targetNodeId"] = .string(targetID) }
            }
        default:
            throw ChromeControlRuntimeError.invalidResponse
        }
        if effect.rawValue.hasPrefix("page.element.") {
            payload["snapshotId"] = .string(string("snapshot_id") ?? "")
            payload["nodeId"] = .string(string("node_id") ?? "")
        }
        if let supplied = input["tab_id"], supplied != .null {
            guard case .int(let id) = supplied, id >= 0 else {
                throw SenseFailure(code: "invalid_tab", message: "tab_id must be the integer tab number from chrome.status. Nothing was sent.")
            }
            payload["tabId"] = .int(id)
        }
        // Missing proof may bind to this chat's observation; supplied proof stays exact.
        if let sequence = input["expected_user_sequence"], sequence != .null {
            payload["expectedUserSequence"] = sequence
        }
        return (effect, payload)
    }

    /// Keep the exact domainState: collapsing partial completion into success/failure would erase receipt evidence.
    public static func chromeReceiptMotorActionReadModel(_ result: JSONValue) -> MotorActionReadModel? {
        guard case .object(let payload) = result,
              case .object(let receipt)? = payload["receipt"],
              case .string(let actionIdentity)? = receipt["id"],
              !actionIdentity.isEmpty,
              case .string(let outcome)? = receipt["outcome"] else { return nil }
        // Use MacControlOperationStore.motorPhase: refused is blocked; unknown is waitingExternal because unknown events are discarded.
        let phase: MotorActionPhase
        switch outcome {
        case "succeeded": phase = .succeeded
        case "refused": phase = .blocked
        default: phase = .waitingExternal
        }
        let verification: MotorVerificationState
        switch receipt["verification"] {
        case .string("verified"): verification = .satisfied
        // Page acknowledgement leaves verification pending until the effect is observed.
        case .string("page_acknowledged"): verification = .pending
        case .string("not_verified"):
            // A `not_quiet` deadline leaves navigation verification pending, not negatively verified.
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
            // Cognitive events require a 64-character digest; hash the raw UUID so the factory can admit the receipt.
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(actionIdentity),
            phase: phase,
            domainState: outcome,
            verification: verification,
            expectedNextEvidence: expectedNextEvidence,
            updatedAt: updatedAt
        )
    }

    private static func inputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        switch raw?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y": return true
        case "n": return false
        default: return ConnectorInputValue.bool(raw, default: defaultValue)
        }
    }
}

/// One invocation owns one capture; task-local delivery cannot mix concurrent reads or borrow evidence from a previous tab or disposable artifact path.
private final class RetainedBrowserRead: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BrowserVisibleCapture?
    var capture: BrowserVisibleCapture? { lock.withLock { value } }
    func remember(_ capture: BrowserVisibleCapture) { lock.withLock { value = capture } }
}
