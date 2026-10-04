import Foundation

public enum NotificationInboxClock {
    /// UTC offset timestamp, with six fractional digits unless microseconds are zero.
    public static func nowISO(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let micros = (c.nanosecond ?? 0) / 1000
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        // Python isoformat() omits the fractional part entirely when microsecond
        // == 0; otherwise it prints exactly 6 digits.
        let frac = micros == 0 ? "" : String(format: ".%06d", micros)
        return base + frac + "+00:00"
    }
}
