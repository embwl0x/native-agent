import Foundation
import GRDB
// Blueprint: | `ActivitySpanStore.swift` | `ActivitySpanStore`; asynchronous per-root store acquisition shared by capture, retention and queries |

/// Single-writer SQLite store for activity spans.
///
/// Construction style mirrors `ContextSQLiteStore` (subdirectory + GRDB
/// `Configuration` + `DatabaseMigrator`). Own DB file, mode 0600, inside
/// `<dataRoot>/activity_watch/activity_spans.sqlite`.
///
/// One table; `title_redacted` holds redacted window titles.
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

    /// Default retention is 30 days, configurable through `ActivityPolicy.retentionDays`.
    public static let defaultRetention: TimeInterval =
        Double(ActivityPolicy.defaultRetentionDays) * 86_400

    public let databaseURL: URL
    let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
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
        try Self.migrator.migrate(dbQueue)

        // Owner-only. This file is a record of where the human was; a
        // group/world-readable mode would be a privacy defect on its own.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: databaseURL.path
        )
    }

    // MARK: - Write path

    /// Apply one command in one write transaction.
    public func apply(_ command: ActivityStoreCommand) throws {
        try dbQueue.write { db in
            switch command {
            case .open(let span):
                // Open rows and last-seen timestamps survive an ungraceful exit.
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
                // Count events and never rewind the crash-recovery bound.
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET last_seen_at = MAX(last_seen_at, ?), event_count = event_count + 1
                    WHERE id = ? AND ended_at IS NULL
                    """,
                    arguments: [timestamp, id]
                )
            case .heartbeat(let id, let timestamp):
                // Liveness advances without counting a human event.
                try db.execute(
                    sql: """
                    UPDATE activity_span
                    SET last_seen_at = MAX(last_seen_at, ?)
                    WHERE id = ? AND ended_at IS NULL
                    """,
                    arguments: [timestamp, id]
                )
            case .retitle(let id, let titleRedacted, let timestamp):
                // Set the initial title only while open, counting its arrival.
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
                // Close at the last observation, never inventing time after a crash.
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

    /// Deletes spans whose end (or last-seen, for still-open rows) predates the
    /// retention window, then VACUUMs so the bytes actually leave the file.
    @discardableResult
    public func prune(
        olderThan retention: TimeInterval = ActivitySpanStore.defaultRetention,
        now: Double = Date().timeIntervalSince1970
    ) throws -> Int {
        let cutoff = now - retention
        let deleted = try dbQueue.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM activity_span WHERE COALESCE(ended_at, last_seen_at) < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
        if deleted > 0 {
            try checkpointAndVacuum()
        } else {
            // Retention checkpoints the WAL even when no rows expire.
            try checkpointWAL()
        }
        return deleted
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

    /// Spans OVERLAPPING the window — the shape every rollup needs. A span that
    /// began yesterday and ran into today belongs to today's buckets for the
    /// part that lands in them, even when its start precedes the window.
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
                // Apply the caller's bundle restriction before LIMIT. Filtering
                // an already-capped array could turn a dense valid answer into
                // an apparently empty one.
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

    /// Apply current exclusions in SQL before LIMIT, even before retroactive
    /// deletion, so excluded history cannot displace legitimate answer rows.
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

    /// Delete every row for a bundle ID and clear its recoverable database/WAL bytes.
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

    /// Checkpoint → VACUUM → checkpoint, in that order: fold WAL into the database,
    /// rewrite without freed pages, then clear the WAL left by VACUUM's rewrite.
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
        }
    }

    /// Folds ordinary in-window writes out of the WAL without rewriting the
    /// main database. Called by the due retention pass when there is nothing to
    /// delete, so capture has one durable checkpoint cadence either way.
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

    // MARK: - Migration

    /// Migrations are append-only: GRDB records identifiers, not SQL, so changing
    /// an applied migration would leave existing databases with divergent schemas.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // The original schema has no title column; only redacted titles may be stored.
        migrator.registerMigration("activity_span_v0") { db in
            try db.execute(sql: """
                CREATE TABLE activity_span (
                    id TEXT PRIMARY KEY,
                    started_at DOUBLE NOT NULL,
                    ended_at DOUBLE NULL,
                    last_seen_at DOUBLE NOT NULL,
                    bundle_id TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    event_count INTEGER NOT NULL,
                    close_reason TEXT NULL,
                    tz_offset_min INTEGER NOT NULL
                );

                CREATE INDEX idx_activity_span_started_at
                    ON activity_span (started_at);

                CREATE INDEX idx_activity_span_bundle_started
                    ON activity_span (bundle_id, started_at);
                """)
        }
        // Add nullable `title_redacted` in place, preserving existing measurements.
        migrator.registerMigration("activity_span_v1_title_redacted") { db in
            try db.execute(sql: """
                ALTER TABLE activity_span ADD COLUMN title_redacted TEXT NULL;
                """)
        }
        return migrator
    }
}
