import Transcripts
import Foundation
import PersistenceCore

// Blueprint: | `TurnClockQuietHours.swift` | `TurnQuietHoursWindow`: local wall-clock quiet-hours membership, wraparound and exact end deadline shared by native reply admission |

/// Declared quiet hours in local wall-clock time, shared by turn context and delivery admission.
/// `start > end` wraps midnight.
public struct TurnQuietHoursWindow: Sendable, Equatable {
    public static func holdsResidentWake(session: String?, dataRoot: URL, at date: Date = Date()) -> Bool {
        SessionConversation.kind(session, dataRoot: dataRoot)?.isOwnWork == true && read(dataRoot: dataRoot)?.contains(hour: Calendar.current.component(.hour, from: date)) == true
    }

    public let startHour: Int
    public let endHour: Int

    public init?(startHour: Int, endHour: Int) {
        guard (0...23).contains(startHour), (0...23).contains(endHour),
              startHour != endHour else { return nil }
        self.startHour = startHour
        self.endHour = endHour
    }

    /// Local-hour membership includes the start and excludes the end.
    public func contains(hour: Int) -> Bool {
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    /// Next local occurrence of the end hour, using the calendar's next valid time.
    public func end(after date: Date) -> Date? {
        var components = DateComponents()
        components.hour = endHour; components.minute = 0; components.second = 0
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// Reads `quiet_hours.{start,end}` from `user_prefs.json`; missing or invalid data means no window.
    public static func read(dataRoot: URL) -> TurnQuietHoursWindow? {
        let url = dataRoot.appendingPathComponent("user_prefs.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quiet = root["quiet_hours"] as? [String: Any] else {
            return nil
        }
        guard let start = intValue(quiet["start"]), let end = intValue(quiet["end"]) else {
            return nil
        }
        return TurnQuietHoursWindow(startHour: start, endHour: end)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(exactly: value.rounded(.towardZero)) }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
