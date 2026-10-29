import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TurnTraceRetention.swift` | `TurnTraceRetention.enforce`: date-based expiry of trace artifacts and their lock sidecars with retention receipts |

/// Expire trace days older than the cutoff; preserve unparseable filenames.
public struct TurnTraceRetentionReport: Sendable, Equatable {
    public var keptDays: Int
    public var removedDays: Int
    /// Root-relative paths removed by this pass. Capture their public audit
    /// identity while the artifact still exists; resolving an already-deleted
    /// leaf can lose a symlinked root spelling and silently drop an audit row.
    public var removedArtifactPaths: [String]

    public init(
        keptDays: Int = 0,
        removedDays: Int = 0,
        removedArtifactPaths: [String] = []
    ) {
        self.keptDays = keptDays
        self.removedDays = removedDays
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
        let calendar = TurnTracePersistLane.dayCalendar
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(max(1, keepDays) - 1), to: today) else {
            return TurnTraceRetentionReport()
        }

        var report = TurnTraceRetentionReport()
        for entry in entries where entry.lastPathComponent.hasSuffix(".jsonl") {
            let day = entry.lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            guard let dayDate = TurnTracePersistLane.day(from: day) else {
                // Not a date-named trace file — never guess, never delete.
                continue
            }
            guard dayDate < cutoff else {
                report.keptDays += 1
                continue
            }
            guard try isRegularFile(entry) else { continue }
            let removedPath = try await SwiftNativePersistenceCore.withFileLock(entry) {
                guard try isRegularFile(entry) else { return nil as String? }
                let auditPath = try relativePath(entry, from: dataRoot)
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

    private static func isRegularFile(_ path: URL) throws -> Bool {
        var entry = stat()
        if lstat(path.path, &entry) != 0 {
            if errno == ENOENT { return false }
            throw PersistenceCoreError.ioFailure("Cannot inspect trace artifact \(path.path): \(String(cString: strerror(errno)))")
        }
        guard entry.st_mode & S_IFMT == S_IFREG else {
            throw PersistenceCoreError.ioFailure("Unsupported trace artifact preserved: \(path.path)")
        }
        return true
    }

    private static func relativePath(_ artifact: URL, from dataRoot: URL) throws -> String {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = artifact.standardizedFileURL.resolvingSymlinksInPath().path
        guard let tail = NativeAgentWorkspaceRoot.relativePath(path, under: root), !tail.isEmpty else {
            throw PersistenceCoreError.ioFailure("Trace artifact escaped its data root: \(artifact.path)")
        }
        return tail
    }
}
