import Foundation
import StandingBots

/// A deliberately small input language; the existing cadence owner validates
/// and schedules its output. Unsupported prose never becomes a guessed cron.
public enum StandingBotSchedule {
    /// Cron day-of-week order: 0 is Sunday.
    public static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    public static func parse(_ input: String, timezone: String? = nil,
                      localTimezone: String = TimeZone.current.identifier) throws -> BotCadence {
        let words = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words == ["manual"] {
            guard timezone == nil else { throw invalid("Manual timing does not use a timezone") }
            return .manual
        }
        if words.count == 3, words[0] == "every", words[1].utf8.allSatisfy({ (48...57).contains($0) }),
           let count = Int(words[1]), count > 0 {
            let multiplier: Int
            switch words[2] {
            case "minute", "minutes": multiplier = 60
            case "hour", "hours": multiplier = 3600
            default: throw unsupported
            }
            guard timezone == nil else { throw invalid("Interval timing does not use a timezone") }
            let (seconds, overflow) = count.multipliedReportingOverflow(by: multiplier)
            guard !overflow else { throw invalid("Schedule interval is too large") }
            return .interval(seconds: TimeInterval(seconds))
        }
        let days: String, time: String
        if words.count == 3, ["daily", "weekdays"].contains(words[0]), words[1] == "at" {
            days = words[0] == "weekdays" ? "1-5" : "*"; time = words[2]
        } else if words.count == 5, words[0] == "weekly", words[1] == "on", words[3] == "at",
                  let day = weekdays.firstIndex(of: words[2]) {
            days = String(day); time = words[4]
        } else { throw unsupported }
        let clock = Array(time.utf8)
        guard clock.count == 5, clock[2] == 58,
              [clock[0], clock[1], clock[3], clock[4]].allSatisfy({ (48...57).contains($0) }) else {
            throw invalid("Use a 24-hour time with two digits each: daily at 09:00")
        }
        let hour = Int(clock[0] - 48) * 10 + Int(clock[1] - 48)
        let minute = Int(clock[3] - 48) * 10 + Int(clock[4] - 48)
        guard hour < 24, minute < 60 else { throw invalid("Schedule time must be between 00:00 and 23:59") }
        let zone = (timezone ?? localTimezone).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (TimeZone.knownTimeZoneIdentifiers.contains(zone) || ["UTC", "GMT"].contains(zone)),
              TimeZone(identifier: zone) != nil else {
            throw invalid("Unknown timezone; use an IANA name such as America/Denver")
        }
        return .cron(expression: "\(minute) \(hour) * * \(days)", timeZone: zone)
    }

    public static func describe(_ cadence: BotCadence) -> String {
        switch cadence {
        case .manual: return "manual"
        case .interval(let seconds):
            if seconds.truncatingRemainder(dividingBy: 3600) == 0 {
                return "every " + String(format: "%.0f", seconds / 3600) + (seconds == 3600 ? " hour" : " hours")
            }
            if seconds.truncatingRemainder(dividingBy: 60) == 0 {
                return "every " + String(format: "%.0f", seconds / 60) + (seconds == 60 ? " minute" : " minutes")
            }
            return "every \(seconds) seconds"
        case .cron(let expression, _):
            let parts = expression.split(separator: " ").map(String.init)
            if parts.count == 5, let minute = Int(parts[0]), let hour = Int(parts[1]),
               (0...59).contains(minute), (0...23).contains(hour),
               parts[2] == "*", parts[3] == "*" {
                let at = " at " + String(format: "%02d:%02d", hour, minute)
                if parts[4] == "*" { return "daily" + at }
                if parts[4] == "1-5" { return "weekdays" + at }
                if let day = Int(parts[4]), weekdays.indices.contains(day) { return "weekly on \(weekdays[day].capitalized)" + at }
            }
            return "cron: " + expression
        }
    }

    private static func invalid(_ message: String) -> StandingBotsError { .invalidValue(message) }
    private static var unsupported: StandingBotsError {
        invalid("Unsupported schedule. Use manual, every 30 minutes, every 2 hours, daily at 09:00, weekdays at 09:00, or weekly on monday at 09:00; use cadence for an explicit advanced cron.")
    }
}
