import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ErrorFeeds.swift` | `ErrorFeeds`: shared live error-feed inventory and bounded recent-burst scans with explicit read/integrity availability |

public enum ErrorFeeds {
    /// Ten errors distinguishes repeated failure from a transient fault before the feed floods.
    public static let errorBurstThreshold = 10
    /// Use a recent window so old retained errors cannot masquerade as a current burst.
    public static let errorBurstWindow: TimeInterval = 10 * 60
    /// Seven silent days means no current signal, not health or failure; ordinary quiet stretches remain neutral.
    public static let feedSilentAfter: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Watched error feeds

    public struct ErrorFeed: Sendable, Equatable {
        public let label: String
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

    /// Error feeds that are still files. Loop failures are `loop.failure` details in the record, scanned beside them under `loopFailureLabel`.
    public static let errorFeeds: [ErrorFeed] = [
        ErrorFeed(label: "telegram", relativePath: "telegram/errors.jsonl"),
        ErrorFeed(label: "slack", relativePath: "slack/errors.jsonl"),
    ]
    public static let loopFailureLabel = "loops"

    public struct ErrorFeedStatus: Sendable {
        public let label: String
        public let unavailable: String?
        /// Silent feeds contribute no current rows and are not opened.
        public let recentCount: Int
        public let earliestExpiry: Date?
        /// Cap retained evidence at 30 rows, oldest first, so a burst cannot flood context.
        public let recentLines: [String]
    }

    /// Read only a 256 KiB tail: append-only feeds can be huge, and a burst overflowing that cap still trips the threshold.
    static let errorLogTailBytes = 256 * 1024

    /// Undated rows make burst evidence unavailable, never a clean count; scan the bounded tail without early breaks.
    /// Never open silent feeds: stale files with bogus future timestamps must not manufacture current bursts.
    public static func scanErrorFeeds(dataRoot: URL, now: Date) async -> [ErrorFeedStatus] {
        let files = errorFeeds.map { feed in
            let path = feed.url(dataRoot: dataRoot)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                guard let lastWriteAt = attributes[.modificationDate] as? Date else {
                    throw PersistenceCoreError.ioFailure("modification date unavailable at \(path.path)")
                }
                guard now.timeIntervalSince(lastWriteAt) <= feedSilentAfter else {
                    return ErrorFeedStatus(label: feed.label, unavailable: nil,
                        recentCount: 0, earliestExpiry: nil, recentLines: [])
                }
                let kept = try recentRows(at: path, now: now)
                return ErrorFeedStatus(label: feed.label, unavailable: nil,
                    recentCount: kept.lines.count, earliestExpiry: kept.earliestExpiry,
                    recentLines: Array(kept.lines.prefix(30).reversed()))
            } catch CocoaError.fileReadNoSuchFile {
                return ErrorFeedStatus(label: feed.label, unavailable: nil,
                    recentCount: 0, earliestExpiry: nil, recentLines: [])
            } catch {
                return ErrorFeedStatus(label: feed.label, unavailable: "\(path.path): \(error.localizedDescription)",
                    recentCount: 0, earliestExpiry: nil, recentLines: [])
            }
        }
        let loops = await recentLoopFailures(dataRoot: dataRoot, now: now)
        return files + [loops]
    }

    /// One row per loop failure incident whose last occurrence is inside the burst window, as the incident row the trail held; an unreadable
    /// record makes this feed unavailable, never quiet.
    private static func recentLoopFailures(dataRoot: URL, now: Date) async -> ErrorFeedStatus {
        do {
            let cutoff = now.addingTimeInterval(-errorBurstWindow)
            let recent = try await LoopFailureReceipts.incidents(dataRoot: dataRoot)
                .filter { $0.lastAt >= cutoff && !SwiftNativeLoopScheduler.isOfflineError($0.error) }
                .sorted { $0.lastAt > $1.lastAt }
            let lines = try recent.map { String(decoding: try $0.row.serializedData(pretty: false), as: UTF8.self).prefix(280).description }
            let expiry = recent.map { $0.lastAt.addingTimeInterval(errorBurstWindow + 0.001) }.min()
            return ErrorFeedStatus(label: loopFailureLabel, unavailable: nil, recentCount: recent.count, earliestExpiry: expiry,
                recentLines: Array(lines.prefix(30).reversed()))
        } catch {
            return ErrorFeedStatus(label: loopFailureLabel, unavailable: "experiences/experiences.sqlite (loop.failure): \(error.localizedDescription)",
                recentCount: 0, earliestExpiry: nil, recentLines: [])
        }
    }

    private static func recentRows(at path: URL, now: Date) throws -> (lines: [String], earliestExpiry: Date?) {
        guard let read = try SwiftNativePersistenceCore.tailPhysicalLines(path, limit: .max, maxBytes: errorLogTailBytes) else { return ([], nil) }
        let cutoff = now.addingTimeInterval(-errorBurstWindow)
        var kept: [String] = []
        var earliestExpiry: Date?
        for lineData in read.lines.dropFirst(read.leadingFragment ? 1 : 0).reversed() {
            guard let line = String(data: lineData, encoding: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = (obj["lastAt"] as? String ?? obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
            else {
                throw PersistenceCoreError.ioFailure(
                    "error feed has a malformed or undated row at \(path.path); repair the retained evidence before judging its burst count"
                )
            }
            // Scan the whole bounded tail: interleaved stale timestamps must not hide newer rows.
            if ts < cutoff { continue }
            // Offline errors are network weather, not faults.
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
