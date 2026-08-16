import Foundation
import GRDB
import Testing
@testable import ActivityWatch

// MARK: - Hermeticity
//
// `ActivitySpanStore(dataRoot:)` writes a real SQLite file. A bare or
// unpinned construction under `swift test` would land in the user's LIVE data
// root (see TrustCenterTests/HermeticTrustSupport.swift for the same
// convention and the same reason). EVERY store in this target is pinned to a
// fresh, unique temp directory.

private func hermeticDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityWatchTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func hermeticStore() throws -> ActivitySpanStore {
    try ActivitySpanStore(dataRoot: hermeticDataRoot())
}

/// Fixed base instant so no test depends on the wall clock.
private let base: Double = 1_700_000_000

@Test("open then close persists endedAt and closeReason")
func spanLifecyclePersists() async throws {
    let store = try hermeticStore()
    let span = try await store.openSpan(
        bundleId: "com.apple.Terminal", appName: "Terminal", at: base
    )

    let open = try await store.querySpans(from: base - 60, to: base + 60)
    #expect(open.count == 1)
    #expect(open[0].endedAt == nil)
    #expect(open[0].closeReason == nil)
    #expect(open[0].isOpen)

    try await store.closeSpan(id: span.id, reason: .appChange, at: base + 120)

    let closed = try await store.querySpans(from: base - 60, to: base + 60)
    #expect(closed.count == 1)
    #expect(closed[0].endedAt == base + 120)
    #expect(closed[0].closeReason == .appChange)
    #expect(closed[0].duration == 120)
}

@Test("reconcileAbandonedSpans closes at last_seen_at, not now")
func reconcileClosesAtLastSeen() async throws {
    let store = try hermeticStore()
    // An open row whose last_seen_at is deliberately in the past: this is the
    // shape a crash / force-quit / power loss leaves behind.
    let lastSeen = base + 300
    let span = ActivitySpan(
        startedAt: base,
        endedAt: nil,
        lastSeenAt: lastSeen,
        bundleId: "com.apple.Safari",
        appName: "Safari",
        eventCount: 7,
        closeReason: nil
    )
    try await store.openSpan(span)

    let count = try await store.reconcileAbandonedSpans()
    #expect(count == 1)

    let rows = try await store.querySpans(from: base - 60, to: base + 60)
    #expect(rows.count == 1)
    // The whole point: closed AT last_seen_at, not at "now". A crash must not
    // invent the hours between the crash and the next launch.
    #expect(rows[0].endedAt == lastSeen)
    #expect(rows[0].closeReason == .abandoned)
    #expect(rows[0].endedAt != Date().timeIntervalSince1970)

    // Idempotent: a second pass has nothing left to close.
    #expect(try await store.reconcileAbandonedSpans() == 0)
}

@Test("touchSpan advances last_seen_at and increments event_count")
func touchAdvancesLastSeenAndCount() async throws {
    let store = try hermeticStore()
    let span = try await store.openSpan(
        bundleId: "com.apple.dt.Xcode", appName: "Xcode", at: base
    )

    try await store.touchSpan(id: span.id, at: base + 10)
    try await store.touchSpan(id: span.id, at: base + 25)

    var rows = try await store.querySpans(from: base - 60, to: base + 60)
    #expect(rows[0].lastSeenAt == base + 25)
    #expect(rows[0].eventCount == 2)

    // last_seen_at never rewinds on an out-of-order handoff.
    try await store.touchSpan(id: span.id, at: base + 5)
    rows = try await store.querySpans(from: base - 60, to: base + 60)
    #expect(rows[0].lastSeenAt == base + 25)
    #expect(rows[0].eventCount == 3)

    // A heartbeat moves last_seen_at WITHOUT inflating the event count —
    // events/hour is the number v0 exists to measure.
    try await store.heartbeatSpan(id: span.id, at: base + 90)
    rows = try await store.querySpans(from: base - 60, to: base + 120)
    #expect(rows[0].lastSeenAt == base + 90)
    #expect(rows[0].eventCount == 3)
}

@Test("prune deletes rows older than the window and keeps newer ones")
func pruneRespectsWindow() async throws {
    let store = try hermeticStore()
    let now = base + 30 * 86_400

    // The default retention window is 30 d (W10). One row on each side of it.
    let stale = ActivitySpan(
        startedAt: now - 31 * 86_400,
        endedAt: now - 31 * 86_400 + 60,
        lastSeenAt: now - 31 * 86_400 + 60,
        bundleId: "com.old.app", appName: "Old", eventCount: 1, closeReason: .idle
    )
    let fresh = ActivitySpan(
        startedAt: now - 3 * 86_400,
        endedAt: now - 3 * 86_400 + 60,
        lastSeenAt: now - 3 * 86_400 + 60,
        bundleId: "com.new.app", appName: "New", eventCount: 1, closeReason: .idle
    )
    try await store.openSpan(stale)
    try await store.openSpan(fresh)

    let deleted = try await store.prune(now: now)
    #expect(deleted == 1)

    let rows = try await store.querySpans(from: 0, to: now)
    #expect(rows.count == 1)
    #expect(rows[0].bundleId == "com.new.app")
}

