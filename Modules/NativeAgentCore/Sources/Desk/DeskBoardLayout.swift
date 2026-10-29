import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskBoardLayout.swift` | `DeskBoardLayout`: active/pursuit/watch partitioning and watch order; `DeskPage` attention, freshness and timestamp interpretation |

public enum DeskBoardLayout {

    // Pursuits claim agent projects even with unreadable payloads; pursuits, watches
    // and board partition active items, keeping malformed pursuits visible.

    public static func isWatchShaped(_ item: DeskItem) -> Bool {
        item.kind == .watch || item.status == .watch
    }

    public static func activeItems(_ items: [DeskItem]) -> [DeskItem] {
        items.filter { !$0.status.isTerminal }
    }

    public static func isPursuitLaneItem(_ item: DeskItem) -> Bool {
        item.origin == .agent && item.kind == .project
    }

    public static func watches(_ active: [DeskItem]) -> [DeskItem] {
        // Shared watch order is stalest first, unparseable dates last, with raw timestamp then handle breaking ties.
        active.filter { !isPursuitLaneItem($0) && isWatchShaped($0) }
            .sorted { a, b in
                let da = DeskPage.parseTimestamp(a.updatedAt) ?? .distantFuture
                let db = DeskPage.parseTimestamp(b.updatedAt) ?? .distantFuture
                if da != db { return da < db }
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.handle < b.handle
            }
    }

}

extension DeskPage {
    public static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }
}

extension DeskPage {
    public static func needsEyes(_ item: DeskItem) -> Bool {
        item.status == .blocked || item.status == .flag || (item.waitingOn?.isEmpty == false)
    }
}

extension DeskPage {
    public static let staleThresholdDays = 7

    public static func freshness(_ item: DeskItem, now: Date) -> (date: Date?, days: Int, isStale: Bool) {
        guard let date = parseTimestamp(item.updatedAt) else { return (nil, 0, false) }
        let days = Int(max(0, now.timeIntervalSince(date)) / 86_400)
        let stale = days >= staleThresholdDays
            && item.status != .blocked && item.status != .flag && !item.status.isTerminal
        return (date, days, stale)
    }
}
