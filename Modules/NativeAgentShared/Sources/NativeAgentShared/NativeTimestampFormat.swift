import Foundation
// Blueprint: | `NativeTimestampFormat.swift` | Per-thread wire timestamp formats and Foundation parsers; explicit precision, UTC suffixes and calendar-day zones |

/// Existing wire formats stay distinct: changing precision or the UTC suffix can change stored bytes even when the represented instant is the same.
public enum NativeTimestampFormat {
    /// One set of formatters per thread. Every part of the app parses and writes timestamps (records, transcripts, traces, memory rows), and a
    /// formatter is not safe to share without a lock they would all queue on. A formatter here is only ever used by the thread that holds it,
    /// inside one synchronous call, so nothing is shared and nothing waits.
    private final class Formats {
        lazy var plainISO = ISO8601DateFormatter()
        lazy var fractionalISO: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        lazy var basicZulu: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            return formatter
        }()
        // Calendar days use the current time zone unless an item sets one.
        lazy var calendarDay: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()
        lazy var sixDigit: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
            return formatter
        }()
    }

    private static let formatsKey = "NativeTimestampFormat.formats"

    /// The calling thread's own formatters, made on its first use.
    private static var formats: Formats {
        let storage = Thread.current.threadDictionary
        if let held = storage[formatsKey] as? Formats { return held }
        let made = Formats()
        storage[formatsKey] = made
        return made
    }

    /// UTC offset wire format with floored microseconds, omitted at whole seconds.
    public static func flooredOptionalMicrosecondUTCOffset(_ date: Date) -> String {
        microsecondUTCOffset(date, rounding: .down)
    }

    /// The one microsecond `+00:00` builder. `rounding` turns the instant into whole microseconds (`.down` truncates like Python's isoformat of a datetime;
    /// `.toNearestOrEven` is `fromtimestamp`'s rounding), carrying into the second; a zero fraction is omitted unless `alwaysFraction`.
    public static func microsecondUTCOffset(
        _ date: Date, rounding: FloatingPointRoundingRule, alwaysFraction: Bool = false
    ) -> String {
        // The whole-second component and the micros are derived from ONE rounded value so they can never disagree at a boundary.
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
        let formatter = formats.calendarDay
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    public static func parseCalendarDay(_ text: String) -> Date? {
        let formatter = formats.calendarDay
        formatter.timeZone = .autoupdatingCurrent
        return formatter.date(from: text)
    }

    /// Plain timestamps take priority for these stored-state readers.
    public static func parseISO8601(_ text: String) -> Date? {
        zulu(text, fractional: false) ?? zulu(text, fractional: true)
            ?? formats.plainISO.date(from: text) ?? formats.fractionalISO.date(from: text)
    }

    public static func parsePlainISO8601(_ text: String) -> Date? {
        zulu(text, fractional: false) ?? formats.plainISO.date(from: text)
    }

    /// The two shapes this app itself writes, read without Foundation's date parser: exactly `YYYY-MM-DDTHH:MM:SSZ`, or with `.fff` before
    /// the `Z`, years 1970 to 2199, every field in range. Anything else returns nil and the caller asks the formatter, so nothing reads
    /// differently. The formatter parses through ICU under a lock of its own, about a thousand times slower, and a turn reads a few thousand
    /// stored timestamps before its first word. The result is bit-identical to the formatter's for every accepted shape.
    private static func zulu(_ text: String, fractional: Bool) -> Date? {
        var text = text
        return text.withUTF8 { bytes -> Date? in
            func number(_ at: Int, _ count: Int) -> Int? {
                var value = 0
                for index in at..<(at + count) {
                    let digit = Int(bytes[index]) &- 48
                    guard digit >= 0, digit <= 9 else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            // '-' 45, 'T' 84, ':' 58, '.' 46, 'Z' 90.
            guard bytes.count == (fractional ? 24 : 20), bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
                  bytes[bytes.count - 1] == 90,
                  let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
            var milliseconds = 0
            if fractional {
                guard bytes[19] == 46, let fraction = number(20, 3) else { return nil }
                milliseconds = fraction
            }
            guard year >= 1970, year <= 2199, month >= 1, month <= 12, hour <= 23, minute <= 59, second <= 59 else { return nil }
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            guard day >= 1, day <= daysInMonth else { return nil }
            // Days since 1970-01-01 in the proleptic Gregorian calendar (the civil-days algorithm).
            let shifted = month <= 2 ? year - 1 : year
            let era = shifted / 400, yearOfEra = shifted - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let total = (days * 86_400 + hour * 3_600 + minute * 60 + second) * 1_000 + milliseconds
            // The same arithmetic Foundation ends with (milliseconds over a thousand, less the reference date), so the bits are the same.
            return Date(timeIntervalSinceReferenceDate: Double(total) / 1_000.0 - 978_307_200.0)
        }
    }
    public static func plainZulu(_ date: Date) -> String {
        formats.plainISO.string(from: date)
    }

    public static func basicZulu(_ date: Date) -> String {
        formats.basicZulu.string(from: date)
    }

    public static func parseBasicZulu(_ text: String) -> Date? {
        formats.basicZulu.date(from: text)
    }
    public static func fractionalZulu(_ date: Date) -> String {
        formats.fractionalISO.string(from: date)
    }

    /// Fractional timestamps take priority for these stored-state readers.
    public static func parseISO8601FractionalFirst(_ text: String) -> Date? {
        zulu(text, fractional: true) ?? zulu(text, fractional: false)
            ?? formats.fractionalISO.date(from: text) ?? formats.plainISO.date(from: text)
    }

    public static func fractionalUTCOffset(_ date: Date) -> String {
        fractionalZulu(date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    public static func sixDigitUTCOffset(_ date: Date) -> String {
        formats.sixDigit.string(from: date)
    }
}