@Test("wipeAll empties the table")
func wipeEmptiesTable() async throws {
    let store = try hermeticStore()
    for index in 0..<5 {
        try await store.openSpan(
            bundleId: "com.app.\(index)", appName: "App\(index)", at: base + Double(index)
        )
    }
    #expect(try await store.querySpans(from: 0, to: base + 1000).count == 5)

    let deleted = try await store.wipeAll()
    #expect(deleted == 5)
    #expect(try await store.querySpans(from: 0, to: base + 1000).isEmpty)
    let stats = try await store.stats(from: 0, to: base + 1000)
    #expect(stats.totalSpans == 0)
    #expect(stats.eventsPerHour == 0)
}

@Test("stats computes events per hour over a known fixture")
func statsEventsPerHourKnownAnswer() async throws {
    let store = try hermeticStore()
    // Fixture with a hand-computable answer: two back-to-back half-hour spans,
    // 10 + 20 events, covering exactly one wall-clock hour → 30 events/hour.
    try await store.openSpan(ActivitySpan(
        startedAt: base, endedAt: base + 1800, lastSeenAt: base + 1800,
        bundleId: "com.apple.Terminal", appName: "Terminal",
        eventCount: 10, closeReason: .appChange
    ))
    try await store.openSpan(ActivitySpan(
        startedAt: base + 1800, endedAt: base + 3600, lastSeenAt: base + 3600,
        bundleId: "com.apple.Safari", appName: "Safari",
        eventCount: 20, closeReason: .idle
    ))

    let stats = try await store.stats(from: base - 1, to: base + 3600)
    #expect(stats.totalSpans == 2)
    #expect(stats.totalEvents == 30)
    #expect(stats.distinctApps == 2)
    #expect(stats.wallClockSeconds == 3600)
    #expect(abs(stats.eventsPerHour - 30) < 0.000_1)

    // REGRESSION (gpt-5.5 IMPORTANT, 2026-08-14): an idle/lock GAP must not
    // dilute the rate. The denominator is summed OBSERVED span time, not
    // first-start-to-last-end. Add a zero-length span an hour later: the
    // intervening hour is time User was not at the machine, so events/hour must
    // stay 30. The previous implementation reported 15 — it counted the gap as
    // observed time, which is exactly how a laptop shut overnight would have
    // made the capture rate look an order of magnitude too low.
    try await store.openSpan(ActivitySpan(
        startedAt: base + 7200, endedAt: base + 7200, lastSeenAt: base + 7200,
        bundleId: "com.apple.Safari", appName: "Safari",
        eventCount: 0, closeReason: .idle
    ))
    let wide = try await store.stats(from: base - 1, to: base + 7200)
    #expect(wide.wallClockSeconds == 3600)
    #expect(abs(wide.eventsPerHour - 30) < 0.000_1)
}

@Test("stats includes a span that straddles the window start, clamped")
func statsIncludesStraddlingSpan() async throws {
    let store = try hermeticStore()
    // Span runs from 30 min BEFORE the window start to 30 min after it.
    // The old `started_at >= from` filter dropped it entirely — an app open
    // across midnight vanished from the day's numbers.
    try await store.openSpan(ActivitySpan(
        startedAt: base - 1800, endedAt: base + 1800, lastSeenAt: base + 1800,
        bundleId: "com.apple.Terminal", appName: "Terminal",
        eventCount: 60, closeReason: .appChange
    ))

    let stats = try await store.stats(from: base, to: base + 3600)
    #expect(stats.totalSpans == 1)                  // included, not dropped
    #expect(stats.wallClockSeconds == 1800)         // clamped to the window
    // Events are PRORATED by the same overlap fraction as the seconds
    // (gpt-5.5 IMPORTANT, 2026-08-14). Half the span lies in the window, so
    // half its 60 events count against half its duration: 30 / 0.5 h = 60/h.
    // This assertion previously read 120/h, which is precisely the asymmetry
    // the review caught — clamping the denominator while leaving the numerator
    // whole doubles the rate for any span crossing a window edge.
    #expect(stats.totalEvents == 30)
    #expect(abs(stats.eventsPerHour - 60) < 0.000_1)
}

