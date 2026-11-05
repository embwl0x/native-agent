import Foundation
import NativeAgentShared
import Desk
import PersistenceCore
import TriggerScheduler

// Blueprint: | `IntentionClock.swift` | `IntentionClock`: shared scheduler occurrence identity |
// Apply rhythm grace and until bounds; intervals start from filing or clockStart, and imported anchors retain full civil precision.

/// Read occurrences from rhythm and anchors without another state ledger.
public enum IntentionClock {
    /// A two-hour grace keeps missed sleeping-Mac occurrences due without accumulating a backlog.
    public static let grace: TimeInterval = 2 * 3_600

    public static func occurrence(_ step: DeskStep, at now: Date) -> Date? {
        guard let rhythm = step.rhythm, let filed = filed(step) else { return nil }
        let first = firstOccurrence(step, rhythm: rhythm)
        guard step.clockStart == nil || first != nil else { return nil }
        let ends = MyQueue.Until(step.until).endsAt
        var latest: Date?
        if let interval = SchedulerJobNormalizer.rhythmInterval(rhythm) {
            let anchor = first ?? filed.addingTimeInterval(interval)
            let count = (now.timeIntervalSince(anchor) / interval).rounded(.down)
            if count >= 0 { latest = anchor.addingTimeInterval(count * interval) }
        } else {
            if let first, first <= now { latest = first }
            var cursor = SchedulerJobNormalizer.nextOccurrence(rhythm, after: max(first ?? filed, now.addingTimeInterval(-grace)))
            for _ in 0..<512 {
                guard let at = cursor, at <= now else { break }
                latest = at
                cursor = SchedulerJobNormalizer.nextOccurrence(rhythm, after: at)
            }
        }
        guard let latest, now.timeIntervalSince(latest) <= grace, ends.map({ latest < $0 }) ?? true else { return nil }
        return latest
    }

    public static func next(_ step: DeskStep, after date: Date) -> Date? {
        guard let rhythm = step.rhythm, let filed = filed(step) else { return nil }
        let first = firstOccurrence(step, rhythm: rhythm)
        guard step.clockStart == nil || first != nil else { return nil }
        let next: Date?
        if let first, date < first { next = first }
        else if let interval = SchedulerJobNormalizer.rhythmInterval(rhythm) {
            let anchor = first ?? filed
            next = anchor.addingTimeInterval((max(0, date.timeIntervalSince(anchor)) / interval).rounded(.down) * interval + interval)
        } else {
            next = SchedulerJobNormalizer.nextOccurrence(rhythm, after: max(first ?? filed, date))
        }
        guard let next, MyQueue.Until(step.until).endsAt.map({ next < $0 }) ?? true else { return nil }
        return next
    }

    /// Keep imported calendar civil identity through zone changes so an occurrence cannot acquire a second effect key.
    public static func occurrenceID(_ step: DeskStep, at now: Date) -> String? {
        guard let at = occurrence(step, at: now) else { return nil }
        if step.clockStart != nil, let rhythm = step.rhythm, SchedulerJobNormalizer.rhythmInterval(rhythm) == nil {
            return SchedulerJobRuntime.occurrence(at: at, zone: .autoupdatingCurrent)
        }
        return String(at.timeIntervalSince1970)
    }

    static func filed(_ step: DeskStep) -> Date? { step.filedAt.flatMap(DeskClock.parseISO) }

    /// Calendar anchors retain the complete civil time, not just the identity's minute. A supported firstRunAt of 16:00:30 must never become 16:00:00.
    public static func importedStart(at date: Date, rhythm: JSONValue) -> String {
        if SchedulerJobNormalizer.rhythmInterval(rhythm) != nil {
            return NativeTimestampFormat.microsecondUTCOffset(date, rounding: .up)
        }
        let civil = date.addingTimeInterval(TimeInterval(TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)))
        let start = NativeTimestampFormat.microsecondUTCOffset(civil, rounding: .up)
            .replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "+00:00", with: "")
        return start
    }

    /// Resolve civil time in the current zone, preserving the subminute part. The scheduler still owns minute-based occurrence identity through moves.
    private static func firstOccurrence(_ step: DeskStep, rhythm: JSONValue) -> Date? {
        guard let start = step.clockStart else { return nil }
        if SchedulerJobNormalizer.rhythmInterval(rhythm) != nil { return DeskClock.parseISO(start) }
        // Parse whole seconds separately: Foundation's ISO formatter can lose submillisecond digits. Add the stored fraction only after resolving.
        let parts = start.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, whole.count == 19,
              let civil = DeskClock.parseISO(whole.replacingOccurrences(of: " ", with: "T") + "Z"),
              let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        let fraction: TimeInterval
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Double("0." + String(parts[1])), value < 1 else { return nil }
            fraction = value
        } else { fraction = 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: civil)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: components)?.addingTimeInterval(fraction)
    }
}
