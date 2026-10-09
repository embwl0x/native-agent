import Foundation
import ChatOrchestration
import ChromeControl
import MacControl
import PersistenceCore
import ToolRegistry
import Senses

/// 2026-09-24 (tools-web): Chrome jobs in one call. A row can be named by its
/// label, snapshot_id defaults to the last page read on the tab, and a form
/// is filled and sent in one call (`fields` + `submit`) — the way `act steps`
/// works for Mac apps. Every act still goes through the extension one by one,
/// each clearing the same Trust gate her own call would.
extension AppToolExecutor {
    public typealias ChromeRun = (String, [String: JSONValue]) async throws -> JSONValue

    public struct ChromeFields {
        var pairs: [(label: String, value: String)] = []
        /// A button's label or row to click after filling, or "enter" to press Enter in the last field.
        var submit: String?
    }

    /// Which acts a verb can use on a row.
    private static let chromeWants: [String: Set<String>] = [
        "browser.chrome_click": ["click", "fill", "type"], "browser.chrome_double_click": ["double_click", "click", "fill", "type"],
        "browser.chrome_fill": ["fill"], "browser.chrome_type": ["type", "fill"], "browser.chrome_select": ["select"],
        "browser.chrome_keypress": ["keypress", "fill", "type", "click"], "browser.chrome_set_checked": ["set_checked"],
        "browser.chrome_wait": ["wait"], "browser.chrome_drag": ["drag"], "browser.chrome_drop_target": ["drop"],
        "browser.chrome_scroll_target": ["scroll"],
    ]

    /// Fills in what the last page read on this tab already says: a row named
    /// by its label, a missing snapshot_id, option labels, one value as a list.
    /// A refusal when a named row is not on that page; nil otherwise.
    public static func resolveChromeTarget(_ actionId: String, _ input: inout [String: JSONValue]) -> JSONValue? {
        guard let refusal = resolveChromeRows(actionId, &input) else { return nil }
        guard case .object(var fields) = refusal else { return refusal }
        fields["effects"] = .string("none")
        fields["provenance"] = .string("raw view · Chrome conversation page bindings and displayed row index; no extension request was sent")
        return .object(fields)
    }

    private static func resolveChromeRows(_ actionId: String, _ input: inout [String: JSONValue]) -> JSONValue? {
        if actionId == "browser.chrome_scroll" || actionId == "browser.chrome_drag" {
            if actionId == "browser.chrome_drag", let refusal = resolveChromeRow(actionId, &input) { return refusal }
            guard let target = input["target_node_id"], !(inputString(target) ?? "").isEmpty else { return nil }
            var destination = input
            destination["node_id"] = target
            if let refusal = resolveChromeRow(actionId == "browser.chrome_drag" ? "browser.chrome_drop_target" : "browser.chrome_scroll_target", &destination) { return refusal }
            input["target_node_id"] = destination["node_id"]
            input["snapshot_id"] = destination["snapshot_id"]
            return nil
        }
        return resolveChromeRow(actionId, &input)
    }

