import Foundation
// Blueprint: | `NativeTimestampFormat.swift` | Locked wire timestamp formats and Foundation parsers; explicit precision, UTC suffixes and calendar-day zones |

/// Existing wire formats stay distinct: changing precision or the UTC suffix
/// can change stored bytes even when the represented instant is the same.
/// One formatter per format for the process, only used under `lock`.
public enum NativeTimestampFormat {
    private static let lock = NSLock()
    // Only touched under `lock`.
    nonisolated(unsafe) private static let plainISO = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let basicZuluFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
    // Calendar days use the current time zone unless an item sets one.
    private static let calendarDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let sixDigitFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter
    }()

    /// UTC offset wire format with floored microseconds, omitted at whole seconds.
    public static func flooredOptionalMicrosecondUTCOffset(_ date: Date) -> String {
        microsecondUTCOffset(date, rounding: .down)
    }

    /// The one microsecond `+00:00` builder. `rounding` turns the instant into
    /// whole microseconds (`.down` truncates like Python's isoformat of a
    /// datetime; `.toNearestOrEven` is `fromtimestamp`'s rounding), carrying
    /// into the second; a zero fraction is omitted unless `alwaysFraction`.
    public static func microsecondUTCOffset(
        _ date: Date, rounding: FloatingPointRoundingRule, alwaysFraction: Bool = false
    ) -> String {
        // The whole-second component and the micros are derived from ONE
        // rounded value so they can never disagree at a boundary.
        let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded(rounding))
        // Floor pre-epoch seconds so the microsecond remainder stays in 0..<1e6.
        var wholeSeconds = totalMicros / 1_000_000
        var micros = Int(totalMicros % 1_000_000)
        if micros < 0 {
            micros += 1_000_000
            wholeSeconds -= 1
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let secondsDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: secondsDate
        )
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        let fraction = micros == 0 && !alwaysFraction ? "" : String(format: ".%06d", micros)
        return base + fraction + "+00:00"
    }

    public static func calendarDay(_ date: Date) -> String {
        calendarDay(date, timeZone: .autoupdatingCurrent)
    }

    public static func calendarDay(_ date: Date, timeZone: TimeZone) -> String {
        lock.withLock {
            calendarDayFormatter.timeZone = timeZone
            return calendarDayFormatter.string(from: date)
        }
    }

    public static func parseCalendarDay(_ text: String) -> Date? {
        lock.withLock {
            calendarDayFormatter.timeZone = .autoupdatingCurrent
            return calendarDayFormatter.date(from: text)
        }
    }

    /// Plain timestamps take priority for these stored-state readers.
    public static func parseISO8601(_ text: String) -> Date? {
        lock.withLock { plainISO.date(from: text) ?? fractionalISO.date(from: text) }
    }

    public static func parsePlainISO8601(_ text: String) -> Date? {
        lock.withLock { plainISO.date(from: text) }
    }
    public static func plainZulu(_ date: Date) -> String {
        lock.withLock { plainISO.string(from: date) }
    }

    public static func basicZulu(_ date: Date) -> String {
        lock.withLock { basicZuluFormatter.string(from: date) }
    }

    public static func parseBasicZulu(_ text: String) -> Date? {
        lock.withLock { basicZuluFormatter.date(from: text) }
    }
    public static func fractionalZulu(_ date: Date) -> String {
        lock.withLock { fractionalISO.string(from: date) }
    }

    /// Fractional timestamps take priority for these stored-state readers.
    public static func parseISO8601FractionalFirst(_ text: String) -> Date? {
        lock.withLock { fractionalISO.date(from: text) ?? plainISO.date(from: text) }
    }

    public static func fractionalUTCOffset(_ date: Date) -> String {
        fractionalZulu(date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    public static func sixDigitUTCOffset(_ date: Date) -> String {
        lock.withLock { sixDigitFormatter.string(from: date) }
    }
}
