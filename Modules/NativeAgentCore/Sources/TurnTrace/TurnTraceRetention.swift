import Foundation
import NativeAgentCore
import PersistenceCore

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
    /// Root-relative paths removed by this pass. Capture their public audit
    /// identity while the artifact still exists; resolving an already-deleted
    /// leaf can lose a symlinked root spelling and silently drop an audit row.
    public var removedArtifactPaths: [String]

    public init(
        keptDays: Int = 0,
        removedDays: Int = 0,
        removedLocks: Int = 0,
        removedArtifactPaths: [String] = []
    ) {
        self.keptDays = keptDays
        self.removedDays = removedDays
        self.removedLocks = removedLocks
        self.removedArtifactPaths = removedArtifactPaths
    }
}

public enum TurnTraceRetention {
    /// Days of trace history to keep, counting the current day.
    public static let defaultKeepDays = 14

    /// Remove expired day files under the same locks reconciliation holds.
    /// FileLockSidecarLifecycle owns reclamation of orphaned lock sidecars.
    @discardableResult
    public static func enforce(
        dataRoot: URL = defaultDataRoot(),
        now: Date = Date(),
        keepDays: Int = defaultKeepDays
    ) async throws -> TurnTraceRetentionReport {
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
            guard let dayDate = dayLock.withLock({ dayFormatter.date(from: day) }) else {
                // Not a date-named trace file — never guess, never delete.
                continue
            }
            guard dayDate < cutoff else {
                report.keptDays += 1
                continue
            }
            let removedPath = try await SwiftNativePersistenceCore().withFileLock(entry) {
                guard FileManager.default.fileExists(atPath: entry.path) else { return nil as String? }
                let auditPath = relativePath(entry, from: dataRoot)
                try FileManager.default.removeItem(at: entry)
                return auditPath
            }
            if let removedPath {
                report.removedDays += 1
                report.removedArtifactPaths.append(removedPath)
            }
        }
        return report
    }

    /// Mirrors `TurnTracePersistLane.dayFormatter` exactly — same locale, same
    /// local timezone, same `yyyy-MM-dd` pattern. A divergence here would either
    /// spare files forever or delete the live day. Only used under `dayLock`.
    private static let dayLock = NSLock()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func relativePath(_ artifact: URL, from dataRoot: URL) -> String {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = artifact.standardizedFileURL.resolvingSymlinksInPath().path
        precondition(path.hasPrefix(root + "/"), "turn trace artifact escaped its data root")
        return String(path.dropFirst(root.count + 1))
    }
}
