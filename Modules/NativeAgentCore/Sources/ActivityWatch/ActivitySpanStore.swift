import Foundation
import GRDB

/// Single-writer SQLite store for v0 activity spans.
///
/// Construction style mirrors `ContextSQLiteStore` (subdirectory + GRDB
/// `Configuration` + `DatabaseMigrator`). Own DB file, mode 0600, inside
/// `<dataRoot>/activity/activity_probe.sqlite`.
///
/// ONE table. There is no `activity_event` table (cut in the cold pass — it had
/// zero readers) and no title column of any kind.
public actor ActivitySpanStore {
    /// W10 default retention. v0 shipped 7 d because it was a throwaway probe;
    /// v1's ceiling is 30 d (build plan W3) and it is configurable through
    /// `ActivityPolicy.retentionDays`.
    public static let defaultRetention: TimeInterval =
        Double(ActivityPolicy.defaultRetentionDays) * 86_400

    public let databaseURL: URL
    private let dbQueue: DatabaseQueue

    public init(dataRoot: URL) throws {
        let directory = ActivityWatchPaths.directory(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(databaseURL: ActivityWatchPaths.databaseURL(dataRoot: dataRoot))
    }

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

    @discardableResult
    public func openSpan(
        id: String = UUID().uuidString,
        bundleId: String,
        appName: String,
        titleRedacted: String? = nil,
        at timestamp: Double,
        tzOffsetMin: Int = ActivitySpan.currentTZOffsetMinutes()
    ) throws -> ActivitySpan {
        let span = ActivitySpan(
            id: id,
            startedAt: timestamp,
            endedAt: nil,
            lastSeenAt: timestamp,
            bundleId: bundleId,
            appName: appName,
            titleRedacted: titleRedacted,
            eventCount: 0,
            closeReason: nil,
            tzOffsetMin: tzOffsetMin
        )
        try openSpan(span)
        return span
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

    public func apply(_ commands: [ActivityStoreCommand]) throws {
        for command in commands { try apply(command) }
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

    public func querySpans(
        from: Double,
        to: Double,
        limit: Int = 5_000,
        policy: ActivityPolicy? = nil
    ) throws -> [ActivitySpan] {
        let excluded = policy.map { Array($0.effectiveExcludedBundleIDs) } ?? []
        return try dbQueue.read { db in
            try Self.fetchSpans(
                db,
                predicate: "started_at >= ? AND started_at <= ?",
                arguments: [from, to],
                excluded: excluded,
                order: "started_at ASC",
                limit: limit
            )
        }
    }

    /// Spans OVERLAPPING the window — the shape every rollup needs. A span that
    /// began yesterday and ran into today belongs to today's buckets for the
    /// part that lands in them; `querySpans`'s `started_at BETWEEN` filter drops
    /// it entirely and silently under-reports the morning.
    public func spansOverlapping(
        from: Double,
        to: Double,
        limit: Int = 20_000,
        policy: ActivityPolicy? = nil
    ) throws -> [ActivitySpan] {
        let excluded = policy.map { Array($0.effectiveExcludedBundleIDs) } ?? []
        return try dbQueue.read { db in
            try Self.fetchSpans(
                db,
                predicate: "started_at <= ? AND COALESCE(ended_at, last_seen_at) >= ?",
                arguments: [to, from],
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
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func stats(
        from: Double,
        to: Double,
        policy: ActivityPolicy? = nil
    ) throws -> ActivityStats {
        // QUERY-TIME FILTER applies to aggregates too. A count that includes an
        // app the user just excluded is still an answer about that app.
        let excluded = policy.map { Array($0.effectiveExcludedBundleIDs) } ?? []
        // Explicitly NUMBERED placeholders (?3, ?4, …). The window predicate
        // already uses ?1/?2 twice each; mixing bare `?` into a statement that
        // reuses numbered ones is a silent-misbinding trap.
        let exclusionClause = excluded.isEmpty
            ? ""
            : "AND bundle_id NOT IN ("
                + (0..<excluded.count).map { "?\($0 + 3)" }.joined(separator: ", ")
                + ")"
        return try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                -- OVERLAP, not "starts inside" (gpt-5.5 IMPORTANT, 2026-08-14).
                -- A span that began before `from` and ran into the window was
                -- being dropped entirely, and one that ran past `to` counted its
                -- whole duration. Both skew the events/hour number that is v0's
                -- entire reason to exist.
                --
                -- The denominator is the summed OBSERVED span time, clamped to
                -- the window -- NOT first-start-to-last-end. The old denominator
                -- swallowed every lock, sleep and idle gap between spans, so a
                -- laptop shut for eight hours between two spans reported a rate
                -- ~8x too low. Observed-time gives "AX callbacks per hour of
                -- ACTIVE use", which is the number the capture design needs.
                -- Events are PRORATED by the same overlap fraction that clamps
                -- the denominator (gpt-5.5 IMPORTANT, 2026-08-14). Clamping only
                -- the seconds was an asymmetry: a 2 h span carrying 100 events,
                -- queried over its first 5 minutes, reported all 100 events
                -- against 300 observed seconds = 1200 events/hour. Prorating
                -- both halves of the ratio keeps the rate stable regardless of
                -- where the window edges fall.
                SELECT COUNT(*) AS spans,
                       CAST(ROUND(COALESCE(SUM(
                           event_count * CASE
                               WHEN COALESCE(ended_at, last_seen_at) > started_at
                               THEN MAX(0,
                                        MIN(COALESCE(ended_at, last_seen_at), ?2)
                                        - MAX(started_at, ?1))
                                    / (COALESCE(ended_at, last_seen_at) - started_at)
                               ELSE 1.0
                           END
                       ), 0)) AS INTEGER) AS events,
                       COUNT(DISTINCT bundle_id) AS apps,
                       COALESCE(SUM(
                           MAX(0,
                               MIN(COALESCE(ended_at, last_seen_at), ?2)
                               - MAX(started_at, ?1))
                       ), 0) AS observed
                FROM activity_span
                WHERE started_at <= ?2
                  AND COALESCE(ended_at, last_seen_at) >= ?1
                  \(exclusionClause)
                """,
                arguments: StatementArguments([from, to] as [DatabaseValueConvertible] + excluded)
            )
            let spans: Int = row?["spans"] ?? 0
            let events: Int = row?["events"] ?? 0
            let apps: Int = row?["apps"] ?? 0
            // Boundary approximation, stated honestly: a span straddling the
            // window edge contributes its full `event_count` against its
            // clamped duration. Spans are minute-scale and windows are day-scale,
            // so the edge effect is negligible; splitting would require
            // per-event rows, which v0 deliberately does not keep.
            let wall: Double = max(0, row?["observed"] ?? 0)
            return ActivityStats(
                from: from,
                to: to,
                totalSpans: spans,
                totalEvents: events,
                distinctApps: apps,
                wallClockSeconds: wall
            )
        }
    }

    /// Column names actually present in `activity_span`. Used by the schema
    /// guard test that proves no column carries a window title.
    public func columnNames() throws -> [String] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(activity_span)")
                .compactMap { $0["name"] as String? }
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

extension ActivitySpanStore {
    /// The journal mode actually in force. Read by the retro-delete test so the
    /// WAL-sidecar assertion cannot pass vacuously on a database that turned out
    /// not to be in WAL mode at all.
    public func journalMode() throws -> String {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
    }
}
