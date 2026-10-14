import Foundation
import GRDB

/// Single-writer SQLite store for activity spans.
///
/// Construction style mirrors `ContextSQLiteStore` (subdirectory + GRDB
/// `Configuration` + `DatabaseMigrator`). Own DB file, mode 0600, inside
/// `<dataRoot>/activity_watch/activity_spans.sqlite`.
///
/// ONE table. There is no `activity_event` table (cut in the cold pass — it had
/// zero readers). The `title_redacted` column holds redacted window titles.
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

    /// W10 default retention. v0 shipped 7 d because it was a throwaway probe;
    /// v1's ceiling is 30 d (build plan W3) and it is configurable through
    /// `ActivityPolicy.retentionDays`.
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
            // WAL + single writer (build plan W3). WAL is also why `purge` has
            // to checkpoint: without it the deleted rows sit legible in the
            // `-wal` sidecar and the retro-delete is theatre.
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

    /// Writes the span row **at open time** (`ended_at` NULL). The durability
    /// story is this row plus `last_seen_at`, not a graceful-shutdown flush.
    public func openSpan(_ span: ActivitySpan) throws {
        try dbQueue.write { db in
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
        }
    }

    /// Applies one engine command. The store's write API and
    /// `ActivityStoreCommand` are one-to-one on purpose: no translation layer
    /// means no place for the live path and the simulated path to diverge.
    public func apply(_ command: ActivityStoreCommand) throws {
        switch command {
        case .open(let span):
            try openSpan(span)
        case .touch(let id, let at):
            try touchSpan(id: id, at: at)
        case .heartbeat(let id, let at):
            try heartbeatSpan(id: id, at: at)
        case .retitle(let id, let titleRedacted, let at):
            try retitleSpan(id: id, titleRedacted: titleRedacted, at: at)
        case .close(let id, let reason, let at):
            try closeSpan(id: id, reason: reason, at: at)
        case .reconcileAbandoned:
            try reconcileAbandonedSpans()
        }
    }

    /// One processed event: advances `last_seen_at` and bumps `event_count`.
    ///
    /// `last_seen_at` must move on every event, not only on the heartbeat —
    /// heartbeat-only would close a crashed span up to a full tick before the
    /// last real activity and silently discard it (cut-review correction, W3).
    /// `last_seen_at` never moves backwards, so an out-of-order handoff cannot
    /// rewind the crash-recovery bound.
    public func touchSpan(id: String, at timestamp: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE activity_span
                SET last_seen_at = MAX(last_seen_at, ?), event_count = event_count + 1
                WHERE id = ? AND ended_at IS NULL
                """,
                arguments: [timestamp, id]
            )
        }
    }

    /// Liveness only: advances `last_seen_at` WITHOUT counting an event.
    ///
    /// The 60 s tick must not inflate `event_count` — events/hour is the number
    /// v0 exists to measure, and a heartbeat is not a human event.
    public func heartbeatSpan(id: String, at timestamp: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE activity_span
                SET last_seen_at = MAX(last_seen_at, ?)
                WHERE id = ? AND ended_at IS NULL
                """,
                arguments: [timestamp, id]
            )
        }
    }

    /// Stamps the open span's INITIAL title onto the existing row.
    ///
    /// This is what replaced the close-and-reopen that used to fire on a span's
    /// first title. The live watcher reads the title microseconds after the
    /// activation that opened the span, so splitting there produced one junk
    /// zero-length row per app switch (8 of 16 rows in the 2026-08-14 live run).
    /// Counted as an event — a title arriving IS evidence the human did
    /// something — but it never touches `started_at` and never opens a row.
    ///
    /// `ended_at IS NULL` in the predicate: a span that closed between the
    /// engine emitting this and the pump applying it must not be retitled after
    /// the fact.
    public func retitleSpan(id: String, titleRedacted: String?, at timestamp: Double) throws {
        try dbQueue.write { db in
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
        }
    }

    public func closeSpan(id: String, reason: ActivityCloseReason, at timestamp: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE activity_span
                SET ended_at = MAX(started_at, ?), close_reason = ?
                WHERE id = ? AND ended_at IS NULL
                """,
                arguments: [timestamp, reason.rawValue, id]
            )
        }
    }

    /// Startup reconciliation: every span left open by a prior process is closed
    /// **at its own `last_seen_at`**, not at "now" — a crash must not invent the
    /// hours between the crash and the next launch.
    @discardableResult
    public func reconcileAbandonedSpans() throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE activity_span
                SET ended_at = last_seen_at, close_reason = ?
                WHERE ended_at IS NULL
                """,
                arguments: [ActivityCloseReason.abandoned.rawValue]
            )
            return db.changesCount
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
            // Retention is also the bounded, durable maintenance cadence for
            // an otherwise healthy capture stream. Previously this path did
            // nothing when every row was in-window, allowing the WAL to sit at
            // its cap indefinitely even though the retention runner was firing.
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

    /// QUERY-TIME FILTER (W5 layer 2). Exclusion lists change: adding 1Password
    /// today must make yesterday unanswerable, whether or not the retro-delete
    /// has run yet. Applied as SQL, not a Swift `filter`, so an excluded row
    /// cannot be counted toward a LIMIT and then dropped — that would silently
    /// shrink legitimate answers.
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

    // MARK: - Retro-delete (W5 layer 3)

    /// Purge every row for a bundle id, then make the bytes actually leave.
    ///
    /// A DELETE alone leaves the rows recoverable in the `-wal` sidecar and in
    /// free pages of the main file. A purge that leaves the data in `-wal` is
    /// theatre, so this checkpoints WAL into the DB (TRUNCATE mode, which also
    /// empties the sidecar) and then VACUUMs to rewrite the file without the
    /// freed pages.
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

    /// Purge a whole set at once (adding several exclusions in one edit).
    @discardableResult
    public func purge(bundleIDs: Set<String>) throws -> Int {
        guard !bundleIDs.isEmpty else { return 0 }
        let ids = Array(bundleIDs)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let deleted = try dbQueue.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM activity_span WHERE bundle_id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            return db.changesCount
        }
        try checkpointAndVacuum()
        return deleted
    }

    /// Checkpoint → VACUUM → checkpoint. All three, in that order.
    ///
    /// The first checkpoint folds the deleted rows out of the WAL and into the
    /// main file; the VACUUM rewrites the main file without the freed pages. The
    /// SECOND checkpoint is the one that is easy to forget and the one that
    /// makes this honest — in WAL mode the VACUUM's own rewrite lands in the WAL,
    /// so skipping it leaves ~28 KB of pre-vacuum page images sitting in the
    /// sidecar, which is exactly the data the purge just promised to destroy.
    /// (Measured, not assumed: without the trailing checkpoint the retro-delete
    /// test found 28,872 bytes still in `-wal`.)
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

    private static func span(from row: Row) -> ActivitySpan {
        ActivitySpan(
            id: row["id"],
            startedAt: row["started_at"],
            endedAt: row["ended_at"],
            lastSeenAt: row["last_seen_at"],
            bundleId: row["bundle_id"],
            appName: row["app_name"],
            titleRedacted: row["title_redacted"],
            eventCount: row["event_count"],
            closeReason: (row["close_reason"] as String?).flatMap(ActivityCloseReason.init(rawValue:)),
            tzOffsetMin: row["tz_offset_min"]
        )
    }

    // MARK: - Migration

    /// Migrations are APPEND-ONLY. `activity_span_v0` is frozen exactly as it
    /// shipped — editing it would make an existing v0 database un-migratable
    /// (GRDB records the identifier, not the SQL, so a rewritten v0 silently
    /// never re-runs and the schema diverges by machine).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // NOTE: v0 had NO title column of any kind. W5 adds exactly one, and it
        // is named `title_redacted` so the invariant is legible at the schema
        // level; ActivityWatchArchitectureTests fails on any other title-ish
        // column name.
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
        // W5 title capture. Nullable, added as a SECOND migration so a v0
        // database on disk migrates in place rather than being rebuilt — the
        // v0 rows are real measurements and dropping them to gain a column
        // would be losing data to gain a feature.
        migrator.registerMigration("activity_span_v1_title_redacted") { db in
            try db.execute(sql: """
                ALTER TABLE activity_span ADD COLUMN title_redacted TEXT NULL;
                """)
        }
        return migrator
    }
}
