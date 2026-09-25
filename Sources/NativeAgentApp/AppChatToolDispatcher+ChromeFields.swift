import CoreGraphics
import Foundation
import ChatOrchestration
import MacControl
import PersistenceCore

/// 2026-09-24 (tools-web): Chrome jobs in one call. A row can be named by its
/// label, snapshot_id defaults to the last page read on the tab, and a form
/// is filled and sent in one call (`fields` + `submit`) — the way `act steps`
/// works for Mac apps. Every act still goes through the extension one by one,
/// each clearing the same Trust gate her own call would.
extension AppChatToolDispatcher {
    typealias ChromeRun = (String, [String: JSONValue]) async throws -> JSONValue

    struct ChromeFields {
        var pairs: [(label: String, value: String)] = []
        /// A button's label or row to click after filling, or "enter" to press Enter in the last field.
        var submit: String?
    }

    /// Which acts a verb can use on a row.
    private static let chromeWants: [String: Set<String>] = [
        "browser.chrome_click": ["click"], "browser.chrome_double_click": ["double_click", "click"],
        "browser.chrome_fill": ["fill"], "browser.chrome_type": ["type", "fill"], "browser.chrome_select": ["select"],
        "browser.chrome_keypress": ["keypress", "fill", "type", "click"], "browser.chrome_set_checked": ["set_checked"],
    ]

