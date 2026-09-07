import Foundation

// Shared UTC formatting for Desk and TaskLedger; monotonic issuance belongs to Desk.

public enum DeskClock {
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private let timestampWriter: DateFormatter
        private let fractionalReader: ISO8601DateFormatter
        private let plainReader: ISO8601DateFormatter
        private let dayFormatter: DateFormatter

        init() {
            let writer = DateFormatter()
            writer.locale = Locale(identifier: "en_US_POSIX")
            writer.timeZone = TimeZone(identifier: "UTC")
            writer.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
            timestampWriter = writer

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fractionalReader = fractional

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            plainReader = plain

            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(identifier: "UTC")
            day.dateFormat = "yyyy-MM-dd"
            dayFormatter = day
        }

        func timestamp(from date: Date) -> String {
            lock.lock(); defer { lock.unlock() }
            return timestampWriter.string(from: date)
        }

        func date(from timestamp: String) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return fractionalReader.date(from: timestamp) ?? plainReader.date(from: timestamp)
        }

        func day(from date: Date) -> String {
            lock.lock(); defer { lock.unlock() }
            return dayFormatter.string(from: date)
        }

        func parsesDay(_ value: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return dayFormatter.date(from: value) != nil
        }
    }

    private static let formatters = FormatterCache()
    // DateFormatter's SSSSSS only resolves to the millisecond (the trailing
    // three digits are always zeros), so two "now" stamps in the same
    // millisecond come out byte-identical — which lets the updatedAt CAS in
    // markNotifiedIfUnchanged false-succeed and swallow a same-millisecond
    // change. Guard: quantize to integer milliseconds and never re-issue a
    // value <= the last one, so in-process nowISO() is strictly monotonic.
    // nonisolated(unsafe): every access is guarded by monotonicLock.
    private static let monotonicLock = NSLock()
    nonisolated(unsafe) private static var lastIssuedMs: Int64 = 0

    /// Strictly monotonic "now" stamp: if the wall clock hasn't advanced past
    /// the last issued millisecond (or stepped backwards), bump by 1ms.
    public static func nowISO() -> String {
        isoFromMs(issueMs(floorMs: 0))
    }

    /// Commit-time stamp for an op appended under the ops flock: strictly
    /// greater than BOTH every stamp this process has issued AND the newest
    /// ts already committed to the feed. In-process monotonicity alone is not
    /// enough at the commit point — a stamp minted at op construction can
    /// stall before the lock and commit BEHIND a later-issued notify stamp
    /// (evaluator then swallows the change), and a second writer process
    /// (e.g. chat-drive) shares the flock but not this process's monotonic
    /// state. Flooring on the committed feed makes commit order == timestamp
    /// order in both cases (Lamport-style: a corrupt far-future ts on disk
    /// would drag stamps forward, trading wall-clock accuracy for ordering).
    public static func commitStamp(notBefore lastCommitted: String?) -> String {
        var floorMs: Int64 = 0
        if let lastCommitted, let d = parseISO(lastCommitted) {
            floorMs = Int64((d.timeIntervalSince1970 * 1000.0).rounded())
        }
        return isoFromMs(issueMs(floorMs: floorMs))
    }

    private static func issueMs(floorMs: Int64) -> Int64 {
        let wallMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded(.down))
        monotonicLock.lock()
        let ms = max(wallMs, max(lastIssuedMs, floorMs) + 1)
        lastIssuedMs = ms
        monotonicLock.unlock()
        return ms
    }

    private static func isoFromMs(_ ms: Int64) -> String {
        // +0.1ms keeps Double representation error from ever landing the
        // reconstructed Date in the previous millisecond; DateFormatter
        // rounds at the half-millisecond so the output is exactly `ms`.
        nowISO(Date(timeIntervalSince1970: (Double(ms) + 0.1) / 1000.0))
    }

    /// Pure formatter for an explicit Date (tests, replay) — no monotonic
    /// bump. ISO-8601 UTC, microsecond precision — byte-identical format to
    /// TaskLedgerClock.nowISO so Desk timestamps sort lexicographically and
    /// align with the other Swift-native event feeds.
    public static func nowISO(_ date: Date) -> String {
        formatters.timestamp(from: date)
    }

    /// Parse an ISO-8601 timestamp produced by `nowISO`. Tolerant of both the
    /// microsecond `+00:00` form and a bare-seconds fallback.
    public static func parseISO(_ s: String) -> Date? {
        formatters.date(from: s)
    }

    /// True when `s` parses as a calendar date — either a bare `yyyy-MM-dd` day
    /// stamp (the felt-salience / reservation day form) or a full ISO timestamp.
    /// Used by dossier structural validation: an unparseable date can't stand as
    /// evidence.
    public static func isParseableDate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if formatters.parsesDay(t) { return true }
        return parseISO(t) != nil
    }

    /// Collapse a parseable date/timestamp string to its `yyyy-MM-dd` UTC day, so
    /// distinct-DAY counting can't be fooled by two timestamps on one day or a
    /// bare day vs its midnight ISO form. nil for an unparseable string.
    public static func normalizedDay(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if formatters.parsesDay(t) { return t }   // already a bare UTC day
        if let d = parseISO(t) { return dayStamp(d) }
        return nil
    }

    /// Deterministic reservation id for a (handle, day, slot) triple — the same
    /// triple always yields the same id, so a replayed reserve op is idempotent
    /// and the caps count distinct reservations without a mutable counter. Slot
    /// is lowercased + non-alphanumerics collapsed to keep the id wire-clean.
    public static func reservationId(handle: String, day: String, slot: String) -> String {
        let bare = handle.hasPrefix("desk_") ? String(handle.dropFirst("desk_".count)) : handle
        func clean(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        }
        return "wres_\(clean(bare))_\(clean(day))_\(clean(slot))"
    }

    public static func workAttemptId(handle: String, lane: DeskWorkAttempt.Lane, day: String, slot: String) -> String {
        "wattempt_\(lane.rawValue)_\(reservationId(handle: handle, day: day, slot: slot).dropFirst(5))"
    }

    /// The `yyyy-MM-dd` UTC day for a timestamp — the reservation/day bucket.
    public static func dayStamp(_ date: Date) -> String {
        formatters.day(from: date)
    }

    /// New stable item handle.
    public static func newHandle() -> String { "desk_" + UUID().uuidString.lowercased() }
    /// New stable ref id (for in-place ref updates).
    public static func newRefId() -> String { "deskref_" + UUID().uuidString.lowercased() }
    /// New op id.
    public static func newOpId() -> String { "deskop_" + UUID().uuidString.lowercased() }
}
