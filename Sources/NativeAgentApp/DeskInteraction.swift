import Foundation
import SwiftUI
import PersistenceCore

// MARK: - DeskInteraction — the pure half of the desk's interaction tier
//
// Sweep R4 W5 (desk interaction tier). DeskView shipped read-only: 7 buttons,
// no selection, no keyboard, no search. The desk already beats Linear on DATA
// (dependency edges, auto-unblock, drift kinds, EWMA cadence); Linear's moat is
// keyboard-first MUTATION. This file is the part of that tier that is not a
// view: row ordering, selection movement, reveal keys, fuzzy match and the
// palette's command grammar.
//
// Everything here is pure and Sendable so it can be tested without SwiftUI —
// the same contract `DeskAttentionStrip` keeps in DeskView.swift.
//
// ONE DEFINITION RULE: the section partition and the family grouping live HERE
// and DeskView calls them, rather than each surface keeping its own copy. A
// selection order derived from a second copy of the partition would drift from
// what is actually on screen, and "arrow-down selects a row you can't see" is
// exactly the bug that makes a keyboard surface feel broken.

// MARK: - Selection chrome

extension View {
    /// The selected row's mark. Deliberately a THIN accent ring rather than a
    /// filled row: the desk's rows already carry a status pill, a kind line and
    /// sequencing pills, and a solid selection fill fought all three for the
    /// eye. Nothing renders when `isSelected` is false, so glance mode is
    /// byte-identical to the pre-W5 surface.
    @ViewBuilder
    func selectionHighlight(_ isSelected: Bool) -> some View {
        if isSelected {
            self.overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
            )
        } else {
            self
        }
    }
}

// MARK: - Section partition + family grouping (shared with DeskView's render)

enum DeskBoardLayout {

    // MARK: partition
    //
    // Disjoint + exhaustive over the active items: pursuits claim first;
    // watches and board both gate `!isPursuit` and board negates the exact
    // watch predicate, so pursuits ∪ watches ∪ board == activeItems.

    static func isWatchShaped(_ item: DeskItem) -> Bool {
        item.kind == .watch || item.status == .watch
    }

    static func activeItems(_ items: [DeskItem]) -> [DeskItem] {
        items.filter { !$0.status.isTerminal }
    }

    static func pursuits(_ active: [DeskItem]) -> [DeskItem] {
        active.filter(\.isPursuit)
    }

    static func watches(_ active: [DeskItem]) -> [DeskItem] {
        // Stalest first (desk-triage-makeover W2) — sorted HERE so rendering,
        // arrow-key selection order, and reveal keys all share one definition
        // (gpt-5.5 HIGH: sorting only the render path desynced ↓ from the
        // visible list). Unparseable timestamps sort last; ties break on the
        // raw timestamp string, then handle, so equal-date rows can't jitter
        // between loads (gpt-5.5 MED: `sorted` is not stable).
        active.filter { !$0.isPursuit && isWatchShaped($0) }
            .sorted { a, b in
                let da = UserDisplayFormatters.parseISOTimestamp(a.updatedAt) ?? .distantFuture
                let db = UserDisplayFormatters.parseISOTimestamp(b.updatedAt) ?? .distantFuture
                if da != db { return da < db }
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.handle < b.handle
            }
    }

    static func board(_ active: [DeskItem]) -> [DeskItem] {
        active.filter { !$0.isPursuit && !isWatchShaped($0) }
    }

    static func boardNonGh(_ board: [DeskItem]) -> [DeskItem] {
        board.filter { $0.kind != .gh }
    }

    static func ghByProject(_ board: [DeskItem]) -> [(project: String, items: [DeskItem])] {
        Dictionary(grouping: board.filter { $0.kind == .gh }, by: \.project)
            .map { (project: $0.key, items: $0.value) }
            .sorted { $0.project < $1.project }
    }

    // MARK: grouping

    /// One top-level family: the root row (when its parent lives in this
    /// section) plus its dot-nested children. A family whose root lives
    /// elsewhere (e.g. already done) collapses under a synthetic header that
    /// borrows the parent's title from the full item list.
    struct Group: Equatable, Sendable {
        let key: String
        let root: DeskItem?
        let parentTitle: String?
        let children: [DeskItem]
    }

