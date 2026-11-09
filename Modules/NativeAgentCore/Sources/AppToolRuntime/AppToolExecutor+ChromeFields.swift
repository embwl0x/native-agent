import Foundation
import NativeAgentCore
import ChatTurnContracts
import ChatToolRuntime
import ChatToolParsing
import AgentWorkspace
import ChromeControl
import MacControl
import PersistenceCore
import ToolRegistry
import Senses
import Desk
// Blueprint: | `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`, `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall`; observed-field batches |

/// Every field act clears the extension's Trust gate independently, even when a form is filled and submitted in one call.
extension AppToolExecutor {
    public typealias ChromeRun = (String, [String: JSONValue]) async throws -> JSONValue

    public struct ChromeFields {
        var pairs: [(label: String, value: String)] = []
        var submit: String?
    }

    private static let chromeWants: [String: Set<String>] = [
        "browser.chrome_click": ["click", "fill", "type"], "browser.chrome_double_click": ["double_click", "click", "fill", "type"],
        "browser.chrome_fill": ["fill"], "browser.chrome_type": ["type"], "browser.chrome_select": ["select"],
        "browser.chrome_keypress": ["keypress"], "browser.chrome_set_checked": ["set_checked"],
        "browser.chrome_wait": ["wait"], "browser.chrome_drag": ["drag"], "browser.chrome_drop_target": ["drop"],
        "browser.chrome_scroll_target": ["scroll"],
    ]

    /// Resolve defaults from this tab's last served page; refuse labels that it did not show.
    public func resolveChromeTarget(_ actionId: String, _ input: inout [String: JSONValue], turn: Turn, execution: AppActionExecution) -> JSONValue? {
        guard let refusal = resolveChromeRows(actionId, &input, turn: turn, execution: execution) else { return nil }
        guard case .object(var fields) = refusal else { return refusal }
        fields["effects"] = .string("none")
        fields["provenance"] = .string("raw view · Chrome conversation page bindings and displayed row index; no extension request was sent")
        return .object(fields)
    }

    private func resolveChromeRows(_ actionId: String, _ input: inout [String: JSONValue], turn: Turn, execution: AppActionExecution) -> JSONValue? {
        if actionId == "browser.chrome_scroll" || actionId == "browser.chrome_drag" {
            if actionId == "browser.chrome_drag", let refusal = resolveChromeRow(actionId, &input, turn: turn, execution: execution) { return refusal }
            guard let target = input["target_node_id"], !(target.scalarText ?? "").isEmpty else { return nil }
            var destination = input
            destination["node_id"] = target
            if let refusal = resolveChromeRow(actionId == "browser.chrome_drag" ? "browser.chrome_drop_target" : "browser.chrome_scroll_target",
                &destination, turn: turn, execution: execution) { return refusal }
            input["target_node_id"] = destination["node_id"]
            input["snapshot_id"] = destination["snapshot_id"]
            return nil
        }
        return resolveChromeRow(actionId, &input, turn: turn, execution: execution)
    }

