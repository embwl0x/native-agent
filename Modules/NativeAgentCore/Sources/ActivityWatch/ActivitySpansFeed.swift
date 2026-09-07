import Foundation
import GRDB

/// Read-only health evidence for the local activity-span feed.
///
/// This deliberately exposes only a newest timestamp and file sizes: activity
/// rows remain private to the store and are never copied into diagnostics.
public struct ActivitySpansFeedHealth: Sendable, Equatable {
    /// A running watcher sends a heartbeat every minute. Fifteen minutes gives
    /// the lifecycle and scheduling boundaries room to settle while still
    /// naming a capture path that stopped without reporting a failure.
    public static let captureFreshnessWindow: TimeInterval = 15 * 60

    public enum Status: String, Sendable, Equatable {
        case disabled
        case healthy
        case captureSilentlyStopped
        case checkpointOverdue
        case captureSilentlyStoppedAndCheckpointOverdue
    }

    public let status: Status
    public let newestSpanAt: Double?
    public let databaseBytes: Int64
    public let walBytes: Int64

    public var captureIsFresh: Bool {
        status == .healthy || status == .checkpointOverdue
    }
}

extension ActivitySpanStore {
    /// Inspects feed liveness without reading any span content.
    public func activitySpansFeedHealth(
        policy: ActivityPolicy,
        now: Double = Date().timeIntervalSince1970
    ) throws -> ActivitySpansFeedHealth {
        let newestSpanAt = try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(last_seen_at) FROM activity_span")
        }
        let databaseBytes = Self.fileSize(at: databaseURL)
        let walBytes = Self.fileSize(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        let checkpointLimit = max(1, databaseBytes) * Self.maximumWALToDatabaseMultiplier
        let checkpointOverdue = walBytes > checkpointLimit
        let captureFresh = policy.captureEnabled
            && newestSpanAt.map { $0 >= now - ActivitySpansFeedHealth.captureFreshnessWindow && $0 <= now } == true

        let status: ActivitySpansFeedHealth.Status
        switch (policy.captureEnabled, captureFresh, checkpointOverdue) {
        case (false, _, _):
            status = .disabled
        case (true, true, false):
            status = .healthy
        case (true, true, true):
            status = .checkpointOverdue
        case (true, false, false):
            status = .captureSilentlyStopped
        case (true, false, true):
            status = .captureSilentlyStoppedAndCheckpointOverdue
        }
        return ActivitySpansFeedHealth(
            status: status,
            newestSpanAt: newestSpanAt,
            databaseBytes: databaseBytes,
            walBytes: walBytes
        )
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
    }
}