    /// `allItems` is the FULL list (not the section slice) so an orphan family
    /// can name its absent parent.
    static func groups(_ list: [DeskItem], allItems: [DeskItem]) -> [Group] {
        var order: [String] = []
        var roots: [String: DeskItem] = [:]
        var children: [String: [DeskItem]] = [:]
        for item in list {
            let key = item.alias.split(separator: ".").first.map(String.init) ?? item.alias
            if roots[key] == nil && children[key] == nil { order.append(key) }
            if item.alias.contains(".") || roots[key] != nil {
                // Dot-nested items are children; so is any duplicate depth-0
                // alias (should never happen, but a dict overwrite would hide
                // an item entirely — nothing on this board may vanish).
                children[key, default: []].append(item)
            } else {
                roots[key] = item
            }
        }
        return order.map { key in
            Group(
                key: key,
                root: roots[key],
                parentTitle: roots[key] == nil
                    ? allItems.first(where: { $0.alias == key })?.title
                    : nil,
                children: children[key] ?? []
            )
        }
    }

    /// The toggle key DeskView stores in `expandedRoots` for one family.
    static func toggleKey(section: String, group: Group) -> String {
        "\(section):\(group.key)"
    }

    /// The handles a family renders RIGHT NOW, given the expansion set. Mirrors
    /// `DeskView.groupView` case for case:
    ///   • root present      → the root row, plus children only when expanded
    ///   • orphan family >1  → children only when expanded (header is chrome)
    ///   • lone orphan child → rendered flat, always visible
    static func visibleHandles(
        in group: Group, section: String, expandedRoots: Set<String>
    ) -> [String] {
        let expanded = expandedRoots.contains(toggleKey(section: section, group: group))
        if let root = group.root {
            return [root.handle] + (expanded ? group.children.map(\.handle) : [])
        }
        if group.children.count > 1 {
            return expanded ? group.children.map(\.handle) : []
        }
        return group.children.map(\.handle)
    }

    // MARK: selection order

    /// Every handle that can currently take the selection, in EXACTLY the order
    /// it renders — pursuits, then watches, then the board, then the GitHub
    /// project roll-ups.
    ///
    /// Deliberately excludes "Recently finished": close/defer/note on a
    /// terminal item is meaningless, and letting arrow-down walk into history
    /// would put the caret somewhere no action applies. Glance mode for that
    /// section is unchanged.
    ///
    /// Collapsed rows are excluded because they are NOT ON SCREEN. Selecting a
    /// row a `scrollTo` cannot reach is the failure this ordering exists to
    /// prevent; `revealKeys(for:)` is the counterpart for jumping TO a
    /// collapsed row on purpose (a blocker pill, a palette match).
    static func selectableHandles(items: [DeskItem], expandedRoots: Set<String>) -> [String] {
        let active = activeItems(items)
        var out: [String] = []
        out.append(contentsOf: pursuits(active).map(\.handle))
        for group in groups(watches(active), allItems: items) {
            out.append(contentsOf: visibleHandles(
                in: group, section: "watch", expandedRoots: expandedRoots))
        }
        let boardItems = board(active)
        for group in groups(boardNonGh(boardItems), allItems: items) {
            out.append(contentsOf: visibleHandles(
                in: group, section: "board", expandedRoots: expandedRoots))
        }
        for entry in ghByProject(boardItems) where expandedRoots.contains("gh:\(entry.project)") {
            out.append(contentsOf: entry.items.map(\.handle))
        }
        return out
    }

    /// Toggle keys that must be OPEN for `handle` to render. Empty when the row
    /// is already reachable (a pursuit, a family root, a lone orphan child).
    static func revealKeys(for handle: String, items: [DeskItem]) -> [String] {
        let active = activeItems(items)
        guard let item = active.first(where: { $0.handle == handle }) else { return [] }
        if item.isPursuit { return [] }
        if isWatchShaped(item) {
            return keys(containing: item,
                        in: groups(watches(active), allItems: items),
                        section: "watch")
        }
        if item.kind == .gh { return ["gh:\(item.project)"] }
        return keys(containing: item,
                    in: groups(boardNonGh(board(active)), allItems: items),
                    section: "board")
    }