    private func resolveChromeRow(_ actionId: String, _ input: inout [String: JSONValue], turn: Turn, execution: AppActionExecution) -> JSONValue? {
        if actionId == "browser.chrome_select", case .string(let one)? = input["values"] { input["values"] = .array([.string(one)]) }
        guard let wants = Self.chromeWants[actionId],
              let node = input["node_id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !node.isEmpty else { return nil }
        // The site sense owns its fresh source proof. Public calls own only the numbers or labels that their last page actually showed.
        if execution.verifyingActCorner != nil { return nil }
        if node.range(of: #"^n\d+$"#, options: .regularExpression) != nil {
            return .object(["ok": .bool(false), "error": .string("internal_node_id"),
                "reason": .string("Internal node ids are not row numbers. Use the row number shown on this page or its label. Nothing was sent.")])
        }
        guard let page = ChromePageMirror.page(tab: Self.chromeTabID(input["tab_id"]), dataRoot: securityCenter.dataRoot, session: turn
            .verifiedSessionID) else {
            return .object(["ok": .bool(false), "error": .string("no_page_read"),
                "reason": .string("No page has been read in this conversation. Read the page with chrome.snapshot before choosing a row. Nothing was sent.")])
        }
        if input["tab_id"] == nil || input["tab_id"] == .null { input["tab_id"] = .int(page.tab) }
        let given = input["snapshot_id"]?.scalarText ?? ""
        guard given.isEmpty || given == page.snapshotID else {
            return .object(["ok": .bool(false), "error": .string("snapshot_stale"),
                "reason": .string("""
                    The supplied snapshot does not match the page last read. Read the page again with browser.chrome_snapshot. Nothing was sent.
                    """)])
        }
        let byNumber = node.range(of: #"^\d+$"#, options: .regularExpression) != nil
        // Existence and ability to act are different facts. In particular the
        // reader deliberately advertises no actions behind a modal.
        let observed = ChromePageMirror.find(node, wants: [], in: page)
        func unavailable(_ row: ChromePageMirror.Row) -> JSONValue {
            let reason = row.actionBlock?.reason ?? "This row does not offer the requested action."
            return .object(["ok": .bool(false), "error": .string(row.actionBlock?.code ?? "node_not_actionable"),
                "reason": .string("Row " + (row.number ?? "\"" + ChromePageText.safe(row.label) + "\"") + ": " + reason
                    + " Read the page again with chrome.snapshot before choosing another control. Nothing was sent.")])
        }
        if actionId != "browser.chrome_wait", case .row(let shown) = observed, shown.actionBlock != nil { return unavailable(shown) }
        var row: ChromePageMirror.Row?
        if byNumber {
            if given.isEmpty { input["snapshot_id"] = .string(page.snapshotID) }
            guard let found = ChromePageMirror.find(node, wants: wants, in: page).row else {
                if case .row(let shown) = observed { return unavailable(shown) }
                let numbers = page.rows.compactMap { $0.number.flatMap(Int.init) }.sorted()
                let range = if let first = numbers.first, let last = numbers.last { "Valid rows on this page: \(first)–\(last)." }
                    else { "This page has no numbered rows." }
                let more = page.text.split(separator: "\n").first { $0.hasPrefix("More: ") }.map(String.init)
                let instruction = range + " Use a shown row or its label. "
                    + (more ?? "Read this tab again with chrome.snapshot {tab_id: \(page.tab)} to see its current rows.")
                let nextInput: [String: JSONValue]
                if let more, let address = more.dropFirst("More: ".count).components(separatedBy: " · ").first {
                    nextInput = ["page": .string("site:" + (URL(string: page.url)?.host ?? "")), "item": .string(address)]
                } else {
                    nextInput = ["action": .string("chrome.snapshot"), "args": .object(["tab_id": .int(page.tab)])]
                }
                let reason = "No row \(node) was shown in this read. \(instruction) Nothing was sent."
                return .object(["ok": .bool(false), "error": .string("no_such_row"), "reason": .string(reason),
                    "remedy": .object(["kind": .string("reread"), "instruction": .string(instruction),
                        "next_call": .object(["tool": .string("app"), "input": .object(nextInput)])])])
            }
            row = found
            input["node_id"] = .string(found.node)
        } else {
            let verb = actionId.replacingOccurrences(of: "browser.chrome_", with: "").replacingOccurrences(of: "_", with: " ")
            let found: ChromePageMirror.Row
            switch ChromePageMirror.find(node, wants: wants, in: page) {
            case .row(let match): found = match
            case .ambiguous(let rows):
                return .object(["ok": .bool(false), "error": .string("ambiguous_row"),
                    "reason": .string("More than one row that can \(verb) matches \"\(ChromePageText.safe(node))\": "
                        + ChromePageMirror.named(rows) + ". Use its row number or its whole label. Nothing was sent.")])
            case .none:
                switch observed {
                case .row(let shown): return unavailable(shown)
                case .ambiguous(let rows):
                    return .object(["ok": .bool(false), "error": .string("ambiguous_row"),
                        "reason": .string("More than one observed row matches \"\(ChromePageText.safe(node))\": "
                            + ChromePageMirror.named(rows) + ". Use its row number. Nothing was sent.")])
                case .none: break
                }
                return .object(["ok": .bool(false), "error": .string("no_such_row"),
                    "reason": .string("No row named \"\(ChromePageText.safe(node))\" was observed on the page last read ("
                        + ChromePageText.safe(page.title) + "). Use its row number, or read the page again with browser.chrome_snapshot. Nothing was sent.")])
            }
            row = found
            input["node_id"] = .string(found.node)
            if given.isEmpty { input["snapshot_id"] = .string(page.snapshotID) }
        }
        if actionId == "browser.chrome_select", let row, case .array(let values)? = input["values"] {
            input["values"] = .array(values.map { value in
                guard case .string(let wanted) = value else { return value }
                return .string(Self.option(wanted, in: row) ?? wanted)
            })
        }
        return nil
    }

    private static func option(_ wanted: String, in row: ChromePageMirror.Row) -> String? {
        let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixed = row.options.filter { $0.label.lowercased().hasPrefix(key) }
        return (row.options.first { $0.value.lowercased() == key } ?? row.options.first { $0.label.lowercased() == key }
            ?? (prefixed.count == 1 ? prefixed[0] : nil))?.value
    }

    public static func chromeFields(_ input: [String: JSONValue]) throws -> ChromeFields? {
        var fields = ChromeFields()
        func invalid(_ path: String, _ detail: String) -> ToolFailureError {
            ToolFailureError(detail + " Nothing was sent.", argumentPath: path, effects: .none,
                code: "bad_input", status: .refused, recovery: .correctArguments)
        }
        func text(_ value: JSONValue) -> String? {
            switch value {
            case .string(let s): return s
            case .int(let n): return String(n)
            case .double(let n): return n.isFinite ? String(n) : nil
            case .bool(let b): return b ? "true" : "false"
            default: return nil
            }
        }
        switch input["fields"] {
        case .object(let map)?:
            for key in map.keys.sorted() {
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let value = map[key].flatMap(text) else {
                    throw invalid("fields.\(key)", "Field \"\(key)\" needs a nonempty label and a string, number or boolean value.")
                }
                fields.pairs.append((label: key, value: value))
            }
        case .string(let line)?:
            for part in line.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
                if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard let cut = part.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                    throw invalid("fields", "Field fragment \"\(part)\" needs Label: value or Label=value.")
                }
                let label = part[..<cut].trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { throw invalid("fields", "Field fragment \"\(part)\" has no label.") }
                fields.pairs.append((label, part[part.index(after: cut)...].trimmingCharacters(in: .whitespaces)))
            }
        case nil, .null?: break
        default: throw invalid("fields", "fields is an object of scalar values or a Label: value string.")
        }
        switch input["submit"] {
        case .bool(true)?: fields.submit = "enter"
        case .string(let label)?: if !label.isEmpty, label != "false" { fields.submit = label }
        case nil, .null?, .bool(false)?: break
        default: throw invalid("submit", "submit is a button label, row or boolean.")
        }
        return fields.pairs.isEmpty && fields.submit == nil ? nil : fields
    }