    private static func resolveChromeRow(_ actionId: String, _ input: inout [String: JSONValue]) -> JSONValue? {
        if actionId == "browser.chrome_select", case .string(let one)? = input["values"] { input["values"] = .array([.string(one)]) }
        guard let wants = chromeWants[actionId],
              let node = inputString(input["node_id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !node.isEmpty else { return nil }
        // The site sense owns its fresh source proof. Public calls own only
        // the numbers or labels that their last page actually showed.
        if SenseDoor.verifyingActCorner != nil { return nil }
        if node.range(of: #"^n\d+$"#, options: .regularExpression) != nil {
            return .object(["ok": .bool(false), "error": .string("internal_node_id"),
                "reason": .string("Internal node ids are not row numbers. Use the row number shown on this page or its label. Nothing was sent.")])
        }
        guard let page = ChromePageMirror.page(tab: chromeTabID(input["tab_id"]), session: ChatToolSessionContext.verifiedSessionId) else {
            return .object(["ok": .bool(false), "error": .string("no_page_read"),
                "reason": .string("No page has been read in this conversation. Read the page with chrome.snapshot before choosing a row. Nothing was sent.")])
        }
        if input["tab_id"] == nil || input["tab_id"] == .null { input["tab_id"] = .int(page.tab) }
        let given = inputString(input["snapshot_id"]) ?? ""
        guard given.isEmpty || given == page.snapshotID else {
            return .object(["ok": .bool(false), "error": .string("snapshot_stale"),
                "reason": .string("The supplied snapshot does not match the page last read. Read the page again with browser.chrome_snapshot. Nothing was sent.")])
        }
        let byNumber = node.range(of: #"^\d+$"#, options: .regularExpression) != nil
        var row: ChromePageMirror.Row?
        if byNumber {
            if given.isEmpty { input["snapshot_id"] = .string(page.snapshotID) }
            guard let found = ChromePageMirror.find(node, wants: wants, in: page).row else {
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
                let reason = page.rows.contains(where: { $0.number == node })
                    ? "Row \(node) on this page cannot perform this action. Nothing was sent."
                    : "No row \(node) on this page. \(instruction) Nothing was sent."
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
                return .object(["ok": .bool(false), "error": .string("no_such_row"),
                    "reason": .string("No row named \"\(ChromePageText.safe(node))\" that can \(verb) on the page last read ("
                        + ChromePageText.safe(page.title) + "). Use its row number, or read the page again with browser.chrome_snapshot. Nothing was sent.")])
            }
            row = found
            input["node_id"] = .string(found.node)
            if given.isEmpty { input["snapshot_id"] = .string(page.snapshotID) }
        }
        if actionId == "browser.chrome_select", let row, case .array(let values)? = input["values"] {
            input["values"] = .array(values.map { value in
                guard case .string(let wanted) = value else { return value }
                return .string(option(wanted, in: row) ?? wanted)
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

    /// `fields` as {label: value} or "Label: value; Label: value", and
    /// `submit` (a button label or row, or true to press Enter). Nil when absent.
    public static func chromeFields(_ input: [String: JSONValue]) -> ChromeFields? {
        var fields = ChromeFields()
        func text(_ value: JSONValue) -> String? {
            switch value {
            case .string(let s): return s
            case .int(let n): return String(n)
            case .double(let n): return String(n)
            case .bool(let b): return b ? "true" : "false"
            default: return nil
            }
        }
        switch input["fields"] {
        case .object(let map)?:
            fields.pairs = map.compactMap { key, value in text(value).map { (label: key, value: $0) } }
        case .string(let line)?:
            for part in line.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
                guard let cut = part.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
                let label = part[..<cut].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { fields.pairs.append((label, part[part.index(after: cut)...].trimmingCharacters(in: .whitespaces))) }
            }
        default: break
        }
        switch input["submit"] {
        case .bool(true)?: fields.submit = "enter"
        case .some(let value): if let label = text(value), !label.isEmpty, label != "false" { fields.submit = label }
        case nil: break
        }
        return fields.pairs.isEmpty && fields.submit == nil ? nil : fields
    }

    /// chrome_fill{fields, submit} on the current page, or chrome_navigate{url,
    /// fields, submit} after the page loads. Every label is found before
    /// anything is typed, so a missing field leaves the form untouched.
    public func runChromeFieldsCall(actionId: String, input: [String: JSONValue], fields: ChromeFields, direct: Bool,
                             surface: String, run: ChromeRun) async throws -> JSONValue {
        var tab = Self.chromeTabID(input["tab_id"])
        var head: [String] = []
        if actionId == "browser.chrome_navigate" {
            var open = input
            open.removeValue(forKey: "fields"); open.removeValue(forKey: "submit")
            let opened = try await run(actionId, open)
            guard case .object(let row) = opened, row["outcome"] == .string("succeeded"),
                  case .int(let granted)? = row["tabId"] else { return opened }
            tab = granted
            head.append(Self.chromeReceiptLine(actionId, row))
        }
        let session = ChatToolSessionContext.verifiedSessionId
        func refused(_ why: String) -> JSONValue {
            .object(["ok": .bool(false), "error": .string("fields_not_sent"), "reason": .string((head + [why]).joined(separator: "\n"))])
        }
        guard await chromeFollowUpAllowed("browser.chrome_snapshot", input: input, surface: surface) else {
            return refused("Reading the page needs your approval here, so nothing was filled. Call browser.chrome_snapshot, then fill one row at a time.")
        }
        var seen = ChromePageMirror.page(tab: tab, session: session)
        func read() async throws -> ChromePageMirror.Page? {
            // The whole page: a field below the fold is still on the form.
            let snapshot = try await run("browser.chrome_snapshot", ["tab_id": tab.map(JSONValue.int) ?? .null, "max_nodes": .int(200), "scope": .string("page")])
            guard case .object(let row) = snapshot, case .int(let id)? = row["tabId"] else { return nil }
            tab = id
            Self.mirrorChromePage(snapshot)
            return ChromePageMirror.page(tab: id, session: session)
        }
        func tool(for row: ChromePageMirror.Row) -> String? {
            if row.acts.contains("select") { return "browser.chrome_select" }
            if row.acts.contains("set_checked"), !row.acts.contains("fill") { return "browser.chrome_set_checked" }
            if row.acts.contains("fill") { return "browser.chrome_fill" }
            return row.acts.contains("type") ? "browser.chrome_type" : nil
        }
        let valueActs: Set<String> = ["fill", "type", "select", "set_checked"]
        guard var page = try await read() else { return refused("The page could not be read, so nothing was filled.") }
        // Row numbers mean the page she saw (or, with none, this first read).
        if seen == nil { seen = page }
        // Find every field (and the button) first: a missing or ambiguous
        // name leaves the form untouched. Then fill in page order.
        var plan: [(label: String, value: String, index: Int)] = []
        var missing: [String] = [], unclear: [String] = []
        func check(_ label: String, _ wants: Set<String>) -> Int? {
            switch ChromePageMirror.find(label, wants: wants, in: page, seen: seen) {
            case .row(let row): return page.rows.firstIndex(of: row)
            case .ambiguous(let rows): unclear.append("\"" + ChromePageText.safe(label) + "\" could be " + ChromePageMirror.named(rows))
            case .none: missing.append("\"" + ChromePageText.safe(label) + "\"")
            }
            return nil
        }
        for pair in fields.pairs {
            if let index = check(pair.label, valueActs) { plan.append((pair.label, pair.value, index)) }
        }
        if let submit = fields.submit, !["enter", "true"].contains(submit.lowercased()) { _ = check(submit, ["click"]) }
        if !missing.isEmpty || !unclear.isEmpty {
            // Her row numbers stay those of the page she saw: this unseen
            // whole-page read must not become what n12 means next call.
            if let seen, seen.snapshotID != page.snapshotID { ChromePageMirror.publish(seen, session: session) }
            return refused("Nothing was filled. " + (missing.isEmpty ? "" : "No field with that name on " + ChromePageText.safe(page.title) + ": "
                + missing.joined(separator: ", ") + ". ") + (unclear.isEmpty ? "" : "More than one row matches: " + unclear.joined(separator: "; ") + ". ")
                + "Use the label as the page shows it (for a choice, the option itself, e.g. \"Medium\") or its row number.")
        }
        plan.sort { $0.index < $1.index }
        var lines: [String] = [], ok = true, last: String?, lastTool = actionId
        var takeover: [String: JSONValue]?
        func act(_ tool: String, target: String, wants: Set<String>, extra: [String: JSONValue], shown: String, submission: Bool = false) async -> Bool {
            if tool != actionId, await !chromeFollowUpAllowed(tool, input: input, surface: surface, enforceAutonomy: submission ? true : nil) {
                lines.append("✗ " + shown + ": needs your approval here; call " + tool + " for it"); return false
            }
            for attempt in 0..<2 {
                let row: ChromePageMirror.Row
                switch ChromePageMirror.find(target, wants: wants, in: page, seen: seen) {
                case .row(let match): row = match
                case .ambiguous(let rows): lines.append("✗ " + shown + ": the page changed and more than one row matches (" + ChromePageMirror.named(rows) + "); not sent"); return false
                case .none: lines.append("✗ " + shown + ": no longer on the page"); return false
                }
                var call = extra
                call["tab_id"] = .int(page.tab); call["snapshot_id"] = .string(page.snapshotID); call["node_id"] = .string(row.node)
                call["expected_user_sequence"] = input["expected_user_sequence"]
                do {
                    let result = try await run(tool, call)
                    let rowPlace = row.number.map { " (row " + $0 + ")" } ?? ""
                    if case .object(let done) = result, done["status"] == .string("yielded_to_user") {
                        takeover = done
                    }
                    if case .object(let done) = result, done["outcome"] == .string("succeeded") {
                        lines.append("✓ " + shown + rowPlace); lastTool = tool; return true
                    }
                    let why: String = if case .object(let done) = result, case .string(let text)? = done["reason"] ?? done["error"] ?? done["outcome"] { text } else { "no clear outcome" }
                    lines.append("✗ " + shown + rowPlace + ": " + ChromePageText.safe(why) + "; not retried"); return false
                } catch {
                    let text = error.localizedDescription
                    // A stale page refuses before anything is sent: read again once.
                    if attempt == 0, text.contains("snapshot_stale") || text.contains("node_stale"),
                       let fresh = try? await read() { page = fresh; continue }
                    lines.append("✗ " + shown + ": " + ChromePageText.safe(text)); return false
                }
            }
            return false
        }
        for (index, item) in plan.enumerated() {
            if index > 0, let fresh = try? await read() { page = fresh }
            guard let row = ChromePageMirror.find(item.label, wants: valueActs, in: page, seen: seen).row, let tool = tool(for: row) else {
                lines.append("✗ " + ChromePageText.safe(item.label) + ": no longer on the page, or no longer one row"); ok = false; break
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
            if let fresh = try? await read() { page = fresh }
            if submit.lowercased() == "enter" || submit.lowercased() == "true" {
                if let last {
                    ok = await act("browser.chrome_keypress", target: last, wants: ["keypress", "fill", "type"], extra: ["key": .string("Enter")], shown: "Enter", submission: true)
                } else { lines.append("✗ Enter: no field was filled to press it in"); ok = false }
            } else {
                ok = await act("browser.chrome_click", target: submit, wants: ["click"], extra: [:], shown: "click " + ChromePageText.safe(submit), submission: true)
            }
        }
        let summary = (ok ? "" : "Stopped: ") + lines.joined(separator: " · ")
        if var takeover {
            takeover["ok"] = .bool(false)
            takeover["text"] = .string((head + [summary]).joined(separator: "\n"))
            return .object(takeover)
        }
        guard direct else {
            return .object(["ok": .bool(ok), "outcome": .string(ok ? "succeeded" : "failed"), "tabId": .int(page.tab),
                            "fields": .string(summary), "tool": .string(actionId)])
        }
        let fresh = await freshChromePage(after: lastTool, tab: page.tab, sequence: nil, input: input, surface: surface, run: run)
        let text = (head + [summary, "", fresh]).joined(separator: "\n")
        guard ok else {
            return .object(["ok": .bool(false), "outcome": .string("failed"), "tabId": .int(page.tab),
                            "fields": .string(summary), "tool": .string(actionId), "text": .string(text)])
        }
        return .string(text)
    }

    /// Snapshot rows remain attached to their exact tab until it closes.
    public static func mirrorChromePage(_ result: JSONValue, closedBy actionId: String? = nil, input: [String: JSONValue] = [:]) {
        guard case .object(let page) = result else { return }
        if actionId == "browser.chrome_close_tab" {
            guard page["tabClosed"] == .bool(true), case .int(let tab)? = page["tabId"] else { return }
            ChromePageMirror.forget(tab: tab)
            ChromePageMirror.tabClosed(tab)
            return
        }
        if case .int(let tab)? = page["tabId"] { ChromePageMirror.tabLive(tab) }
        guard case .int(let tab)? = page["tabId"], case .string(let id)? = page["snapshotId"],
              let text = ChromePageText.render(result) else { return }
        ChromePageMirror.publish(.init(tab: tab, title: ChromePageText.safe(inputString(page["title"]) ?? ""),
                                       url: ChromePageText.safe(inputString(page["url"]) ?? ""), snapshotID: id, text: text,
                                       rows: ChromePageText.rows(result)), session: ChatToolSessionContext.verifiedSessionId)
    }

    /// Same address, same scroll position and height, and the same rows (as
    /// far as both reads go; a read of another scope compares position only):
    /// nothing moved or changed.
    public static func chromePageUnchanged(before: String, after: String) -> Bool {
        // A fingerprint, not the header's wording: title/address line, scroll
        // position, and every row's text (row numbers aside).
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

    /// Row lines' text with the row number off.
    private static func chromeRowTexts<S: StringProtocol>(_ lines: [S]) -> [String] {
        let lines = lines.map { String($0) }
        return ChromePageText.rowRanges(lines).map { range in
            lines[range].joined(separator: "\n").replacingOccurrences(of: #"^\s*\d+  "#, with: "", options: .regularExpression)
        }
    }

    /// After a scroll, the rows the last read already showed are left out
    /// (they are still there, and act by their label): only what came into view.
    /// A read that is only a spinner or "Loading…" (three rows at most).
    public static func chromeStillLoading(_ snapshot: JSONValue) -> Bool {
        if case .object(let page) = snapshot, page["document"] != nil { return false }
        let rows = ChromePageText.rows(snapshot).filter { !$0.label.isEmpty }
        return rows.count <= 3 && (rows.isEmpty || rows.contains { $0.role == "progressbar" || $0.label.lowercased().hasPrefix("loading") })
    }

    /// A zero text delta is not a viewport comparison. Only the content
    /// agent's observation can establish that nothing changed in view.
    public static func onlyNewRows(_ page: String, before: String, viewportChanged: Bool? = nil) -> (text: String, new: Int) {
        // A row counts as already shown only when the same text stood beside
        // the same neighbour (above or below) before: a new "Load more" with
        // new rows around it is new.
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
        // Keep the observed rows when the viewport changed (or its comparison
        // is incomplete), even if a previous document read included them.
        lines = new == 0 && viewportChanged != false
            ? page.split(separator: "\n", omittingEmptySubsequences: false) : kept
        // After the rows, before the footer: say what was left out.
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

    /// A successful act as one line: what it did and anything it measured
    /// (scroll distance, typed count), without ids the page already carries.
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
