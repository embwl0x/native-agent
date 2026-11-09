import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskBoardLayout.swift` | `DeskBoardLayout`: active work and the pursuit lane; `DeskPage` reads a stored timestamp |

public enum DeskBoardLayout {
    public static func activeItems(_ items: [DeskItem]) -> [DeskItem] {
        items.filter { !$0.status.isTerminal }
    }

    public static func isPursuitLaneItem(_ item: DeskItem) -> Bool {
        item.origin == .agent && item.kind == .project
    }
}

extension DeskPage {
    public static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }
}
