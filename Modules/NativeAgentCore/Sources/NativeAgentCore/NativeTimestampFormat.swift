import Foundation

/// Existing wire formats stay distinct: changing precision or the UTC suffix
/// can change stored bytes even when the represented instant is the same.
/// One formatter per format for the process, configured once and only used
/// under `lock`: building one per call (an ICU construction behind a global
/// ICU mutex) stalled every launch loop that parses a row's stamp.
public enum NativeTimestampFormat {
    private static let lock = NSLock()
    // Only touched under `lock`; never reconfigured after creation.
    nonisolated(unsafe) private static let plainISO = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let internetISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
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
        let interval = date.timeIntervalSince1970
        // Floor to integer microseconds (Python truncates, never rounds up). The
        // whole-second component and the micros are derived from ONE floored
        // value so they can never disagree at a boundary.
        let totalMicros = Int64((interval * 1_000_000).rounded(.down))
        // 2026-09-07: Swift's / and % truncate toward zero, so a pre-epoch
        // instant produced a negative fraction; floor so the remainder is 0..<1e6.
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
        if micros == 0 {
            return base + "+00:00"  // timespec='auto' omits the fraction
        }
        return base + String(format: ".%06d+00:00", micros)
    }

    public static func utcDay(_ date: Date) -> String {
        lock.withLock { utcDayFormatter.string(from: date) }
    }

    /// Preserve the loops' default-format-first, fractional-format-second order.
    public static func parseISO8601(_ text: String) -> Date? {
        lock.withLock { plainISO.date(from: text) ?? fractionalISO.date(from: text) }
    }

    public static func fractionalZulu(_ date: Date) -> String {
        lock.withLock { fractionalISO.string(from: date) }
    }

    /// Fractional timestamps take priority for these stored-state readers.
    public static func parseISO8601FractionalFirst(_ text: String) -> Date? {
        lock.withLock { fractionalISO.date(from: text) ?? internetISO.date(from: text) }
    }

    public static func fractionalUTCOffset(_ date: Date) -> String {
        let zulu = fractionalZulu(date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    public static func sixDigitUTCOffset(_ date: Date) -> String {
        lock.withLock { sixDigitFormatter.string(from: date) }
    }
}
