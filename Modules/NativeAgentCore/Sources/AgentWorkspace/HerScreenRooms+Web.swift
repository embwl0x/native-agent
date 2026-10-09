import Foundation
import NativeAgentCore
import PersistenceCore
import ChromeControl

/// The last Chrome page each tab showed, as the app's browser tools last
/// read it (2026-09-24, her-screen web rooms). Home and the tab room read it
/// without a tool call; the app resolves a row's label ("Email", "Sign in")
/// to its node from it. In memory only, for the life of the app.
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

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: [Int64: Page]] = [:]
    nonisolated(unsafe) private static var current: [String: Int64] = [:]

    /// Keep only pages this chat has read. This cache is evidence, not tab ownership.
    public static func publish(_ page: Page, session: String?) {
        let who = session ?? ""
        lock.withLock {
            pages[who, default: [:]][page.tab] = page
            current[who] = page.tab
            if let saved = pages[who], saved.count > 16,
               let oldest = saved.values.min(by: { $0.at < $1.at }) {
                pages[who]?[oldest.tab] = nil
            }
            if pages.count > 64, let oldest = pages.keys.filter({ $0 != who }).min(by: {
                (pages[$0]?.values.map(\.at).max() ?? .distantPast) < (pages[$1]?.values.map(\.at).max() ?? .distantPast)
            }) { pages[oldest] = nil; current[oldest] = nil }
        }
    }

    /// An explicit tab, else this chat's last tab; only evidence it read itself.
    public static func page(tab: Int64?, session: String?) -> Page? {
        let who = session ?? ""
        return lock.withLock {
            guard let id = tab ?? current[who] else { return nil }
            return pages[who]?[id]
        }
    }

    public static func forget(tab: Int64) {
        lock.withLock {
            for who in Array(pages.keys) { pages[who]?[tab] = nil }
            current = current.filter { $0.value != tab }
        }
    }

    /// Only an explicit close removes a tab's saved page from home.
    nonisolated(unsafe) private static var closed: Set<Int64> = []
    public static func tabClosed(_ id: Int64) {
        forget(tab: id)
        lock.withLock { if closed.count > 256 { closed = [] }; closed.insert(id) }
    }
    public static func isClosed(_ id: Int64) -> Bool { lock.withLock { closed.contains(id) } }
    /// A tab seen live again (Chrome can reuse an id after a restart).
    public static func tabLive(_ id: Int64) { lock.withLock { _ = closed.remove(id) } }

    public enum Match: Equatable {
        case row(Row), none, ambiguous([Row])
        public var row: Row? { if case .row(let row) = self { row } else { nil } }
    }

    /// A row by its visible number ("12") or its label, among rows that can do
    /// one of `wants`. Never a guess between two: a label matches exactly
    /// (case, spaces and a trailing colon aside), else by prefix or substring
    /// only when one row has it, else a text row just before its unnamed
    /// control. A number from an older page (`seen`) is found again by role,
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
        let captions = page.rows.indices.filter { norm(page.rows[$0].label) == wanted }
        let controls = captions.compactMap { i in page.rows[(i + 1)...].prefix(3).first { !wants.isDisjoint(with: $0.acts) } }
        return one(controls) ?? .none
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

/// Her-screen rooms for the web (2026-09-24): her Chrome tab as `tab.N`, and
/// the browser place. Both are read from the mirror above: no tool call on
/// home; opening `tab.N` reads the page fresh first (the workspace's owner read).
extension HerScreen {
    /// `tab.N` for a tab; numbers only go up, a new tab gets a new one.
    /// 09-24: numbered per chat from 1 (a chat's first tab is tab.1).
    static func tabName(_ tab: Int64, dataRoot: URL, scope: String) -> String {
        "tab.\(withNames(dataRoot) { $0.number("tab:" + scope, id: String(tab)) { [String(tab)] } })"
    }

