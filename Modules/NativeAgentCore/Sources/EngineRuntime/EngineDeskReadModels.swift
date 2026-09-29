import Foundation
import Desk
import WorkshopExecution
public enum DeskLaneState<Row: Sendable>: Sendable {
    case unavailable(String)
    case rows([Row])

    public static var maxReasonChars: Int { 240 }

    /// Every failure notice on the Desk uses this cap. Keeping the truncation
    /// at the state boundary makes an unreadable store visible without letting
    /// an untrusted error string take over the board.
    public static func boundedReason(_ reason: String) -> String {
        String(reason.prefix(maxReasonChars))
    }

    public var items: [Row] {
        if case .rows(let rows) = self { return rows }
        return []
    }

    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// A throwing read: the error text IS the reason, bounded.
    public static func failed(_ error: any Error) -> DeskLaneState {
        .unavailable(boundedReason("\(error)"))
    }

    /// Silent-zero cross-check, for readers that CANNOT throw.
    /// `SwiftNativeWorkshopRunner.listAll()` swallows an unreadable execution
    /// root and returns `[]`, so the only honest signal available to this
    /// surface is the disk cross-check. The probe is TRI-state on purpose: a
    /// bare count conflated "the root isn't there" (honest zero) with "the root
    /// wouldn't open" (the corrupt-store case this whole check exists to
    /// expose), because both produced 0.
    public static func classify(rows: [Row], probe: DeskRecordProbe, noun: String) -> DeskLaneState {
        switch probe {
        case .empty:
            // No store yet — a genuinely empty lane, rows or not.
            return .rows(rows)
        case .unreadable(let detail):
            // The reader could not even enumerate the store. `rows` is [] by
            // construction in that case; saying "empty" here is the exact lie
            // this primitive exists to prevent.
            return .unavailable(
                boundedReason("Couldn't read the \(noun) store — \(detail)"))
        case .records(let recordsOnDisk):
            if rows.isEmpty && recordsOnDisk > 0 {
                return .unavailable("\(recordsOnDisk) \(noun) on disk, none could be read")
            }
            return .rows(rows)
        }
    }
}

public enum DeskRecordProbe: Sendable, Equatable {
    /// The root does not exist. Nothing has been written yet: an honest zero.
    case empty
    /// The root exists but could not be enumerated (permissions, corruption,
    /// not-a-directory). NOT zero — unknown.
    case unreadable(String)
    /// The root was enumerated: this many directories actually hold a record
    /// (or are malformed record dirs). Reservation/cancellation leftovers that
    /// legitimately carry no record are NOT counted — counting them turned a
    /// healthy empty bench into a bogus "unavailable" banner.
    case records(Int)
}
