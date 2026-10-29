import Foundation
import os
import NativeAgentCore
import PersistenceCore
import ChromeControl
// Blueprint: | `HerScreenRooms+Web.swift` | `HerScreen`: `tabName`, `tabTitle`, `webTabCell`. Browser label lookup selects only actionable source labels, never nearby text. |

/// Root-and-session-scoped browser reads supply home, tab rooms and label-to-node lookup without another tool call.
public enum ChromePageMirror {
    public struct Option: Sendable, Equatable {
        public let label: String, value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public struct Row: Sendable, Equatable {
        public let node: String, role: String, label: String
        /// The number actually shown in the page, including inline link references.
        /// A retained internal node without a visible reference has no row number.
        public let number: String?
        public let acts: Set<String>
        public let options: [Option]
        public init(node: String, role: String, label: String, acts: Set<String>, options: [Option], number: String? = nil) {
            self.node = node; self.role = role; self.label = label; self.acts = acts; self.options = options; self.number = number
        }
    }

    public struct Page: Sendable {
        public let tab: Int64
        public let title: String, url: String, snapshotID: String, text: String
        public let rows: [Row]
        public let at: Date
        public init(tab: Int64, title: String, url: String, snapshotID: String, text: String, rows: [Row], at: Date = Date()) {
            self.tab = tab; self.title = title; self.url = url; self.snapshotID = snapshotID
            self.text = text; self.rows = rows; self.at = at
        }
    }

    private struct State {
        var pages: [String: [Int64: Page]] = [:]
        var current: [String: Int64] = [:]
        var closed: Set<Int64> = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Keep only pages this chat has read. This cache is evidence, not tab ownership.
    public static func publish(_ page: Page, dataRoot: URL, session: String?) {
        let who = dataRoot.standardizedFileURL.path + "\u{0}" + (session ?? "")
        state.withLock { state in
            state.pages[who, default: [:]][page.tab] = page
            state.current[who] = page.tab
            if let saved = state.pages[who], saved.count > 16,
               let oldest = saved.values.min(by: { $0.at < $1.at }) {
                state.pages[who]?[oldest.tab] = nil
            }
            if state.pages.count > 64, let oldest = state.pages.keys.filter({ $0 != who }).min(by: {
                (state.pages[$0]?.values.map(\.at).max() ?? .distantPast) < (state.pages[$1]?.values.map(\.at).max() ?? .distantPast)
            }) { state.pages[oldest] = nil; state.current[oldest] = nil }
        }
    }

    /// An explicit tab, else this chat's last tab; only evidence it read itself.
    public static func page(tab: Int64?, dataRoot: URL, session: String?) -> Page? {
        let who = dataRoot.standardizedFileURL.path + "\u{0}" + (session ?? "")
        return state.withLock { state in
            guard let id = tab ?? state.current[who] else { return nil }
            return state.pages[who]?[id]
        }
    }

    public static func forget(tab: Int64) {
        state.withLock { state in
            for who in Array(state.pages.keys) { state.pages[who]?[tab] = nil }
            state.current = state.current.filter { $0.value != tab }
        }
    }

    /// Only an explicit close removes a tab's saved page from home.
    public static func tabClosed(_ id: Int64) {
        forget(tab: id)
        state.withLock { state in if state.closed.count > 256 { state.closed = [] }; state.closed.insert(id) }
    }
    public static func isClosed(_ id: Int64) -> Bool { state.withLock { state in state.closed.contains(id) } }
    /// A tab seen live again (Chrome can reuse an id after a restart).
    public static func tabLive(_ id: Int64) { state.withLock { state in _ = state.closed.remove(id) } }

    public enum Match: Equatable {
        case row(Row), none, ambiguous([Row])
        public var row: Row? { if case .row(let row) = self { row } else { nil } }
    }