    /// A page's title, or its address when the page has none yet.
    static func tabTitle(_ page: ChromePageMirror.Page) -> String {
        if !page.title.isEmpty { return page.title }
        let bare = page.url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        return bare.isEmpty ? "untitled" : bare
    }

    /// Home's PLACES cell for this chat's tab, or nil when it has none.
    static func webTabCell(dataRoot: URL, scope: String, now: Date) -> String? {
        guard let page = ChromePageMirror.page(tab: nil, session: scope) else { return nil }
        return tabName(page.tab, dataRoot: dataRoot, scope: scope) + " \"" + clip(tabTitle(page), 28) + "\" "
            + age(now.timeIntervalSince(page.at))
    }

    /// A web name to its action: `tab.N` (read it fresh), `tab.N.go|click|fill|more`, `browser.go`.
    /// `scope` is the chat the rooms were drawn for (tabName's), never a task-local:
    /// the Mac chat's workspace runs outside runInner, where none is bound (walk 6).
    static func webTarget(_ name: String, verb: String?, dataRoot: URL, scope: String) -> Target? {
        if name == "browser", verb == "go" {
            return .action(.perform(tool: "browser.chrome_navigate", input: [:], title: "Open a website", textField: "url", isEffect: true))
        }
        guard name.hasPrefix("tab."), let n = Int(name.dropFirst(4)),
              let saved = withNames(dataRoot, { $0.id("tab:" + scope, n) }),
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
    }

    /// A Chrome tab as a room: its title and address, the first rows of the
    /// page as last read, and the one-call verbs by its name.
    static func tabRoom(_ input: [String: JSONValue], dataRoot: URL, scope: String, issue: String?, now: Date) -> String {
        let tab: Int64? = if case .int(let value)? = input["tab_id"] { value } else { nil }
        guard let page = ChromePageMirror.page(tab: tab, session: scope) else {
            return screen(["TAB", "no page read"], [["No page has been read in this tab yet."], issue.map { section("READ", [clip($0, 100)]) } ?? []],
                verbs: [("browser.go", "open a website (text: its address)")], back: "Back: home · browser.")
        }
        let name = tabName(page.tab, dataRoot: dataRoot, scope: scope)
        if !previewing { AgentWorkspacePorts.current.tools.markConsumed(peer: "web content") }
        let rows = page.text.split(separator: "\n").map(String.init)
            .filter { $0.range(of: #"^\s*\d+  "#, options: .regularExpression) != nil }
        let cap = 24
        var shown = rows.prefix(cap).map { clip($0, 110) }
        if rows.count > cap { shown.append("+\(rows.count - cap) more rows · app chrome.snapshot reads them all") }
        if shown.isEmpty { shown = ["nothing readable in view"] }
        let lines = page.text.split(separator: "\n").map(String.init)
        let status = lines.dropFirst().first.map { $0.replacingOccurrences(of: #"^snapshot_id \S+ ?·? ?"#, with: "", options: .regularExpression) } ?? ""
        return screen([name, "Chrome", tabTitle(page), "read " + age(now.timeIntervalSince(page.at)) + " ago"],
            [section("AT", [clip(page.url, 100)] + (status.isEmpty ? [] : [clip(status, 100)])), section("PAGE", shown),
             issue.map { section("READ", [clip($0, 100)]) } ?? []],
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
        var tab = ["no page open in this chat · browser.go opens one"]
        if let page = ChromePageMirror.page(tab: nil, session: scope) {
            let name = tabName(page.tab, dataRoot: dataRoot, scope: scope)
            tab = [pad(name, 8) + clip(tabTitle(page), 50) + " · read " + age(now.timeIntervalSince(page.at)) + " ago",
                   pad("", 8) + clip(page.url, 90)]
            verbs.insert((name, "open that page"), at: 0)
        }
        verbs.append(("research", "search the web or read a page without a tab"))
        return screen(["BROWSER", link], [section("MY TAB", tab)], verbs: verbs)
    }
}