    private static func keys(
        containing item: DeskItem, in groups: [Group], section: String
    ) -> [String] {
        for group in groups where group.children.contains(where: { $0.handle == item.handle }) {
            // A lone orphan child renders flat — nothing to open.
            if group.root == nil && group.children.count <= 1 { return [] }
            return [toggleKey(section: section, group: group)]
        }
        return []
    }
}

// MARK: - Selection movement

enum DeskSelection {

    /// Arrow-key movement over the visible order. CLAMPS rather than wraps:
    /// wrapping from the last row back to the first reads as a jump on a
    /// surface this long, and User holding ↓ should come to rest at the bottom.
    ///
    /// With no current selection, ↓ takes the first row and ↑ the last — the
    /// standard "enter the list from the edge you came from" behavior.
    static func move(from current: String?, by delta: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let idx = order.firstIndex(of: current) else {
            return delta >= 0 ? order.first : order.last
        }
        let next = idx + delta
        guard next >= 0, next < order.count else { return current }
        return order[next]
    }

    /// A selection whose row is gone (closed, collapsed, filtered out by a
    /// reload) must not linger: a stale caret makes `c` fire on something User
    /// can no longer see.
    static func reconcile(_ current: String?, order: [String]) -> String? {
        guard let current, order.contains(current) else { return nil }
        return current
    }
}

// MARK: - Palette rows + fuzzy match

/// One candidate in the ⌘K palette. Flattened off DeskItem so the matcher is
/// testable without building a whole desk state.
struct DeskPaletteRow: Identifiable, Equatable, Sendable {
    let handle: String
    let alias: String
    let title: String
    let project: String
    let status: String

    var id: String { handle }

    /// What the query matches against: the visible number, the title and the
    /// project — everything User can actually read on the row.
    var haystack: String { "\(alias) \(title) \(project)" }

    init(handle: String, alias: String, title: String, project: String, status: String) {
        self.handle = handle
        self.alias = alias
        self.title = title
        self.project = project
        self.status = status
    }

    init(item: DeskItem) {
        self.init(
            handle: item.handle,
            alias: item.alias,
            title: item.title,
            project: item.project,
            status: item.status.rawValue)
    }
}

enum DeskFuzzy {
    /// Match quality, LOWER is better. nil = no match at all.
    ///   0 exact · 1 prefix · 2 word-boundary prefix · 3 substring · 4 subsequence
    ///
    /// Ranked rather than boolean because a bare subsequence match ("dsk" ->
    /// "desk") is genuinely weaker than a prefix, and an unranked filter puts
    /// the accidental match above the obvious one.
    static func rank(query: String, candidate: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let c = candidate.lowercased()
        guard !q.isEmpty else { return 0 }
        if c == q { return 0 }
        if c.hasPrefix(q) { return 1 }
        if c.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
        if c.contains(q) { return 3 }
        return isSubsequence(q, of: c) ? 4 : nil
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let next = it.next() {
                if next == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Best matches first. Ties break on title length then handle, so the list
    /// is a TOTAL order — `sorted(by:)` is not stable in Swift, and a palette
    /// whose rows swap under an unchanged query is unusable.
    static func filter(_ rows: [DeskPaletteRow], query: String, limit: Int = 12) -> [DeskPaletteRow] {
        let scored: [(row: DeskPaletteRow, rank: Int)] = rows.compactMap { row in
            guard let r = rank(query: query, candidate: row.haystack) else { return nil }
            return (row, r)
        }
        let sorted = scored.sorted { l, r in
            if l.rank != r.rank { return l.rank < r.rank }
            if l.row.title.count != r.row.title.count { return l.row.title.count < r.row.title.count }
            return l.row.handle < r.row.handle
        }
        return Array(sorted.prefix(limit).map(\.row))
    }
}

// MARK: - Palette command grammar

/// What the palette field currently means. A LEADING verb turns the rest of the
/// line into the item query; anything else is a plain jump-to search.
///
/// An EMPTY query after a verb ("close" and nothing else) means "the row that
/// is already selected" — so ⌘K → `close` → Enter is a two-keystroke close of
/// the thing User is looking at, and never a close of a row he didn't name.
struct DeskPaletteQuery: Equatable, Sendable {
    enum Verb: String, CaseIterable, Sendable {
        case close
        case deferItem = "defer"
        case note

        var actionLabel: String {
            switch self {
            case .close: return "Close"
            case .deferItem: return "Defer"
            case .note: return "Add note"
            }
        }
    }

    var verb: Verb?
    var query: String

    var isPlainSearch: Bool { verb == nil }

    static func parse(_ raw: String) -> DeskPaletteQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DeskPaletteQuery(verb: nil, query: "") }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let head = String(parts[0]).lowercased()
        guard let verb = Verb(rawValue: head) else {
            return DeskPaletteQuery(verb: nil, query: trimmed)
        }
        let rest = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return DeskPaletteQuery(verb: verb, query: rest)
    }
}