    /// A row by its visible number ("12") or its label, among rows that can do
    /// one of `wants`. Never a guess between two: a label matches exactly
    /// (case, spaces and a trailing colon aside), else by prefix or substring
    /// only when one actionable row has it. Source-provided accessible labels
    /// belong to that control; nearby text never supplies a target. A number
    /// from an older page (`seen`) is found again by role,
    /// label and the rows beside it, and only when that is unique.
    public static func find(_ target: String, wants: Set<String>, in page: Page, seen: Page? = nil) -> Match {
        func one(_ rows: [Row]) -> Match? { rows.count == 1 ? .row(rows[0]) : rows.count > 1 ? .ambiguous(rows) : nil }
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = raw
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
            guard let seen, seen.snapshotID != page.snapshotID else {
                return page.rows.first { $0.number == digits && !wants.isDisjoint(with: $0.acts) }.map(Match.row) ?? .none
            }
            guard let at = seen.rows.firstIndex(where: { $0.number == digits && !wants.isDisjoint(with: $0.acts) }) else { return .none }
            let old = seen.rows[at]
            func label(_ rows: [Row], _ i: Int) -> String? { rows.indices.contains(i) ? norm(rows[i].label) : nil }
            let same = page.rows.indices.filter { !wants.isDisjoint(with: page.rows[$0].acts) && page.rows[$0].role == old.role && norm(page.rows[$0].label) == norm(old.label) }
            if same.count < 2 { return one(same.map { page.rows[$0] }) ?? .none }
            let beside = same.filter { label(page.rows, $0 - 1) == label(seen.rows, at - 1) && label(page.rows, $0 + 1) == label(seen.rows, at + 1) }
            return beside.count == 1 ? .row(page.rows[beside[0]]) : .ambiguous(same.map { page.rows[$0] })
        }
        let wanted = norm(raw)
        guard !wanted.isEmpty else { return .none }
        let able = page.rows.filter { !wants.isDisjoint(with: $0.acts) }
        if let exact = one(able.filter { norm($0.label) == wanted }) { return exact }
        if let loose = one(able.filter { norm($0.label).hasPrefix(wanted) || (wanted.count > 1 && norm($0.label).contains(wanted)) }) { return loose }
        return .none
    }

    /// Candidates named for a refusal: `row 5 "Email", row 9 "Email notifications"`.
    public static func named(_ rows: [Row]) -> String {
        rows.prefix(6).map { ($0.number.map { "row " + $0 + " " } ?? "") + "\"" + $0.label.prefix(40) + "\"" }
            .joined(separator: ", ") + (rows.count > 6 ? " and \(rows.count - 6) more" : "")
    }

    public static func norm(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :*"))
    }
}

/// Home reads the mirror; opening tab.N refreshes its page through the workspace owner.
extension HerScreen {
    /// Tab numbers start at 1 per chat, increase only and are never reused.
    static func tabName(_ tab: Int64, dataRoot: URL, scope: String) -> String {
        do {
            return "tab.\(try withNames(dataRoot) { try $0.number("tab:" + scope, id: String(tab)) { [String(tab)] } })"
        } catch { return nameFailure(error) }
    }

    /// A page's title, or its address when the page has none yet.
    static func tabTitle(_ page: ChromePageMirror.Page) -> String {
        if !page.title.isEmpty { return page.title }
        let bare = page.url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        return bare.isEmpty ? "untitled" : bare
    }

    /// Home's PLACES cell for this chat's tab, or nil when it has none.
    static func webTabCell(dataRoot: URL, scope: String, now: Date) -> String? {
        guard let page = ChromePageMirror.page(tab: nil, dataRoot: dataRoot, session: scope) else { return nil }
        return tabName(page.tab, dataRoot: dataRoot, scope: scope) + " \"" + clip(tabTitle(page), 28) + "\" "
            + age(now.timeIntervalSince(page.at))
    }

