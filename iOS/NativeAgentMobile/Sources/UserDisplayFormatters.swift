// 2026-06-07 ui-taste-sweep: iOS-side mirror of the Mac
// UserDisplayFormatters helper. Same intent — never show raw ISO
// timestamps or /Users/<home>/... paths to the user. iOS is a separate
// SPM target so it can't import the Mac version; the helpers are tiny
// enough that duplicate is fine.

import Foundation
import NativeAgentShared

@MainActor
enum UserDisplayFormatters {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private static var dates: [String: Date] = [:]
    /// Convert an ISO-8601 timestamp (with or without fractional seconds) to
    /// a relative phrase like "5 weeks ago" / "in 3 hours". On parse failure
    /// returns the raw input — better than dropping the field. Power-user UI
    /// should also surface the raw value via accessibility or long-press.
    static func humanizeISOTimestamp(_ iso: String) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard let date = parseISOTimestamp(trimmed) else { return trimmed }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Parse an ISO-8601 timestamp to a Date (fractional seconds tolerated).
    static func parseISOTimestamp(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let date = dates[trimmed] { return date }
        guard let date = fractional.date(from: trimmed) ?? whole.date(from: trimmed) else { return nil }
        if dates.count >= 500, let key = dates.keys.first { dates.removeValue(forKey: key) }
        dates[trimmed] = date
        return date
    }

    /// Compact duration phrase: "0.4s", "4.6s", "2m 14s", "1h 3m".
    nonisolated static func humanizeDuration(_ seconds: Double) -> String {
        CompactDurationFormatter.string(seconds)
    }
}