    /// Fills in what the last page read on this tab already says: a row named
    /// by its label, a missing snapshot_id, option labels, one value as a list.
    /// A refusal when a named row is not on that page; nil otherwise.
    static func resolveChromeTarget(_ actionId: String, _ input: inout [String: JSONValue]) -> JSONValue? {
        if actionId == "browser.chrome_select", case .string(let one)? = input["values"] { input["values"] = .array([.string(one)]) }
        guard let wants = chromeWants[actionId],
              let page = ChromePageMirror.page(lease: inputString(input["lease_id"]), session: ChatToolSessionContext.verifiedSessionId),
              let node = inputString(input["node_id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !node.isEmpty else { return nil }
        let given = inputString(input["snapshot_id"]) ?? ""
        let byNumber = node.range(of: #"^n?\d+$"#, options: .regularExpression) != nil
        var row: ChromePageMirror.Row?
        if byNumber {
            guard given.isEmpty || given == page.snapshotID else { return nil }
            input["snapshot_id"] = .string(page.snapshotID)
            row = ChromePageMirror.find(node, wants: wants, in: page).row
        } else if page.rows.contains(where: { $0.node == node }) {
            return nil
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
            input["snapshot_id"] = .string(page.snapshotID)
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
    static func chromeFields(_ input: [String: JSONValue]) -> ChromeFields? {
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
        if let index = fields.pairs.firstIndex(where: { $0.label.lowercased() == "submit" }) {
            fields.submit = fields.pairs.remove(at: index).value
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
    func runChromeFieldsCall(actionId: String, input: [String: JSONValue], fields: ChromeFields, direct: Bool,
                             surface: String, run: ChromeRun) async throws -> JSONValue {
        var lease = Self.inputString(input["lease_id"]) ?? ""
        var head: [String] = []
        if actionId == "browser.chrome_navigate" {
            var open = input
            open.removeValue(forKey: "fields"); open.removeValue(forKey: "submit")
            let opened = try await run(actionId, open)
            await preloadBrowserTools(input)
            guard case .object(let row) = opened, row["outcome"] == .string("succeeded"),
                  case .string(let granted)? = row["leaseId"] else { return opened }
            lease = granted
            if case .string(let url)? = row["url"] { await ChromeControlRuntime.shared.notePage(url: url, leaseID: granted) }
            head.append(Self.chromeReceiptLine(actionId, row))
        }
        let session = ChatToolSessionContext.verifiedSessionId
        func refused(_ why: String) -> JSONValue {
            .object(["ok": .bool(false), "error": .string("fields_not_sent"), "reason": .string((head + [why]).joined(separator: "\n"))])
        }
        if await ChromeControlRuntime.shared.actionBlockedOnPost(leaseID: lease, verifiedSessionID: session) {
            return refused(Self.postOnBackgroundNote + " Nothing was sent.")
        }
        guard await chromeFollowUpAllowed("browser.chrome_snapshot", input: input, surface: surface) else {
            return refused("Reading the page needs your approval here, so nothing was filled. Call browser.chrome_snapshot, then fill one row at a time.")
        }
        var seen = ChromePageMirror.page(lease: lease, session: session)
        func read() async throws -> ChromePageMirror.Page? {
            let snapshot = try await run("browser.chrome_snapshot", ["lease_id": .string(lease), "max_nodes": .int(200)])
            guard case .object(let row) = snapshot, case .string(let id)? = row["leaseId"] else { return nil }
            lease = id
            Self.mirrorChromePage(snapshot)
            return ChromePageMirror.page(lease: id, session: session)
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
            return refused("Nothing was filled. " + (missing.isEmpty ? "" : "Not in view on " + ChromePageText.safe(page.title) + ": "
                + missing.joined(separator: ", ") + ". ") + (unclear.isEmpty ? "" : "More than one row matches: " + unclear.joined(separator: "; ") + ". ")
                + "Use the whole label or the row number the page shows, or scroll first.")
        }
        plan.sort { $0.index < $1.index }
        var lines: [String] = [], ok = true, last: String?, lastTool = actionId
        func act(_ tool: String, target: String, wants: Set<String>, extra: [String: JSONValue], shown: String) async -> Bool {
            if tool != actionId, await !chromeFollowUpAllowed(tool, input: input, surface: surface) {
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
                call["lease_id"] = .string(lease); call["snapshot_id"] = .string(page.snapshotID); call["node_id"] = .string(row.node)
                do {
                    let result = try await run(tool, call)
                    let rowNumber = row.node.hasPrefix("n") ? String(row.node.dropFirst()) : row.node
                    if case .object(let done) = result, done["outcome"] == .string("succeeded") {
                        lines.append("✓ " + shown + " (row " + rowNumber + ")"); lastTool = tool; return true
                    }
                    let why: String = if case .object(let done) = result, case .string(let text)? = done["reason"] ?? done["error"] ?? done["outcome"] { text } else { "no clear outcome" }
                    lines.append("✗ " + shown + " (row " + rowNumber + "): " + ChromePageText.safe(why) + "; not retried"); return false
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
                    ok = await act("browser.chrome_keypress", target: last, wants: ["keypress", "fill", "type"], extra: ["key": .string("Enter")], shown: "Enter")
                } else { lines.append("✗ Enter: no field was filled to press it in"); ok = false }
            } else {
                ok = await act("browser.chrome_click", target: submit, wants: ["click"], extra: [:], shown: "click " + ChromePageText.safe(submit))
            }
        }
        let summary = (ok ? "" : "Stopped: ") + lines.joined(separator: " · ")
        guard direct else {
            return .object(["ok": .bool(ok), "outcome": .string(ok ? "succeeded" : "failed"), "leaseId": .string(lease),
                            "fields": .string(summary), "tool": .string(actionId)])
        }
        let fresh = await freshChromePage(after: lastTool, lease: lease, sequence: nil, input: input, surface: surface, run: run)
        return .string((head + [summary, "", fresh]).joined(separator: "\n"))
    }

    /// A main_content read of a page with no main or article region comes
    /// back empty; read the whole page instead, once.
    static func wholePageIfNoMain(_ result: JSONValue, input: [String: JSONValue], run: ChromeRun) async throws -> JSONValue {
        guard inputString(input["scope"]) == "main_content", case .object(let page) = result,
              case .array(let nodes)? = page["nodes"], nodes.isEmpty,
              case .object(let reading)? = page["reading"], reading["mainContentAvailable"] != .bool(true) else { return result }
        var whole = input
        whole["scope"] = .string("page")
        if case .string(let lease)? = page["leaseId"] { whole["lease_id"] = .string(lease) }
        return try await run("browser.chrome_snapshot", whole)
    }

    /// Keeps the page a snapshot read in the mirror (home, `tab.N`, labels);
    /// a released tab leaves it.
    static func mirrorChromePage(_ result: JSONValue, releasedBy actionId: String? = nil, input: [String: JSONValue] = [:]) {
        guard case .object(let page) = result else { return }
        if actionId == "browser.chrome_release" {
            // A refused release (released:false) leaves the tab and its page.
            guard page["released"] == .bool(true) || page["tabClosed"] == .bool(true) else { return }
            // The lease the release names is the one that closed; an input
            // lease_id may be an empty pair the provider serialized.
            if let lease = [inputString(page["leaseId"]), inputString(input["lease_id"])].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                ChromePageMirror.forget(lease: lease)
            }
            if page["tabClosed"] == .bool(true), case .int(let tab)? = page["tabId"] { ChromePageMirror.tabClosed(tab) }
            return
        }
        if case .int(let tab)? = page["tabId"] { ChromePageMirror.tabLive(tab) }
        guard case .string(let lease)? = page["leaseId"], case .string(let id)? = page["snapshotId"],
              let text = ChromePageText.render(result) else { return }
        ChromePageMirror.publish(.init(lease: lease, title: ChromePageText.safe(inputString(page["title"]) ?? ""),
                                       url: ChromePageText.safe(inputString(page["url"]) ?? ""), snapshotID: id, text: text,
                                       rows: ChromePageText.rows(result)), session: ChatToolSessionContext.verifiedSessionId)
    }

    /// The tab's lease is gone (lapsed, released or yielded), so the call never reached a page.
    static func chromeLeaseGone(_ error: Error) -> Bool {
        if case ChromeControlRuntimeError.leaseEnded = error { return true }
        let text = error.localizedDescription
        return text.contains("lease_not_found") || text.contains("lease_expired")
    }

    /// Same address, same scroll position and height, and the same rows (as
    /// far as both reads go; a read of another scope compares position only):
    /// nothing moved or changed.
    static func chromePageUnchanged(before: String, after: String) -> Bool {
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

    /// Row lines' text with the row number off.
    private static func chromeRowTexts<S: StringProtocol>(_ lines: [S]) -> [String] {
        lines.filter { $0.range(of: #"^\s*\d+  "#, options: .regularExpression) != nil }
            .map { $0.replacingOccurrences(of: #"^\s*\d+  "#, with: "", options: .regularExpression) }
    }

    /// After a scroll, the rows the last read already showed are left out
    /// (they are still there, and act by their label): only what came into view.
    /// A read that is only a spinner or "Loading…" (three rows at most).
    static func chromeStillLoading(_ snapshot: JSONValue) -> Bool {
        let rows = ChromePageText.rows(snapshot).filter { !$0.label.isEmpty }
        return rows.count <= 3 && (rows.isEmpty || rows.contains { $0.role == "progressbar" || $0.label.lowercased().hasPrefix("loading") })
    }

    /// The person is away: the screen is locked, or no input for 3 minutes
    /// (the same system idle clock her home screen reads).
    static func macPersonAway() -> Bool {
        if MacScreenLock.isLocked() { return true }
        guard let any = CGEventType(rawValue: ~0) else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        return idle.isFinite && idle >= 180
    }

    /// `stalled`: the scroll moved but nothing new came into view, even after
    /// waiting — say that in one line instead of counting the old rows.
    /// `personHere`: the tab was not rendered for the scroll because he is at the Mac.
    static func onlyNewRows(_ page: String, before: String, stalled: Bool = false, personHere: Bool = false) -> (text: String, new: Int) {
        let row = #"^\s*\d+  "#
        // A row counts as already shown only when the same text stood beside
        // the same neighbour (above or below) before: a new "Load more" with
        // new rows around it is new.
        func keys(_ texts: [String]) -> [(String, String, String)] {
            texts.indices.map { (texts[$0], $0 > 0 ? texts[$0 - 1] : "", $0 + 1 < texts.count ? texts[$0 + 1] : "") }
        }
        let old = keys(chromeRowTexts(before.split(separator: "\n")))
        let above = Set(old.map { $0.0 + "\u{0}" + $0.1 }), below = Set(old.map { $0.0 + "\u{0}" + $0.2 })
        var lines = page.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = keys(chromeRowTexts(lines))[...]
        var kept: [Substring] = [], left = 0
        for line in lines {
            if line.range(of: row, options: .regularExpression) != nil, let (text, up, down) = shown.popFirst(),
               above.contains(text + "\u{0}" + up) || below.contains(text + "\u{0}" + down) { left += 1; continue }
            kept.append(line)
        }
        let new = chromeRowTexts(kept).count
        guard left > 0 else { return (page, new) }
        lines = kept
        // After the rows, before the footer: say what was left out.
        let at = lines.lastIndex(where: { $0.range(of: row, options: .regularExpression) != nil }).map { $0 + 1 }
            ?? lines.firstIndex(where: { $0.isEmpty }).map { $0 + 1 } ?? lines.count
        lines.insert(stalled && new == 0
            ? (personHere
                ? "Nothing new came into view: a feed in a background tab doesn't load more while the Mac is in use. The rest comes once it has been idle a few minutes."
                : "Nothing new came into view after waiting: the page did not load more. Scroll again to retry; if it stays the same, this is as far as it goes.")
            : "(\(left) rows still in view from the last read left out; act on them by label)", at: min(at, lines.count))
        return (lines.joined(separator: "\n"), new)
    }

    /// A successful act as one line: what it did and anything it measured
    /// (scroll distance, typed count), without ids the page already carries.
    static func chromeReceiptLine(_ actionId: String, _ obj: [String: JSONValue]) -> String {
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
        for key in ["receipt", "leaseId", "tabId", "requestedUrl", "status", "verified", "outcome", "title", "url",
                    "coordinateScope", "frameId", "observationScope", "userSequence", "snapshotId", "nodeId"] {
            extra.removeValue(forKey: key)
        }
        let verb = actionId.replacingOccurrences(of: "browser.chrome_", with: "").replacingOccurrences(of: "_", with: " ")
        let detail = extra.isEmpty ? "" : " · " + ((try? JSONValue.object(extra).serialize(pretty: false)) ?? "")
        return UntrustedText.neutralized(verb + " succeeded" + detail)
    }
}