    /// A web name to its action: `tab.N` (read it fresh), `tab.N.go|click|fill|more`, `browser.go`.
    /// `scope` is the chat the rooms were drawn for, even outside a bound turn.
    static func webTarget(_ name: String, verb: String?, dataRoot: URL, scope: String) -> Target? {
        do {
            if name == "browser", verb == "go" {
                return .action(.perform(tool: "browser.chrome_navigate", input: [:], title: "Open a website", textField: "url", isEffect: true))
            }
            guard name.hasPrefix("tab."), let n = Int(name.dropFirst(4)),
                  let saved = try withNames(dataRoot, { $0.id("tab:" + scope, n) }),
                  let tab = Int64(saved) else { return nil }
            let bound: [String: JSONValue] = ["tab_id": .int(tab)]
            switch verb {
            case nil:
                let place = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot",
                    input: bound.merging(["max_nodes": .int(150), "scope": .string("main_content")]) { a, _ in a }, title: "Browser tab")
                return .action(.window(AgentWorkspaceNavigation.windowAction(place)))
            // A tab User takes over is refused by the browser owner.
            case "go": return .action(.perform(tool: "browser.chrome_navigate", input: bound, title: "Go to an address", textField: "url", isEffect: true))
            case "click": return .action(.perform(tool: "browser.chrome_click", input: bound, title: "Click in " + name, textField: "node_id", isEffect: true))
            case "fill": return .action(.perform(tool: "browser.chrome_fill", input: bound, title: "Fill in " + name, textField: "fields", isEffect: true))
            case "more":
                return .action(.perform(tool: "browser.chrome_scroll", input: bound.merging(["delta_x": .int(0), "delta_y": .int(800)]) { a, _ in a },
                                        title: "Scroll " + name, textField: nil, isEffect: true))
            default: return nil
            }
        } catch { return .page(nameFailure(error)) }
    }

    /// A Chrome tab as a room: its title and address, the first rows of the
    /// page as last read, and the one-call verbs by its name.
    static func tabRoom(_ input: [String: JSONValue], dataRoot: URL, scope: String, issue: String?, now: Date) -> String {
        let tab: Int64? = if case .int(let value)? = input["tab_id"] { value } else { nil }
        guard let page = ChromePageMirror.page(tab: tab, dataRoot: dataRoot, session: scope) else {
            return screen(["TAB", "no page read"], [["No page has been read in this tab yet."], issue.map { section("READ", [$0]) } ?? []],
                verbs: [("browser.go", "open a website (text: its address)")], back: "Back: home · browser.")
        }
        let name = tabName(page.tab, dataRoot: dataRoot, scope: scope)
        let rows = page.text.split(separator: "\n").map(String.init)
            .filter { $0.range(of: #"^\s*\d+  "#, options: .regularExpression) != nil }
        let cap = 24
        var shown = rows.prefix(cap).map { clip($0, 110) }
        if rows.count > cap { shown.append("+\(rows.count - cap) rows in this snapshot · app {action:\"chrome.snapshot\"} reads a bounded snapshot") }
        if shown.isEmpty { shown = ["no numbered rows in this saved snapshot"] }
        let lines = page.text.split(separator: "\n").map(String.init)
        let status = lines.dropFirst().first.map { $0.replacingOccurrences(of: #"^snapshot_id \S+ ?·? ?"#, with: "", options: .regularExpression) } ?? ""
        return screen([name, "Chrome", tabTitle(page), "read " + age(now.timeIntervalSince(page.at)) + " ago"],
            [section("AT", [clip(page.url, 100)] + (status.isEmpty ? [] : [clip(status, 100)])), section("PAGE", shown),
             issue.map { section("READ", [$0]) } ?? []],
            verbs: [(name, "read it again"), (name + ".go", "open another address here (text: url)"),
                    (name + ".click", "click a row (text: its number or label)"),
                    (name + ".fill", "fill and send (text: Email: a@b; Message: hi; submit: Send)"),
                    (name + ".more", "scroll down")],
            back: "Back: home · browser.")
    }

    /// The browser place: whether Chrome is connected and this chat's tab.
    static func browserRoom(dataRoot: URL, scope: String, person: String, now: Date) -> String {
        let link = BrowserConnectionMirror.connected == true ? person + "'s Chrome connected" : "Chrome not connected"
        var verbs: [(String, String)] = [("browser.go", "open a website in my own tab (text: its address)")]
        var tab = ["no page read in this chat · browser.go opens an address"]
        if let page = ChromePageMirror.page(tab: nil, dataRoot: dataRoot, session: scope) {
            let name = tabName(page.tab, dataRoot: dataRoot, scope: scope)
            tab = [pad(name, 8) + clip(tabTitle(page), 50) + " · read " + age(now.timeIntervalSince(page.at)) + " ago",
                   pad("", 8) + clip(page.url, 90)]
            verbs.insert((name, "open that page"), at: 0)
        }
        verbs.append(("research", "search the web or read a page without a tab"))
        return screen(["BROWSER", link], [section("MY TAB", tab)], verbs: verbs)
    }
}
