import Foundation
import PersistenceCore

/// "Parked": one rule for the Desk page's folded group and the agent's home
/// screen (2026-09-23). A piece of work with nothing executing for it that
/// nobody has touched (itself or any of its parts) for two weeks, or a plan
/// with none of its parts done that nobody moved for a week.
public enum DeskParking {
    public static let quietDays = 14
    public static let untouchedPlanDays = 7

    /// An execution still counts as live until it completed, failed or was cancelled.
    public static func executionIsLive(status: String) -> Bool {
        !["completed", "failed", "cancelled"].contains(status)
    }

    /// The newest touch on the item or any of its parts.
    public static func lastTouch(_ item: DeskItem, in state: DeskState) -> Date? {
        let handles = subtreeHandles(item.handle, in: state)
        return state.items.filter { handles.contains($0.handle) }.compactMap { date($0.updatedAt) }.max()
    }

    public static func subtreeHandles(_ handle: String, in state: DeskState) -> Set<String> {
        let children = Dictionary(grouping: state.items, by: { $0.parent ?? "" })
        var handles: Set<String> = [handle]
        var pending = [handle]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where handles.insert(child.handle).inserted {
                pending.append(child.handle)
            }
        }
        return handles
    }

    public static func isParked(_ item: DeskItem, in state: DeskState, plan: DeskSequencing.Plan,
                                live: Bool, now: Date = Date()) -> Bool {
        guard !live else { return false }
        let quiet = lastTouch(item, in: state).map { Int(now.timeIntervalSince($0) / 86_400) } ?? 0
        let untouchedPlan = plan.byHandle[item.handle].map { $0.totalCount > 0 && $0.doneCount == 0 } ?? false
        return quiet >= quietDays || (untouchedPlan && quiet >= untouchedPlanDays)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
