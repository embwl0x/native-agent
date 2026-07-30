// 2026-06-07 ui-taste-sweep: iOS-side mirror of the Mac
// UserDisplayFormatters helper. Same intent — never show raw ISO
// timestamps or /Users/<home>/... paths to the user. iOS is a separate
// SPM target so it can't import the Mac version; the helpers are tiny
// enough that duplicate is fine.

import Foundation

enum UserDisplayFormatters {
    /// Convert an ISO-8601 timestamp (with or without fractional seconds) to
    /// a relative phrase like "5 weeks ago" / "in 3 hours". On parse failure
    /// returns the raw input — better than dropping the field. Power-user UI
    /// should also surface the raw value via accessibility or long-press.
    static func humanizeISOTimestamp(_ iso: String) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
        guard let date else { return trimmed }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    /// Parse an ISO-8601 timestamp to a Date (fractional seconds tolerated).
    static func parseISOTimestamp(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }

    /// Compact duration phrase: "0.4s", "4.6s", "2m 14s", "1h 3m".
    static func humanizeDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        // Round once, then branch — 59.5 must roll into "1m", not print "60s".
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let s = total % 60
            return s == 0 ? "\(total / 60)m" : "\(total / 60)m \(s)s"
        }
        let m = (total % 3600) / 60
        return m == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(m)m"
    }
}