@Test("stats clamps a span that runs past the window end")
func statsClampsTrailingSpan() async throws {
    let store = try hermeticStore()
    try await store.openSpan(ActivitySpan(
        startedAt: base, endedAt: base + 7200, lastSeenAt: base + 7200,
        bundleId: "com.apple.Safari", appName: "Safari",
        eventCount: 100, closeReason: .appChange
    ))
    // Window covers only the first hour of a two-hour span.
    let stats = try await store.stats(from: base, to: base + 3600)
    #expect(stats.wallClockSeconds == 3600)
}

@Test("SCHEMA GUARD: the only title-ish column is title_redacted")
func schemaHasOnlyRedactedTitleColumn() async throws {
    let store = try hermeticStore()
    let columns = try await store.columnNames()
    #expect(columns == [
        "id", "started_at", "ended_at", "last_seen_at",
        "bundle_id", "app_name", "event_count", "close_reason", "tz_offset_min",
        "title_redacted",
    ])
    let titleish = columns.filter { $0.lowercased().contains("title") }
    #expect(
        titleish == ["title_redacted"],
        """
        REDACTION-AT-SOURCE PROOF FAILED: activity_span carries title-ish columns
        \(titleish). Exactly ONE is permitted, `title_redacted`, and it can only
        ever hold the output of ActivityTitleRedaction.redact. A column named
        anything else is a place a RAW title can be stored, and the name is the
        only thing standing between a future call site and doing exactly that.
        """
    )
}

@Test("RETRO-DELETE: purge removes the rows AND a later query cannot see them")
func purgeRemovesRowsAndSurvivesQuery() async throws {
    let store = try hermeticStore()
    let secret = "com.1password.1password"
    for index in 0..<4 {
        try await store.openSpan(ActivitySpan(
            startedAt: base + Double(index) * 100,
            endedAt: base + Double(index) * 100 + 60,
            lastSeenAt: base + Double(index) * 100 + 60,
            bundleId: index % 2 == 0 ? secret : "com.apple.Terminal",
            appName: index % 2 == 0 ? "1Password" : "Terminal",
            titleRedacted: index % 2 == 0 ? "Personal vault" : "zsh",
            eventCount: 3, closeReason: .appChange
        ))
    }
    #expect(try await store.querySpans(from: 0, to: base + 10_000).count == 4)

    let deleted = try await store.purge(bundleID: secret)
    #expect(deleted == 2)

    // (1) the rows are gone from the table…
    let rows = try await store.querySpans(from: 0, to: base + 10_000)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.bundleId != secret })

    // (2) …and no query path can see them, including the aggregate one.
    let stats = try await store.stats(from: 0, to: base + 10_000)
    #expect(stats.totalSpans == 2)
    #expect(stats.distinctApps == 1)

    // (3) …and the bytes are not sitting in the WAL sidecar. The store runs in
    // WAL mode, so a DELETE alone leaves the old pages legible in `-wal`;
    // `purge` checkpoints in TRUNCATE mode and then VACUUMs. Prove the sidecar
    // is actually empty rather than trusting that it happened.
    let dbPath = await store.databaseURL.path
    let journalMode = try await store.journalMode()
    #expect(journalMode.lowercased() == "wal", "not in WAL mode — this check proves nothing")
    let attributes = try? FileManager.default.attributesOfItem(
        atPath: dbPath + "-wal"
    )
    let walSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    #expect(walSize == 0, "WAL still holds \(walSize) bytes after a purge")
}

@Test("QUERY-TIME FILTER: excluding an app today makes yesterday unanswerable")
func queryTimeFilterHidesNewlyExcludedApp() async throws {
    let store = try hermeticStore()
    // Rows written BEFORE the exclusion existed — the retro-delete has not run.
    try await store.openSpan(ActivitySpan(
        startedAt: base, endedAt: base + 600, lastSeenAt: base + 600,
        bundleId: "com.bankofexample.app", appName: "Bank", eventCount: 5, closeReason: .idle
    ))
    try await store.openSpan(ActivitySpan(
        startedAt: base + 700, endedAt: base + 900, lastSeenAt: base + 900,
        bundleId: "com.apple.Terminal", appName: "Terminal", eventCount: 2, closeReason: .idle
    ))

    let unfiltered = try await store.querySpans(from: 0, to: base + 10_000)
    #expect(unfiltered.count == 2)

    let policy = ActivityPolicy(
        captureEnabled: true, excludedBundleIDs: ["com.bankofexample.app"]
    )
    let filtered = try await store.querySpans(from: 0, to: base + 10_000, policy: policy)
    #expect(filtered.count == 1)
    #expect(filtered[0].bundleId == "com.apple.Terminal")

    let overlapping = try await store.spansOverlapping(from: 0, to: base + 10_000, policy: policy)
    #expect(overlapping.count == 1)

    let stats = try await store.stats(from: 0, to: base + 10_000, policy: policy)
    #expect(stats.totalSpans == 1)
    #expect(stats.totalEvents == 2)
}

