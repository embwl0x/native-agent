import Foundation
import NativeAgentCore

/// The live error sinks the heartbeat and the weekly self-improvement pass
/// read. A burst across them is `errorBurstThreshold` rows inside
/// `errorBurstWindow`.
public enum ErrorFeeds {
    /// Rows across the watched error feeds within the window required to call
    /// it a "burst." 10 is high enough to mean "something is repeatedly
    /// failing," low enough to catch a fault before it floods.
    public static let errorBurstThreshold = 10
    /// The recency window for the burst count, short enough that the count
    /// reflects a CURRENT cluster, not errors the feeds retain for days.
    public static let errorBurstWindow: TimeInterval = 10 * 60
    /// A watched feed with no write in this long carries NO signal. It is not
    /// evidence of health: `logs/errors.jsonl` reported "0 recent errors … ok"
    /// for three months after its only writer (the retired Python daemon) went
    /// away. 7 days is longer than any real quiet stretch on a live sink and
    /// short enough to catch a writer that silently stopped.
    public static let feedSilentAfter: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Watched error feeds

    /// One watched error sink.
    public struct ErrorFeed: Sendable, Equatable {
        /// Short name used in the heartbeat line.
        public let label: String
        /// Path relative to the data root.
        public let relativePath: String

        public init(label: String, relativePath: String) {
            self.label = label
            self.relativePath = relativePath
        }

        public func url(dataRoot: URL) -> URL {
            relativePath.split(separator: "/").reduce(dataRoot) {
                $0.appendingPathComponent(String($1))
            }
        }
    }

    /// The error sinks the heartbeat watches.
    ///
    /// `logs/errors.jsonl` used to be the ONLY one, and it has had no Swift
    /// writer since the Python daemon was retired — last row 2026-06-02, while
    /// thirteen readers kept treating its emptiness as health. The live sinks
    /// are the surface error feeds and the background-loop failure receipts.
    /// The dead file stays listed so a returning writer is still seen, but the
    /// `feedSilentAfter` guard now reports it as "no signal", never "clean".
    public static let errorFeeds: [ErrorFeed] = [
        ErrorFeed(label: "telegram", relativePath: "telegram/errors.jsonl"),
        ErrorFeed(label: "slack", relativePath: "slack/errors.jsonl"),
        ErrorFeed(label: "loops", relativePath: "logs/background_loop_failures.jsonl"),
        ErrorFeed(label: "legacy", relativePath: "logs/errors.jsonl"),
    ]

    /// What one watched feed currently says. `silent` is the honesty flag: a
    /// missing or long-unwritten feed proves nothing, so a zero `recentCount`
    /// on a silent feed must never be reported as "no errors".
    public struct ErrorFeedStatus: Sendable {
        public let feed: ErrorFeed
        /// Last modification time, or nil when the file does not exist.
        public let lastWriteAt: Date?
        /// Rows inside `errorBurstWindow` (always 0 for a silent feed — it is
        /// not read at all).
        public let recentCount: Int
        /// Up to 30 of those rows, oldest-first, truncated for evidence.
        public let recentLines: [String]
        /// Missing, unreadable, or unwritten for `feedSilentAfter`.
        public let silent: Bool

        /// Human phrasing for the heartbeat line — "no signal" for a silent
        /// feed, a row count for a live one.
        public func summary(now: Date) -> String {
            guard silent else { return "\(recentCount) row(s)" }
            guard let lastWriteAt else { return "no signal (never written)" }
            let days = Int(now.timeIntervalSince(lastWriteAt) / 86_400)
            return "no signal (last write \(days)d ago)"
        }
    }

    /// Max bytes read from the END of each feed per tick. The files are
    /// append-only and can be large; reading them whole every tick is a
    /// cooperative-pool blocker. 256 KiB of tail comfortably covers any
    /// realistic 15-minute window (a burst that overflows it still trips
    /// the threshold from the lines that fit).
    static let errorLogTailBytes = 256 * 1024

    /// Reads every watched feed's bounded tail and reports what it saw. Rows
    /// WITHOUT a parseable timestamp are SKIPPED from the count — counting
    /// undated/malformed historical rows as "current" makes a stale corrupt log
    /// a permanent false burst trigger. The whole bounded tail is scanned (no
    /// early break — interleaved out-of-order timestamps must not hide newer
    /// rows). A silent feed is never opened: its rows cannot be current, and a
    /// bogus future timestamp in a dead file must not manufacture a burst.
    public static func scanErrorFeeds(dataRoot: URL, now: Date) -> [ErrorFeedStatus] {
        errorFeeds.map { feed in
            let path = feed.url(dataRoot: dataRoot)
            let lastWriteAt = (try? FileManager.default.attributesOfItem(atPath: path.path))?[
                .modificationDate] as? Date
            let silent = lastWriteAt.map { now.timeIntervalSince($0) > feedSilentAfter } ?? true
            guard !silent else {
                return ErrorFeedStatus(
                    feed: feed, lastWriteAt: lastWriteAt,
                    recentCount: 0, recentLines: [], silent: true)
            }
            let kept = recentRows(at: path, now: now)
            return ErrorFeedStatus(
                feed: feed, lastWriteAt: lastWriteAt,
                recentCount: kept.count,
                recentLines: Array(kept.prefix(30).reversed()),
                silent: false)
        }
    }

    /// Newest-first rows inside the burst window from one feed's bounded tail.
    private static func recentRows(at path: URL, now: Date) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(errorLogTailBytes) ? size - UInt64(errorLogTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = now.addingTimeInterval(-errorBurstWindow)
        var kept: [String] = []
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = (obj["lastAt"] as? String ?? obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
            else { continue }  // undated/malformed: never counted as current
            // No early break: writers can interleave slightly out-of-order
            // timestamps, and one stale row must not hide newer rows behind
            // it. The scan is already bounded by errorLogTailBytes.
            if ts < cutoff { continue }
            // 2026-09-22: a wifi drop is not a fault.
            if SwiftNativeLoopScheduler.isOfflineError(String(line)) { continue }
            kept.append(line.prefix(280).description)
        }
        return kept
    }

    // MARK: - Helpers

    static func parseISO(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601(s)
    }
}
