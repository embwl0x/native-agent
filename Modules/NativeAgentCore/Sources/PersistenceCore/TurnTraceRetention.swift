import Foundation
import NativeAgentCore

/// M7 (honesty sweep, 2026-07-09): `<dataRoot>/turn_traces/` accumulated one
/// `<yyyy-MM-dd>.jsonl` plus one orphaned `<yyyy-MM-dd>.jsonl.lock` per day and
/// nothing ever removed them (~236MB/yr). `ChatSessionRetention` bounded the
/// chat index but only the chat index. This is the date-keyed sibling.
///
/// Deliberately simple and destructive-by-date rather than by size: a trace day
/// is a debugging artifact with a natural expiry, unlike a conversation, so
/// there is nothing to archive. Only files whose NAME parses as a day older than
/// the cutoff are touched — an unparseable filename is left alone rather than
/// guessed at.
public struct TurnTraceRetentionReport: Sendable, Equatable {
    public var keptDays: Int
    public var removedDays: Int
    public var removedLocks: Int

    public init(keptDays: Int = 0, removedDays: Int = 0, removedLocks: Int = 0) {
        self.keptDays = keptDays
        self.removedDays = removedDays
        self.removedLocks = removedLocks
    }
}

public enum TurnTraceRetention {
    /// Days of trace history to keep, counting the current day.
    public static let defaultKeepDays = 14

    /// Remove `turn_traces/<date>.jsonl` (and its `.lock` sidecar) for every day
    /// strictly older than `keepDays` days before `now`.
    ///
    /// The lock sidecar for an expired day can never be held: a flock is only
    /// taken while appending, and appends only ever target the CURRENT day's
    /// file. Removing the `.jsonl` without its `.lock` is what left the orphans.
    @discardableResult
    public static func enforce(
        dataRoot: URL = defaultDataRoot(),
        now: Date = Date(),
        keepDays: Int = defaultKeepDays
    ) throws -> TurnTraceRetentionReport {
        let dir = dataRoot.appendingPathComponent("turn_traces", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return TurnTraceRetentionReport()
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )

        // Cutoff is the START of the (keepDays - 1)-days-ago day, so keepDays=14
        // keeps today plus the previous 13 days. Day boundaries use the same
        // local calendar the writer's `dayFormatter` uses.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(max(1, keepDays) - 1), to: today) else {
            return TurnTraceRetentionReport()
        }

        var report = TurnTraceRetentionReport()
        for entry in entries where entry.lastPathComponent.hasSuffix(".jsonl") {
            let day = entry.lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            guard let dayDate = dayFormatter.date(from: day) else {
                // Not a date-named trace file — never guess, never delete.
                continue
            }
            guard dayDate < cutoff else {
                report.keptDays += 1
                continue
            }
            try FileManager.default.removeItem(at: entry)
            report.removedDays += 1
            let lock = entry.appendingPathExtension("lock")
            if FileManager.default.fileExists(atPath: lock.path) {
                try FileManager.default.removeItem(at: lock)
                report.removedLocks += 1
            }
        }

        // Second pass: a `.lock` for an expired day whose `.jsonl` is already
        // gone (a previous partial sweep, or a lock taken for a file that was
        // never written). Same date gate — a lock for a live day is never touched.
        for entry in entries where entry.lastPathComponent.hasSuffix(".jsonl.lock") {
            let day = entry.lastPathComponent.replacingOccurrences(of: ".jsonl.lock", with: "")
            guard let dayDate = dayFormatter.date(from: day), dayDate < cutoff else { continue }
            guard FileManager.default.fileExists(atPath: entry.path) else { continue }
            try FileManager.default.removeItem(at: entry)
            report.removedLocks += 1
        }
        return report
    }

    /// Mirrors `TurnTracePersistLane.dayFormatter` exactly — same locale, same
    /// local timezone, same `yyyy-MM-dd` pattern. A divergence here would either
    /// spare files forever or delete the live day.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
