import Foundation
// Blueprint: | `UserDisplayFormatters.swift` | `UserDisplayFormatters` timestamp parsing, cache and presentation shared by Mac and iPhone; compact duration presentation delegates to `CompactDurationFormatter` |

public enum UserDisplayFormatters {
    // MARK: - Timestamps

    /// Fractional-first Foundation formatter semantics for stored timestamps.
    /// Callers retain their own whitespace and empty-input rules. Keep these
    /// formatters local: they are not Sendable, and the cached display parser
    /// below uses distinct value-typed parsing strategies.
    public static func parseFoundationISOTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // Value-typed, immutable parse strategies are safe to share and avoid
    // constructing two Foundation formatter objects for every timestamp in a
    // list render. Fractional and plain wire shapes remain distinct because
    // both are produced by NativeAgent's durable stores.
    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO = Date.ISO8601FormatStyle()
    private static let timestampParseCache = TimestampParseCache(capacity: 2_048)

    /// Convert an ISO-8601 timestamp (with or without fractional seconds) to
    /// a relative phrase like "5 weeks ago" / "in 3 hours". On parse failure
    /// returns the raw input — better than dropping the field, but signals
    /// upstream to investigate. Power-user UI should also surface the raw
    /// value in a tooltip.
    public static func humanizeISOTimestamp(_ iso: String) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let date = parseISOTimestamp(trimmed)
        guard let date else { return trimmed }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    /// Parse an ISO-8601 timestamp to a Date (fractional seconds tolerated).
    public static func parseISOTimestamp(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return timestampParseCache.value(for: trimmed) {
            (try? fractionalISO.parse(trimmed)) ?? (try? plainISO.parse(trimmed))
        }
    }

    /// Timestamp used under a chat bubble. Kept here with the canonical wire
    /// parser so every bubble does not rebuild its own pair of ISO formatters.
    public static func chatTimestamp(_ iso: String, calendar: Calendar = .current) -> String {
        guard let date = parseISOTimestamp(iso) else { return iso }
        return date.formatted(
            date: calendar.isDateInToday(date) ? .omitted : .abbreviated,
            time: .shortened
        )
    }

    /// Relative phrase ("5m ago") with a caller-chosen units style. Use this
    /// when a call site wants a shorter form than `humanizeISOTimestamp`'s
    /// `.full`. On parse failure returns `fallback` — pass the raw input to
    /// echo it back, or a placeholder like "recently".
    public static func relativeISOTimestamp(
        _ iso: String,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle,
        fallback: String
    ) -> String {
        guard let date = parseISOTimestamp(iso) else { return fallback }
        // Clock skew can put a fresh stamp a hair in the future; "in 0s" is
        // nonsense to a person, so anything under a minute reads "now".
        let now = Date()
        if date > now || now.timeIntervalSince(date) < 60 { return "now" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = unitsStyle
        return rel.localizedString(for: date, relativeTo: now)
    }

    /// Time-of-day only, localized ("6:02 PM"). On parse failure returns the
    /// raw input (never drop the field). Uses the current locale/timezone.
    public static func shortTime(_ iso: String) -> String {
        guard let date = parseISOTimestamp(iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .none
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// Medium date + short time, localized ("May 26, 2026 at 6:02 PM"). On
    /// parse failure returns the raw input. Uses the current locale/timezone.
    public static func mediumDateTime(_ iso: String) -> String {
        guard let date = parseISOTimestamp(iso) else { return iso }
        let out = DateFormatter()
        out.locale = .current
        out.timeZone = .current
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// Compact duration phrase: "0.4s", "4.6s", "2m 14s", "1h 3m".
    public static func humanizeDuration(_ seconds: Double) -> String {
        CompactDurationFormatter.string(seconds)
    }
}

/// ISO timestamps are immutable wire values and recur throughout lists and
/// status chrome. Keep both successful and failed parses in a small FIFO so a
/// SwiftUI redraw does not rebuild the same Date over and over. The lock keeps
/// the shared formatter helper safe for background projections too.
private final class TimestampParseCache: @unchecked Sendable {
    private enum Entry {
        case date(Date)
        case invalid

        var date: Date? {
            if case .date(let date) = self { return date }
            return nil
        }
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(for key: String, load: () -> Date?) -> Date? {
        lock.lock()
        if let entry = entries[key] {
            lock.unlock()
            return entry.date
        }
        lock.unlock()

        let loaded = load()
        lock.lock()
        if let raced = entries[key] {
            lock.unlock()
            return raced.date
        }
        entries[key] = loaded.map(Entry.date) ?? .invalid
        order.append(key)
        if order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return loaded
    }
}
