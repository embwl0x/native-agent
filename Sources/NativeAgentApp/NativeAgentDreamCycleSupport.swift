import Foundation
import NativeAgentCore
import DreamREMCycle
import PersistenceCore
import TriggerScheduler

enum NativeAgentDreamCycleSchedule {
    static let timeZoneIdentifier = DreamREMSchedule.timeZoneIdentifier
    static let dreamHour = DreamREMSchedule.dreamHour
    static let dreamMinute = DreamREMSchedule.dreamMinute
    // Forward to Core's single source of truth (DreamREMSchedule) — no literals here.
    static let remHour = DreamREMSchedule.remHour
    static let remMinute = DreamREMSchedule.remMinute

    static var dreamSchedule: [String: JSONValue] {
        [
            "type": .string("daily"),
            "at": .string(String(format: "%02d:%02d", dreamHour, dreamMinute)),
            "timezone": .string(timeZoneIdentifier),
        ]
    }

    static var remSchedule: [String: JSONValue] {
        [
            "type": .string("weekly"),
            "weekdays": .array([.string("sun")]),
            "at": .string(String(format: "%02d:%02d", remHour, remMinute)),
            "timezone": .string(timeZoneIdentifier),
        ]
    }

    static func runDateKey(_ date: Date) -> String {
        DreamREMSchedule.todayKey(now: date, calendar: calendar())
    }

    static func dreamEntryDateKey(_ date: Date) -> String {
        DreamREMSchedule.dreamEntryDateKey(now: date, calendar: calendar())
    }

    static func clockHasReached(_ date: Date, hour: Int, minute: Int) -> Bool {
        let comps = calendar().dateComponents([.hour, .minute], from: date)
        let currentMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return currentMinutes >= hour * 60 + minute
    }

    static func isSunday(_ date: Date) -> Bool {
        calendar().component(.weekday, from: date) == 1
    }

    static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone()
        return cal
    }

    private static func timeZone() -> TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: -6 * 60 * 60)!
    }
}

enum NativeAgentDreamNotificationInboxPolicy {
    static let source = "dream_cycle"

    static func archiveOlderDreamRows(
        _ rows: [JSONValue],
        keeping keepItemId: String
    ) -> (rows: [JSONValue], archivedCount: Int) {
        var archivedCount = 0
        let rewritten = rows.map { row -> JSONValue in
            guard case .object(var obj) = row,
                  SchedulerJobRuntime.string(obj["source"]) == source,
                  SchedulerJobRuntime.string(obj["id"]) != keepItemId else {
                return row
            }
            let status = (SchedulerJobRuntime.string(obj["status"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard status != "archived", status != "dismissed" else {
                return row
            }
            obj["status"] = .string("archived")
            archivedCount += 1
            return .object(obj)
        }
        return (rewritten, archivedCount)
    }
}
