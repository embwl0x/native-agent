import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskParking.swift` | `DeskDeferPreset`; deferred-work interpretation |

/// "Parked": one rule for the Desk page's folded group and the agent's home
/// screen. A piece of work with nothing executing for it that
/// nobody has touched (itself or any of its parts) for two weeks, or a plan
/// with none of its parts done that nobody moved for a week.
public enum DeskParking {
    public static let quietDays = 14
    public static let untouchedPlanDays = 7

    /// The newest touch on the item or any of its parts.
    public static func lastTouch(_ item: DeskItem, in children: [String?: [DeskItem]]) -> Date? {
        ([item] + SwiftNativeDeskStore.descendants(of: item.handle, in: children))
            .compactMap { NativeTimestampFormat.parseISO8601FractionalFirst($0.updatedAt) }.max()
    }

    public static func subtreeHandles(_ handle: String, in children: [String?: [DeskItem]]) -> Set<String> {
        Set(SwiftNativeDeskStore.descendants(of: handle, in: children).map(\.handle)).union([handle])
    }

    public static func parking(_ item: DeskItem, in state: DeskState, plan: DeskSequencing.Plan,
                               live: Bool, now: Date = Date()) -> (parked: Bool, boundary: Date?) {
        guard !live, let touched = lastTouch(item, in: plan.children) else { return (false, nil) }
        let quiet = Int(now.timeIntervalSince(touched) / 86_400)
        let untouchedPlan = plan.byHandle[item.handle].map { $0.totalCount > 0 && $0.doneCount == 0 } ?? false
        let days = untouchedPlan ? untouchedPlanDays : quietDays
        return (quiet >= days, touched.addingTimeInterval(Double(days) * 86_400))
    }

}

public enum DeskDeferPreset: String, CaseIterable, Identifiable, Sendable {
    case tomorrow
    case nextWeek

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    public var days: Int {
        switch self {
        case .tomorrow: return 1
        case .nextWeek: return 7
        }
    }

    /// `now` and `calendar` are injected so the boundary cases (a park chosen at
    /// 23:59, a non-local time zone) are testable instead of clock-dependent.
    public func day(from now: Date, calendar: Calendar = .current) -> String {
        let target = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return NativeTimestampFormat.calendarDay(target, timeZone: calendar.timeZone)
    }
}
