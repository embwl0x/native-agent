import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ErrorFeeds.swift` | `ErrorFeeds`: shared live error-feed inventory and bounded recent-burst scans for heartbeat and weekly improvement |

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
    /// A watched live feed with no write in this long carries no current signal,
    /// rather than evidence of health. Seven days catches a silent writer
    /// without treating an ordinary quiet stretch as failure.
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

    /// Live surface error feeds and background-loop failure receipts.
    public static let errorFeeds: [ErrorFeed] = [
        ErrorFeed(label: "telegram", relativePath: "telegram/errors.jsonl"),
        ErrorFeed(label: "slack", relativePath: "slack/errors.jsonl"),
        ErrorFeed(label: "loops", relativePath: "logs/background_loop_failures.jsonl"),
    ]

    /// Bounded recent evidence from one watched feed.
    public struct ErrorFeedStatus: Sendable {
        public let feed: ErrorFeed
        /// Rows inside `errorBurstWindow` (always 0 for a silent feed — it is
        /// not read at all).
        public let recentCount: Int
        public let earliestExpiry: Date?
        /// Up to 30 of those rows, oldest-first, truncated for evidence.
        public let recentLines: [String]
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
                    feed: feed, recentCount: 0, earliestExpiry: nil, recentLines: [])
            }
            let kept = recentRows(at: path, now: now)
            return ErrorFeedStatus(
                feed: feed,
                recentCount: kept.lines.count, earliestExpiry: kept.earliestExpiry,
                recentLines: Array(kept.lines.prefix(30).reversed()))
        }
    }

    /// Newest-first rows inside the burst window from one feed's bounded tail.
    private static func recentRows(at path: URL, now: Date) -> (lines: [String], earliestExpiry: Date?) {
        guard let read = try? SwiftNativePersistenceCore.tailPhysicalLines(path, limit: .max, maxBytes: errorLogTailBytes) else { return ([], nil) }
        let cutoff = now.addingTimeInterval(-errorBurstWindow)
        var kept: [String] = []
        var earliestExpiry: Date?
        for lineData in read.lines.reversed() {
            guard let line = String(data: lineData, encoding: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = (obj["lastAt"] as? String ?? obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
            else { continue }  // undated/malformed: never counted as current
            // No early break: writers can interleave slightly out-of-order
            // timestamps, and one stale row must not hide newer rows behind
            // it. The scan is already bounded by errorLogTailBytes.
            if ts < cutoff { continue }
            // Offline errors do not count as faults.
            if SwiftNativeLoopScheduler.isOfflineError(line) { continue }
            let expiry = ts.addingTimeInterval(errorBurstWindow + 0.001)
            earliestExpiry = min(earliestExpiry ?? expiry, expiry)
            kept.append(line.prefix(280).description)
        }
        return (kept, earliestExpiry)
    }

    // MARK: - Helpers

    static func parseISO(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601(s)
    }
}
