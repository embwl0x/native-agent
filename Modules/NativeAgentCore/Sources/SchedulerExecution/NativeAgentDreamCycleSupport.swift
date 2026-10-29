import Foundation
import NativeAgentCore
import DreamREMCycle
import PersistenceCore
import TriggerScheduler
// Blueprint: | `NativeAgentDreamCycleSupport.swift` | `NativeAgentDreamCycleSchedule` enum; `runDateKey`, `dreamEntryDateKey` |

enum NativeAgentDreamCycleSchedule {
    static let dreamHour = DreamREMSchedule.dreamHour
    static let dreamMinute = DreamREMSchedule.dreamMinute
    // Forward to Core's single source of truth (DreamREMSchedule) — no literals here.
    static let remHour = DreamREMSchedule.remHour
    static let remMinute = DreamREMSchedule.remMinute

    static var dreamSchedule: [String: JSONValue] {
        [
            "type": .string("daily"),
            "at": .string(String(format: "%02d:%02d", dreamHour, dreamMinute)),
        ]
    }

    static var remSchedule: [String: JSONValue] {
        [
            "type": .string("weekly"),
            "weekdays": .array([.string("sun")]),
            "at": .string(String(format: "%02d:%02d", remHour, remMinute)),
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

    private static func timeZone() -> TimeZone { .current }
}