@Test("MIGRATION: a v0-shaped database migrates in place and keeps its rows")
func v0DatabaseMigratesInPlace() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityWatchMigration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbURL = root.appendingPathComponent("activity_probe.sqlite")

    // Build EXACTLY the v0 schema by hand — the shape a machine that ran the
    // dev probe before W5 has on disk right now — and stamp GRDB's migration
    // table so the v0 migration is recorded as already applied.
    try seedV0Database(at: dbURL)

    // Opening the store runs the migrator. It must ADD the column, not rebuild.
    let store = try ActivitySpanStore(databaseURL: dbURL)
    let columns = try await store.columnNames()
    #expect(columns.contains("title_redacted"))

    let rows = try await store.querySpans(from: 0, to: 1_800_000_000)
    #expect(rows.count == 1, "the v0 row was lost in migration")
    #expect(rows[0].id == "legacy-1")
    #expect(rows[0].eventCount == 9)
    #expect(rows[0].tzOffsetMin == -300)
    #expect(rows[0].titleRedacted == nil, "a pre-existing row has no title, and must not gain one")

    // And the migrated DB is fully writable at the new shape.
    _ = try await store.openSpan(
        bundleId: "com.apple.Safari", appName: "Safari",
        titleRedacted: "Example — Safari", at: 1_700_001_000
    )
    let after = try await store.querySpans(from: 0, to: 1_800_000_000)
    #expect(after.count == 2)
    #expect(after[1].titleRedacted == "Example — Safari")
}

@Test("lock gate: loginwindow is a lock signal, never a span")
func lockSignalDetection() {
    #expect(ActivityWatcher.isLockSignal(bundleId: "com.apple.loginwindow", localizedName: "loginwindow"))
    #expect(ActivityWatcher.isLockSignal(bundleId: "com.apple.loginwindow", localizedName: nil))
    #expect(ActivityWatcher.isLockSignal(bundleId: nil, localizedName: "loginwindow"))
    #expect(ActivityWatcher.isLockSignal(bundleId: nil, localizedName: nil))
    #expect(!ActivityWatcher.isLockSignal(bundleId: "com.apple.Terminal", localizedName: "Terminal"))
}

@Test("QUERY: bundle filter is applied before the source-row limit")
func bundleFilterPrecedesLimit() async throws {
    let store = try hermeticStore()
    for index in 0..<4 {
        try await store.openSpan(ActivitySpan(
            id: "other-\(index)", startedAt: base + Double(index),
            endedAt: base + Double(index) + 1, lastSeenAt: base + Double(index) + 1,
            bundleId: "com.example.other", appName: "Other", eventCount: 1,
            closeReason: .idle, tzOffsetMin: 0
        ))
    }
    try await store.openSpan(ActivitySpan(
        id: "wanted", startedAt: base + 10, endedAt: base + 11,
        lastSeenAt: base + 11, bundleId: "com.example.wanted", appName: "Wanted",
        eventCount: 1, closeReason: .idle, tzOffsetMin: 0
    ))

    let rows = try await store.spansOverlapping(
        from: base, to: base + 20, limit: 1,
        policy: ActivityPolicy(captureEnabled: true),
        bundleID: "com.example.wanted"
    )
    #expect(rows.map(\.id) == ["wanted"])
}

/// Writes a byte-accurate v0-era `activity_span` database, migration stamp and
/// all. Synchronous on purpose: inside an async test, GRDB's `write` resolves to
/// its async overload, and the point here is to build the file the OLD way.
private func seedV0Database(at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
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
            CREATE INDEX idx_activity_span_started_at ON activity_span (started_at);
            CREATE INDEX idx_activity_span_bundle_started
                ON activity_span (bundle_id, started_at);
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations (identifier) VALUES ('activity_span_v0');
            INSERT INTO activity_span
                (id, started_at, ended_at, last_seen_at, bundle_id, app_name,
                 event_count, close_reason, tz_offset_min)
            VALUES
                ('legacy-1', 1700000000, 1700000600, 1700000600,
                 'com.apple.Terminal', 'Terminal', 9, 'idle', -300);
            """)
    }
}
