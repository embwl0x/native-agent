import Foundation
import Synchronization
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |

// UTC instants and local calendar days serve different ordering and day-bucket needs.

public enum DeskClock {
    // DateFormatter resolves only milliseconds; monotonic issuance prevents same-millisecond CAS collisions.
    private static let lastIssuedMs = Mutex<Int64>(0)

    /// Advance by a millisecond when the clock stalls or steps back so issued stamps stay ordered.
    public static func nowISO() -> String {
        isoFromMs(issueMs(floorMs: 0))
    }

    /// Floor on both issued and committed stamps under the flock so concurrent processes preserve commit order.
    /// A corrupt future stamp trades wall-clock accuracy for that ordering guarantee.
    public static func commitStamp(notBefore lastCommitted: String?) -> String {
        var floorMs: Int64 = 0
        if let lastCommitted, let d = parseISO(lastCommitted) {
            floorMs = Int64((d.timeIntervalSince1970 * 1000.0).rounded())
        }
        return isoFromMs(issueMs(floorMs: floorMs))
    }

    private static func issueMs(floorMs: Int64) -> Int64 {
        let wallMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded(.down))
        return lastIssuedMs.withLock {
            $0 = max(wallMs, max($0, floorMs) + 1)
            return $0
        }
    }

    private static func isoFromMs(_ ms: Int64) -> String {
        // A 0.1ms bias absorbs Double error while remaining below DateFormatter’s rounding midpoint.
        nowISO(Date(timeIntervalSince1970: (Double(ms) + 0.1) / 1000.0))
    }

    public static func nowISO(_ date: Date) -> String {
        NativeTimestampFormat.sixDigitUTCOffset(date)
    }
    public static func parseISO(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(s)
    }

    public static func parseDay(_ s: String) -> Date? {
        NativeTimestampFormat.parseCalendarDay(s)
    }

    /// Unparseable dates cannot stand as dossier evidence.
    public static func isParseableDate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if NativeTimestampFormat.parseCalendarDay(t) != nil { return true }
        return parseISO(t) != nil
    }

    /// Normalize local days so timestamp variants cannot inflate distinct-day evidence.
    public static func normalizedDay(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if NativeTimestampFormat.parseCalendarDay(t) != nil { return t }
        if let d = parseISO(t) { return dayStamp(d) }
        return nil
    }

    /// Stable normalized reservation IDs make replay idempotent and caps count distinct reservations.
    public static func reservationId(handle: String, day: String, slot: String) -> String {
        let bare = handle.hasPrefix("desk_") ? String(handle.dropFirst("desk_".count)) : handle
        func clean(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        }
        return "wres_\(clean(bare))_\(clean(day))_\(clean(slot))"
    }

    public static func workAttemptId(handle: String, lane: DeskWorkAttempt.Lane, day: String, slot: String) -> String {
        lane == .pursuit ? reservationId(handle: handle, day: day, slot: slot)
            : "wattempt_\(lane.rawValue)_\(reservationId(handle: handle, day: day, slot: slot).dropFirst(5))"
    }

    public static func dayStamp(_ date: Date) -> String {
        NativeTimestampFormat.calendarDay(date)
    }

    public static func newHandle() -> String { "desk_" + UUID().uuidString.lowercased() }
    public static func newRefId() -> String { "deskref_" + UUID().uuidString.lowercased() }
    public static func newOpId() -> String { "deskop_" + UUID().uuidString.lowercased() }
}