    /// Resolve every field before typing so a missing label leaves the form untouched.
    public func runChromeFieldsCall(actionId: String, input: [String: JSONValue], fields: ChromeFields, direct: Bool,
                             surface: String, turn: Turn, execution: AppActionExecution, run: ChromeRun) async throws -> JSONValue {
        var tab = Self.chromeTabID(input["tab_id"])
        var navigationDocument: JSONValue?, navigationURL: JSONValue?, navigationTimingOrigin: JSONValue?
        var head: [String] = []
        var receipts: [JSONValue] = []
        if actionId == "browser.chrome_navigate" {
            var open = input
            open.removeValue(forKey: "fields"); open.removeValue(forKey: "submit")
            let opened = try await run(actionId, open)
            receipts.append(opened)
            guard case .object(let row) = opened, row["outcome"] == .string("succeeded"),
                  case .int(let granted)? = row["tabId"] else { return opened }
            tab = granted
            navigationDocument = row["documentId"]; navigationURL = row["url"]
            navigationTimingOrigin = row["receipt"]?.objectValue?["timings"]?.objectValue?["startedAtMs"]
            head.append(Self.chromeReceiptLine(actionId, row))
        }
        let session = turn.verifiedSessionID
        func refused(_ why: String) -> JSONValue {
            .object(["ok": .bool(false), "error": .string("fields_not_sent"), "receipt": .array(receipts),
                     "reason": .string((head + [why]).joined(separator: "\n"))])
        }
        let snapshotAdmission = await chromeFollowUpCheck("browser.chrome_snapshot", surface: surface, turn: turn)
        if case .object(var stop)? = snapshotAdmission.refusal {
            stop["completed"] = .array(head.map(JSONValue.string))
            stop["receipt"] = .array(receipts)
            stop["effects"] = .string(head.isEmpty ? "none" : "occurred")
            return .object(stop)
        }
        var seen = ChromePageMirror.page(tab: tab, dataRoot: securityCenter.dataRoot, session: session)
        func read() async throws -> ChromePageMirror.Page {
            // Offscreen fields still belong to the same form.
            var read: [String: JSONValue] = ["tab_id": tab.map(JSONValue.int) ?? .null, "scope": .string("page")]
            read["__chrome_document_id"] = navigationDocument
            read["__chrome_page_url"] = navigationURL
            read["__chrome_navigation_started_at_ms"] = navigationTimingOrigin
            let snapshot = try await run("browser.chrome_snapshot", read)
            receipts = receipts.map { receipt in
                guard case .object(let row) = receipt else { return receipt }
                return .object(Self.chromeNavigationReadTiming(row, snapshot: snapshot))
            }
            navigationTimingOrigin = nil
            guard case .object(let row) = snapshot, case .int(let id)? = row["tabId"],
                  case .string(let snapshotID)? = row["snapshotId"], !snapshotID.isEmpty else {
                throw ToolFailureError("Chrome page unavailable: " + (ChatToolOutcome.explanation(snapshot)
                    ?? "The snapshot did not provide a tab and snapshot identity."),
                    effects: .none, owner: "Chrome page snapshot", code: "chrome_page_unavailable")
            }
            tab = id
            // Only the first read belongs to navigation's observed identity.
            navigationDocument = nil; navigationURL = nil
            mirrorChromePage(snapshot, projection: ChromePageText.project(snapshot, turn: turn), turn: turn)
            guard let page = ChromePageMirror.page(tab: id, dataRoot: securityCenter.dataRoot, session: session),
                  page.snapshotID == snapshotID else {
                throw ToolFailureError("""
                    Chrome's returned snapshot could not publish its matching page mirror. Read the tab after repairing its snapshot; do not repeat fields \
                    already sent.
                    """,
                    effects: .none, owner: "Chrome page mirror", code: "chrome_page_unavailable")
            }
            return page
        }
        func tool(for row: ChromePageMirror.Row) -> String? {
            if row.acts.contains("select") { return "browser.chrome_select" }
            if row.acts.contains("set_checked"), !row.acts.contains("fill") { return "browser.chrome_set_checked" }
            if row.acts.contains("fill") { return "browser.chrome_fill" }
            return row.acts.contains("type") ? "browser.chrome_type" : nil
        }
        let valueActs: Set<String> = ["fill", "type", "select", "set_checked"]
        var page: ChromePageMirror.Page
        do { page = try await read() }
        catch { return refused("The page could not be read, so nothing was filled: " + error.localizedDescription) }
        // Row numbers mean the page the agent saw (or, with none, this first read).
        if seen == nil { seen = page }
        // Find every field (and the button) first: a missing or ambiguous name leaves the form untouched. Then fill in page order.
        var plan: [(label: String, value: String, index: Int)] = []
        var missing: [String] = [], unclear: [String] = []
        func fieldIssue(_ target: String) -> String {
            switch ChromePageMirror.find(target, wants: [], in: page, seen: seen) {
            case .row(let row): return row.actionBlock?.reason ?? "The observed row does not offer this action."
            case .ambiguous(let rows): return "More than one observed row matches: " + ChromePageMirror.named(rows) + "."
            case .none: return "No matching row was observed in this read."
            }
        }
        func check(_ label: String, _ wants: Set<String>) -> Int? {
            switch ChromePageMirror.find(label, wants: wants, in: page, seen: seen) {
            case .row(let row):
                if let block = row.actionBlock { missing.append("\"" + ChromePageText.safe(label) + "\": " + block.reason); return nil }
                return page.rows.firstIndex(of: row)
            case .ambiguous(let rows): unclear.append("\"" + ChromePageText.safe(label) + "\" could be " + ChromePageMirror.named(rows))
            case .none: missing.append("\"" + ChromePageText.safe(label) + "\": " + fieldIssue(label))
            }
            return nil
        }
        for pair in fields.pairs {
            if let index = check(pair.label, valueActs) { plan.append((pair.label, pair.value, index)) }
        }
        if let submit = fields.submit, !["enter", "true"].contains(submit.lowercased()) { _ = check(submit, ["click"]) }
        if !missing.isEmpty || !unclear.isEmpty {
            // The agent's row numbers stay those of the page it saw: this unseen whole-page read must not become what n12 means next call.
            if let seen, seen.snapshotID != page.snapshotID { ChromePageMirror.publish(seen, dataRoot: securityCenter.dataRoot, session: session) }
            return refused("Nothing was filled. " + (missing.isEmpty ? "" : "Fields unavailable on " + ChromePageText.safe(page.title) + ": "
                + missing.joined(separator: ", ") + ". ") + (unclear.isEmpty ? "" : "More than one row matches: " + unclear.joined(separator: "; ") + ". ")
                + "Use the label as the page shows it (for a choice, the option itself, e.g. \"Medium\") or its row number.")
        }
        plan.sort { $0.index < $1.index }
        var lines: [String] = [], ok = true, last: String?, lastTool = actionId
        var takeover: [String: JSONValue]?
        var followUpRefusal: JSONValue?
        func act(_ tool: String, target: String, wants: Set<String>, extra: [String: JSONValue], shown: String, submission: Bool = false) async -> Bool {
            if tool != actionId {
                let admission = await chromeFollowUpCheck(tool, surface: surface, turn: turn, enforceAutonomy: submission ? true : nil)
                if let stop = admission.stop {
                    followUpRefusal = admission.refusal
                    lines.append("✗ " + shown + ": " + stop); return false
                }
            }
            let row: ChromePageMirror.Row
            switch ChromePageMirror.find(target, wants: wants, in: page, seen: seen) {
            case .row(let match): row = match
            case .ambiguous(let rows): lines.append("✗ " + shown + ": the page changed and more than one row matches (" + ChromePageMirror.named(rows)
                + "); not sent"); return false
            case .none: lines.append("✗ " + shown + ": " + fieldIssue(target)); return false
            }
            if let block = row.actionBlock { lines.append("✗ " + shown + ": " + block.reason + " Nothing was sent."); return false }
            var call = extra
            call["tab_id"] = .int(page.tab); call["snapshot_id"] = .string(page.snapshotID); call["node_id"] = .string(row.node)
            call["expected_user_sequence"] = input["expected_user_sequence"]
            do {
                let result = try await run(tool, call)
                receipts.append(result)
                let rowPlace = row.number.map { " (row " + $0 + ")" } ?? ""
                if case .object(let done) = result, done["status"] == .string("yielded_to_user") {
                    takeover = done
                }
                if case .object(let done) = result, done["outcome"] == .string("succeeded") {
                    lines.append("✓ " + shown + rowPlace); lastTool = tool; return true
                }
                let why: String = if case .object(let done) = result, case .string(let text)? = done["reason"] ?? done["error"]
                    ?? done["outcome"] { text } else { "no clear outcome" }
                lines.append("✗ " + shown + rowPlace + ": " + ChromePageText.safe(why) + "; not retried"); return false
            } catch {
                receipts.append(ChatToolOutcome.failure(error: error, tool: tool))
                lines.append("✗ " + shown + ": " + ChromePageText.safe(error.localizedDescription)
                    + "; not retried. Read this tab again before continuing; do not repeat fields already sent.")
                return false
            }
        }
        for (index, item) in plan.enumerated() {
            if index > 0 {
                do { page = try await read() }
                catch { lines.append("✗ Page refresh failed: " + ChromePageText.safe(error.localizedDescription)
                    + "; remaining fields were not sent. Read this tab again before continuing."); ok = false; break }
            }
            guard let row = ChromePageMirror.find(item.label, wants: valueActs, in: page, seen: seen).row, let tool = tool(for: row) else {
                lines.append("✗ " + ChromePageText.safe(item.label) + ": " + fieldIssue(item.label)); ok = false; break
            }
            var extra: [String: JSONValue]
            switch tool {
            case "browser.chrome_select": extra = ["values": .array([.string(Self.option(item.value, in: row) ?? item.value)])]
            case "browser.chrome_set_checked":
                extra = ["checked": .bool(!["false", "no", "off", "0", "unchecked", "uncheck", ""].contains(item.value.lowercased()))]
            case "browser.chrome_type": extra = ["text": .string(item.value)]
            default: extra = ["value": .string(item.value)]
            }
            let wants: Set<String> = [String(tool.dropFirst("browser.chrome_".count))]
            guard await act(tool, target: item.label, wants: wants, extra: extra, shown: ChromePageText.safe(item.label)) else { ok = false; break }
            last = item.label
        }
        if ok, let submit = fields.submit {
            do { page = try await read() }
            catch { lines.append("✗ Page refresh failed: " + ChromePageText.safe(error.localizedDescription)
                + "; submission was not sent. Read this tab again before continuing."); ok = false }
            if ok, submit.lowercased() == "enter" || submit.lowercased() == "true" {
                if let last {
                    ok = await act("browser.chrome_keypress", target: last, wants: ["keypress"], extra: ["key": .string("Enter")], shown: "Enter",
                        submission: true)
                } else { lines.append("✗ Enter: no field was filled to press it in"); ok = false }
            } else if ok {
                ok = await act("browser.chrome_click", target: submit, wants: ["click"], extra: [:], shown: "click " + ChromePageText.safe(submit),
                    submission: true)
            }
        }
        let summary = (ok ? "" : "Stopped: ") + lines.joined(separator: " · ")
        if var takeover {
            takeover["ok"] = .bool(false)
            takeover["receipt"] = .array(receipts)
            takeover["text"] = .string((head + [summary]).joined(separator: "\n"))
            return .object(takeover)
        }
        let receipt = JSONValue.array(receipts)
        var result: [String: JSONValue] = [
            "ok": .bool(ok), "outcome": .string(ok ? "succeeded" : "failed"), "tabId": .int(page.tab),
            "fields": .string(summary), "tool": .string(actionId), "receipt": receipt,
            "verification": .string(ok ? (DeskContinuation.receiptIsUnresolved(receipt) ? "pending" : "satisfied") : "unavailable"),
        ]
        result["follow_up_refusal"] = followUpRefusal
        if direct, ok {
            let fresh = await freshChromePage(after: lastTool, tab: page.tab, sequence: nil, input: input, surface: surface, turn: turn, run: run)
            result["text"] = .string((head + [summary, "", fresh.text]).joined(separator: "\n"))
        } else if direct {
            result["text"] = .string((head + [summary]).joined(separator: "\n"))
        }
        return .object(result)
    }

