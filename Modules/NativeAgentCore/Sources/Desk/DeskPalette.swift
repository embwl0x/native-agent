import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskPalette.swift` | `DeskPaletteRow`, `DeskFuzzy`, `DeskPaletteQuery`, `DeskPaletteCommandApplication`: ranked matching and revision-bound command admission |

public struct DeskPaletteRow: Identifiable, Equatable, Sendable {
    public let handle: String
    public let alias: String
    public let title: String
    public let project: String
    public let status: String

    public var id: String { handle }

    /// What the query matches against: the visible number, the title and the
    /// project — everything User can actually read on the row.
    public var haystack: String { "\(alias) \(title) \(project)" }

    public init(
        handle: String,
        alias: String,
        title: String,
        project: String,
        status: String
    ) {
        self.handle = handle
        self.alias = alias
        self.title = title
        self.project = project
        self.status = status
    }

    public init(item: DeskItem) {
        self.init(
            handle: item.handle,
            alias: item.alias,
            title: item.title,
            project: item.project,
            status: item.status.rawValue)
    }
}

public enum DeskFuzzy {
    /// Lower ranks win; nil means no match.
    /// 0 exact · 1 prefix · 2 word-boundary prefix · 3 substring · 4 subsequence
    public static func rank(query: String, candidate: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let c = candidate.lowercased()
        guard !q.isEmpty else { return 0 }
        if c == q { return 0 }
        if c.hasPrefix(q) { return 1 }
        if c.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
        if c.contains(q) { return 3 }
        return isSubsequence(q, of: c) ? 4 : nil
    }

    public static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
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
    public static func filter(_ rows: [DeskPaletteRow], query: String, limit: Int = 12) -> [DeskPaletteRow] {
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

public struct DeskPaletteQuery: Equatable, Sendable {
    public enum Verb: String, CaseIterable, Sendable {
        case close
        case deferItem = "defer"
        case note

        public var actionLabel: String {
            switch self {
            case .close: return "Close"
            case .deferItem: return "Defer"
            case .note: return "Add note"
            }
        }
    }

    public var verb: Verb?
    public var query: String

    public static func parse(_ raw: String) -> DeskPaletteQuery {
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

public enum DeskPaletteCommandApplication {
    public enum Resolution: Equatable, Sendable {
        case dispatch(DeskQuickAction)
        case beginDefer(handle: String)
        case beginNote(handle: String)
        case refused(String)
    }

    public static let actionInFlightMessage = "Another Desk action is still in progress."

    public static func resolve(
        verb: DeskPaletteQuery.Verb,
        handle rawHandle: String,
        activeItems: [DeskItem]
    ) -> Resolution {
        let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else {
            return .refused("Palette command was not applied: no Desk item was selected.")
        }
        guard let item = activeItems.first(where: { $0.handle == handle }) else {
            return .refused("Palette command was not applied: that item is no longer active.")
        }
        switch verb {
        case .close:
            let expectedUpdatedAt = item.updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expectedUpdatedAt.isEmpty else {
                return .refused(
                    "Palette command was not applied: the item's current version is unavailable."
                )
            }
            return .dispatch(.closeIfCurrent(
                handle: handle,
                outcome: DeskQuickAction.deskCloseOutcome,
                expectedUpdatedAt: expectedUpdatedAt
            ))
        case .deferItem:
            // Choosing Defer only opens its date choices. It has not changed
            // the store yet, so calling it successful here would be a lie.
            return .beginDefer(handle: handle)
        case .note:
            // Likewise, the note is not an effect until non-empty text is
            // submitted through DeskQuickAction.note.
            return .beginNote(handle: handle)
        }
    }
}