// MARK: - Defer presets

/// The two parks User actually reaches for. `desk_defer` takes a `yyyy-MM-dd`
/// day or a full ISO stamp; the day form is what the projection renders back,
/// so that is what the menu writes.
enum DeskDeferPreset: String, CaseIterable, Identifiable, Sendable {
    case tomorrow
    case nextWeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    var days: Int {
        switch self {
        case .tomorrow: return 1
        case .nextWeek: return 7
        }
    }

    /// `now` and `calendar` are injected so the boundary cases (a park chosen at
    /// 23:59, a non-local time zone) are testable instead of clock-dependent.
    func day(from now: Date, calendar: Calendar = .current) -> String {
        let target = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: target)
    }
}

// MARK: - Ref affordances

/// What clicking a ref should DO. A ref that carries a URL opens; a bare ref
/// (a file path, a commit sha, a trace id) has nothing to open, so it copies —
/// silently doing nothing on click is the worst of the three options.
enum DeskRefAction: Equatable, Sendable {
    case open(url: String, label: String)
    case copy(text: String, label: String)

    var label: String {
        switch self {
        case .open(_, let label): return label
        case .copy(_, let label): return label
        }
    }

    var opensExternally: Bool {
        if case .open = self { return true }
        return false
    }
}

enum DeskRefAffordance {
    static func action(for ref: DeskRef) -> DeskRefAction {
        switch ref.kind {
        case let .ghPr(repo, number, title, _, _):
            return .open(
                url: "https://github.com/\(repo)/pull/\(number)",
                label: title?.isEmpty == false ? title! : "\(repo) #\(number)")
        case let .ghIssue(repo, number, title, _):
            return .open(
                url: "https://github.com/\(repo)/issues/\(number)",
                label: title?.isEmpty == false ? title! : "\(repo) #\(number)")
        case let .url(url, title):
            return .open(url: url, label: title?.isEmpty == false ? title! : url)
        case let .commit(sha, repo, label, _):
            if let repo, !repo.isEmpty {
                return .open(
                    url: "https://github.com/\(repo)/commit/\(sha)",
                    label: label?.isEmpty == false ? label! : String(sha.prefix(8)))
            }
            return .copy(text: sha, label: label?.isEmpty == false ? label! : String(sha.prefix(8)))
        case let .file(path, line, label):
            let text = line.map { "\(path):\($0)" } ?? path
            return .copy(text: text, label: label?.isEmpty == false ? label! : text)
        case let .agent(name, handoffId, sessionId):
            return .copy(text: handoffId ?? sessionId ?? name, label: name)
        case let .approval(id, _):
            return .copy(text: id, label: "approval \(id.prefix(8))")
        case let .trace(id, kind):
            return .copy(text: id, label: kind.map { "\($0) \(id.prefix(8))" } ?? "trace \(id.prefix(8))")
        case let .note(text):
            return .copy(text: text, label: text)
        }
    }
}
