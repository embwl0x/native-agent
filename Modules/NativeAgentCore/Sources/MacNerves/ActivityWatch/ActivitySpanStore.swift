import Foundation
import GRDB
// Blueprint: | `ActivitySpanStore.swift` | `ActivitySpanStore`: per-root acquisition; retention owes compaction until VACUUM and checkpoints succeed |

/// One writer owns private activity spans and durable compaction debt in an owner-only database.
public actor ActivitySpanStore {
    private actor Stores {
        var stores: [URL: (store: ActivitySpanStore, identity: NSObject)] = [:]

        func acquire(dataRoot: URL, existingOnly: Bool) throws -> ActivitySpanStore? {
            let url = ActivityWatchPaths.databaseURL(dataRoot: dataRoot).standardizedFileURL
            let current: NSObject?
            do { current = try identity(at: url) }
            catch CocoaError.fileReadNoSuchFile { current = nil }
            catch CocoaError.fileNoSuchFile { current = nil }
            if let cached = stores[url], let current, cached.identity.isEqual(current) {
                return cached.store
            }
            stores[url] = nil
            if existingOnly, current == nil { return nil }
            let store = try ActivitySpanStore(databaseURL: url)
            stores[url] = (store, try identity(at: url))
            return store
        }

        private func identity(at url: URL) throws -> NSObject {
            guard let identity = try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier as? NSObject else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return identity
        }
    }

    private static let stores = Stores()

    public static func acquire(dataRoot: URL, existingOnly: Bool = false) async throws -> ActivitySpanStore? {
        try await stores.acquire(dataRoot: dataRoot, existingOnly: existingOnly)
    }

    public static let defaultRetention: TimeInterval =
        Double(ActivityPolicy.defaultRetentionDays) * 86_400

    public let databaseURL: URL
    let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        let newStore: Bool
        do {
            _ = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            newStore = false
        } catch CocoaError.fileReadNoSuchFile { newStore = true }
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.databaseURL = databaseURL

        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            // WAL storage requires checkpointing for physical privacy deletion.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA journal_size_limit = 4194304")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try dbQueue.write { db in
            if try db.tableExists("activity_span") {
                let columns = Set(try db.columns(in: "activity_span").map(\.name))
                guard columns.isSuperset(of: [
                    "id", "started_at", "ended_at", "last_seen_at", "bundle_id", "app_name",
                    "event_count", "close_reason", "tz_offset_min", "title_redacted"
                ]) else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: databaseURL.path])
                }
            } else {
                guard newStore else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: databaseURL.path])
                }
                try Self.createSchema(db)
            }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS activity_compaction_owed (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    since DOUBLE NOT NULL
                )
                """)
        }

        // Activity history must remain owner-only; group or world readability exposes private behavior.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: databaseURL.path
        )
    }

    // MARK: - Write path

    public func apply(_ command: ActivityStoreCommand) throws {
        try dbQueue.write { db in
            switch command {
            case .open(let span):
                // Persist open rows and last observation for crash settlement.
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO activity_span (
                        id, started_at, ended_at, last_seen_at,
                        bundle_id, app_name, title_redacted,
                        event_count, close_reason, tz_offset_min
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        span.id, span.startedAt, span.endedAt, span.lastSeenAt,
                        span.bundleId, span.appName, span.titleRedacted,
                        span.eventCount, span.closeReason?.rawValue, span.tzOffsetMin,
                    ]
                )
            case .touch(let id, let timestamp):
                // Never rewind the crash-recovery bound when counting events.
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET last_seen_at = MAX(last_seen_at, ?), event_count = event_count + 1
                    WHERE id = ? AND ended_at IS NULL
                    """,
                    arguments: [timestamp, id]
                )
            case .heartbeat(let id, let timestamp):
                // Liveness must not fabricate a human event.
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET last_seen_at = MAX(last_seen_at, ?)
                    WHERE id = ? AND ended_at IS NULL
                    """,
                    arguments: [timestamp, id]
                )
            case .retitle(let id, let titleRedacted, let timestamp):
                // Only an open span may learn its initial title.
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET title_redacted = ?,
                        last_seen_at = MAX(last_seen_at, ?),
                        event_count = event_count + 1
                    WHERE id = ? AND ended_at IS NULL
                    """,
                    arguments: [titleRedacted, timestamp, id]
                )
            case .close(let id, let reason, let timestamp):
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET ended_at = MAX(started_at, ?), close_reason = ?
                    WHERE id = ? AND ended_at IS NULL
                    """,
                    arguments: [timestamp, reason.rawValue, id]
                )
            case .reconcileAbandoned:
                // A crash provides no evidence of activity after the last observation.
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET ended_at = last_seen_at, close_reason = ?
                    WHERE ended_at IS NULL
                    """,
                    arguments: [ActivityCloseReason.abandoned.rawValue]
                )
            }
        }
    }

    // MARK: - Retention

    /// Commit deletion with compaction debt so physical privacy cleanup remains owed across failure or restart.
    @discardableResult
    public func prune(
        olderThan retention: TimeInterval = ActivitySpanStore.defaultRetention,
        now: Double = Date().timeIntervalSince1970
    ) throws -> Int {
        let cutoff = now - retention
        let result = try dbQueue.write { db -> (deleted: Int, compactionOwed: Bool) in
            try db.execute(
                sql: "DELETE FROM activity_span WHERE COALESCE(ended_at, last_seen_at) < ?",
                arguments: [cutoff]
            )
            let deleted = db.changesCount
            if deleted > 0 {
                // Retain the first unpaid deletion time until physical cleanup succeeds.
                try db.execute(
                    sql: "INSERT INTO activity_compaction_owed (id, since) VALUES (1, ?) ON CONFLICT(id) DO NOTHING",
                    arguments: [now]
                )
            }
            let since = try Double.fetchOne(db, sql: "SELECT since FROM activity_compaction_owed WHERE id = 1")
            if let since, !since.isFinite {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: databaseURL.path])
            }
            return (deleted, since != nil)
        }
        if result.compactionOwed {
            try checkpointAndVacuum()
        } else {
            // Checkpoint the WAL even when no rows expire so ordinary capture also becomes durable.
            try checkpointWAL()
        }
        return result.deleted
    }

    @discardableResult
    public func wipeAll() throws -> Int {
        let deleted = try dbQueue.write { db -> Int in
            try db.execute(sql: "DELETE FROM activity_span")
            return db.changesCount
        }
        try checkpointAndVacuum()
        return deleted
    }

    // MARK: - Read path

    /// Query overlap, not starts: a span begun yesterday still contributes its time inside today.
    public func spansOverlapping(
        from: Double,
        to: Double,
        limit: Int = 20_000,
        policy: ActivityPolicy? = nil,
        bundleID: String? = nil
    ) throws -> [ActivitySpan] {
        let excluded = policy.map { Array($0.effectiveExcludedBundleIDs) } ?? []
        return try dbQueue.read { db in
            var predicate = "started_at <= ? AND COALESCE(ended_at, last_seen_at) >= ?"
            var arguments: [DatabaseValueConvertible] = [to, from]
            if let bundleID, !bundleID.isEmpty {
                // Restrict before LIMIT so unrelated rows cannot displace valid matches and imply an empty answer.
                predicate += " AND bundle_id = ?"
                arguments.append(bundleID)
            }
            return try Self.fetchSpans(
                db,
                predicate: predicate,
                arguments: arguments,
                excluded: excluded,
                order: "started_at ASC",
                limit: limit
            )
        }
    }

    /// Apply current exclusions before LIMIT so excluded history cannot displace valid answer rows.
    private static func fetchSpans(
        _ db: Database,
        predicate: String,
        arguments: [DatabaseValueConvertible],
        excluded: [String],
        order: String,
        limit: Int
    ) throws -> [ActivitySpan] {
        var sql = """
        SELECT id, started_at, ended_at, last_seen_at, bundle_id, app_name,
               title_redacted, event_count, close_reason, tz_offset_min
        FROM activity_span
        WHERE \(predicate)
        """
        var args: [DatabaseValueConvertible] = arguments
        if !excluded.isEmpty {
            let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ", ")
            sql += " AND bundle_id NOT IN (\(placeholders))"
            args.append(contentsOf: excluded)
        }
        sql += " ORDER BY \(order) LIMIT ?"
        args.append(limit)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            .map(Self.span(from:))
    }

    // MARK: - Retroactive deletion

    /// Remove recoverable database and WAL bytes as well as the logical rows.
    @discardableResult
    public func purge(bundleID: String) throws -> Int {
        let deleted = try dbQueue.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM activity_span WHERE bundle_id = ?",
                arguments: [bundleID]
            )
            return db.changesCount
        }
        try checkpointAndVacuum()
        return deleted
    }

    /// Checkpoint, VACUUM, then checkpoint: merge WAL, remove freed pages, then clear the rewrite WAL.
    public func checkpointAndVacuum() throws {
        try dbQueue.writeWithoutTransaction { db in
            func checkpoint() throws {
                guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)"),
                      (row[0] as Int) == 0, (row[1] as Int) == (row[2] as Int) else {
                    throw DatabaseError(resultCode: .SQLITE_BUSY, message: "Activity privacy deletion could not finish clearing the WAL.")
                }
            }
            try checkpoint()
            try db.execute(sql: "VACUUM")
            try checkpoint()
            // Clear the obligation only after physical cleanup, leaving it owed across a crash or failure.
            try db.execute(sql: "DELETE FROM activity_compaction_owed WHERE id = 1")
        }
    }

    /// When nothing expires, checkpoint ordinary writes through the same retention cadence.
    public func checkpointWAL() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private static func span(from row: Row) throws -> ActivitySpan {
        let storedCount: DatabaseValue = row["event_count"]
        guard case .int64(let integer) = storedCount.storage,
              let count = Int(exactly: integer), count >= 0 else {
            throw ActivityRollups.RollupError.invalidEventCount(source: "span \(row["id"] as String)")
        }
        return ActivitySpan(
            id: row["id"],
            startedAt: row["started_at"],
            endedAt: row["ended_at"],
            lastSeenAt: row["last_seen_at"],
            bundleId: row["bundle_id"],
            appName: row["app_name"],
            titleRedacted: row["title_redacted"],
            eventCount: count,
            closeReason: (row["close_reason"] as String?).flatMap(ActivityCloseReason.init(rawValue:)),
            tzOffsetMin: row["tz_offset_min"]
        )
    }

    // MARK: - Current schema

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE activity_span (
                id TEXT PRIMARY KEY, started_at DOUBLE NOT NULL,
                ended_at DOUBLE NULL, last_seen_at DOUBLE NOT NULL,
                bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
                event_count INTEGER NOT NULL, close_reason TEXT NULL,
                tz_offset_min INTEGER NOT NULL, title_redacted TEXT NULL
            );
            CREATE INDEX idx_activity_span_started_at ON activity_span (started_at);
            CREATE INDEX idx_activity_span_bundle_started ON activity_span (bundle_id, started_at);
            """)
    }
}