    /// Snapshot rows remain attached to their workspace and exact tab until it closes.
    func mirrorChromePage(_ result: JSONValue, projection: ChromePageText.VisiblePageText, turn: Turn, closedBy actionId: String? = nil) {
        guard case .object(let page) = result else { return }
        if actionId == "browser.chrome_close_tab" {
            guard page["tabClosed"] == .bool(true), case .int(let tab)? = page["tabId"] else { return }
            ChromePageMirror.tabClosed(tab)
            return
        }
        if case .int(let tab)? = page["tabId"] { ChromePageMirror.tabLive(tab) }
        guard case .int(let tab)? = page["tabId"], case .string(let id)? = page["snapshotId"],
              let text = projection.text else { return }
        ChromePageMirror.publish(.init(tab: tab, title: ChromePageText.safe(page["title"]?.scalarText ?? ""),
                                       url: ChromePageText.safe(page["url"]?.scalarText ?? ""), snapshotID: id, text: text,
                                       rows: projection.rows), dataRoot: securityCenter.dataRoot, session: turn.verifiedSessionID)
    }

    /// Compare address, viewport and all shared rows; reads of different scopes can prove position only.
    public static func chromePageUnchanged(before: String, after: String) -> Bool {
        // Compare captured content and scroll position, excluding display row numbers.
        func print(_ text: String) -> [String] {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let second = lines.count > 1 ? lines[1] : ""
            let showing = second.range(of: #"showing \d+–\d+ of \d+px"#, options: .regularExpression).map { String(second[$0]) } ?? ""
            return [lines.first ?? "", showing] + chromeRowTexts(lines)
        }
        return print(before) == print(after)
    }

    public static func chromeTabID(_ value: JSONValue?) -> Int64? {
        if case .int(let id)? = value, id >= 0 { return id }
        return nil
    }

    private static func chromeRowTexts<S: StringProtocol>(_ lines: [S]) -> [String] {
        let lines = lines.map { String($0) }
        return ChromePageText.rowRanges(lines).map { range in
            lines[range].joined(separator: "\n").replacingOccurrences(of: #"^\s*\d+  "#, with: "", options: .regularExpression)
        }
    }

    /// A zero text delta is not a viewport comparison. Only the content agent's observation can establish that nothing changed in view.
    public static func onlyNewRows(_ page: String, before: String, viewportChanged: Bool? = nil) -> (text: String, new: Int) {
        // A row counts as already shown only when the same text stood beside the same neighbour (above or below) before: a new "Load more" with new rows around
        // it is new.
        func keys(_ texts: [String]) -> [(String, String, String)] {
            texts.indices.map { (texts[$0], $0 > 0 ? texts[$0 - 1] : "", $0 + 1 < texts.count ? texts[$0 + 1] : "") }
        }
        let old = keys(chromeRowTexts(before.split(separator: "\n", omittingEmptySubsequences: false)))
        let above = Set(old.map { $0.0 + "\u{0}" + $0.1 }), below = Set(old.map { $0.0 + "\u{0}" + $0.2 })
        var lines = page.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = keys(chromeRowTexts(lines))[...]
        let blocks = Dictionary(uniqueKeysWithValues: ChromePageText.rowRanges(lines.map(String.init)).map { ($0.lowerBound, $0) })
        var kept: [Substring] = [], left = 0
        var index = 0
        while index < lines.count {
            if let range = blocks[index], let (text, up, down) = shown.popFirst() {
                if above.contains(text + "\u{0}" + up) || below.contains(text + "\u{0}" + down) { left += 1 }
                else { kept.append(contentsOf: lines[range]) }
                index = range.upperBound
            } else { kept.append(lines[index]); index += 1 }
        }
        let new = chromeRowTexts(kept).count
        guard left > 0 else { return (page, new) }
        // Keep the observed rows when the viewport changed (or its comparison is incomplete), even if a previous document read included them.
        lines = new == 0 && viewportChanged != false
            ? page.split(separator: "\n", omittingEmptySubsequences: false) : kept
        // Place omission evidence before the footer so it stays associated with the rows.
        let lastRow = ChromePageText.rowRanges(lines.map(String.init)).last
        var at = lastRow?.upperBound
            ?? lines.firstIndex(where: { $0.isEmpty }).map { $0 + 1 } ?? lines.count
        if let lastRow, lastRow.count > 1, at < lines.count, lines[at].isEmpty { at += 1 }
        let note: String
        if new == 0 {
            note = if viewportChanged == false { "Nothing new came into view in this read: the viewport content is unchanged." }
                else if viewportChanged == true { "(The viewport changed; these rows were already included in the previous read.)" }
                else { "(Viewport change could not be verified; these rows were already included in the previous read.)" }
        } else {
            note = "(\(left) previously read rows left out; act on them by label)"
        }
        lines.insert(Substring(note), at: min(at, lines.count))
        return (lines.joined(separator: "\n"), new)
    }

    /// Compact act summaries omit ids already carried by the page.
    public static func chromeReceiptLine(_ actionId: String, _ obj: [String: JSONValue]) -> String {
        if actionId == "browser.chrome_scroll" {
            func number(_ key: String) -> Int? {
                switch obj[key] { case .int(let n)?: Int(n); case .double(let n)?: Int(n); default: nil }
            }
            let moved = number("movedY") ?? 0, sideways = number("movedX") ?? 0
            let end = obj["atBottom"] == .bool(true) ? "at the bottom" : obj["atTop"] == .bool(true) ? "at the top"
                : number("remainingDown").map { "\($0)px more below" } ?? ""
            if moved == 0, sideways == 0 { return "scroll: nothing moved" + (end.isEmpty ? "" : " (" + end + ")") }
            return "scrolled " + (moved != 0 ? "\(moved > 0 ? "down" : "up") \(abs(moved))px" : "\(sideways > 0 ? "right" : "left") \(abs(sideways))px")
                + (end.isEmpty ? "" : " · " + end)
        }
        var extra = obj
        for key in ["receipt", "tabId", "tabId", "requestedUrl", "status", "verified", "outcome", "title", "url",
                    "coordinateScope", "frameId", "observationScope", "userSequence", "snapshotId", "nodeId"] {
            extra.removeValue(forKey: key)
        }
        let verb = actionId.replacingOccurrences(of: "browser.chrome_", with: "").replacingOccurrences(of: "_", with: " ")
        let detail = extra.isEmpty ? "" : " · " + ((try? JSONValue.object(extra).serialize(pretty: false)) ?? "")
        return UntrustedText.neutralized(verb + " succeeded" + detail)
    }
}
