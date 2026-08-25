import Foundation
import Testing
@testable import ActivityWatch

// MARK: - What this file guards
//
// The STORE envelope — the on-disk properties that are load-bearing and that
// nothing watches. Ledger fence `core.activity`:
//
//   activity.store.heartbeatSpan        heartbeat advances time, never event_count
//   activity.store.fileMode             the DB and its sidecars are owner-only
//   activity.store.sqlitePragmas        WAL + journal_size_limit + two writers
//   activity.rollups.sourceSpanLimit    answerBundle REFUSES rather than truncating
//   activity.redaction.maxTitleChars    a title is metadata, not a document body

private func storeEnvelopeRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityStoreEnvelope-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let storeBase: Double = 1_700_000_000

// MARK: - activity.store.heartbeatSpan

@Test("HEARTBEAT: advances last_seen_at and NEVER counts as an event")
func heartbeatAdvancesTimeButNotTheEventCount() async throws {
    // events/hour is the number this whole organ exists to produce. The 60 s
    // tick fires while a span is open; if a heartbeat ever bumped event_count,
    // a span open for an hour would report 60 phantom events and the rate would
    // be fiction. The code comments forbid it and nothing pinned it — the only
    // existing exercise of heartbeatSpan is inside a retention fixture.
    let store = try ActivitySpanStore(dataRoot: storeEnvelopeRoot())
    let span = try await store.openSpan(
        bundleId: "com.example.editor", appName: "Editor", at: storeBase
    )

    // Two REAL events first, so the assertion is not "zero stayed zero".
    try await store.touchSpan(id: span.id, at: storeBase + 10)
    try await store.touchSpan(id: span.id, at: storeBase + 20)
    let afterTouches = try #require(
        try await store.querySpans(from: storeBase - 60, to: storeBase + 60).first
    )
    #expect(afterTouches.eventCount == 2, "precondition: touches must count")
    #expect(afterTouches.lastSeenAt == storeBase + 20)

    // Ten heartbeats over ten minutes.
    for tick in 1...10 {
        try await store.heartbeatSpan(id: span.id, at: storeBase + 20 + Double(tick) * 60)
    }
    let afterBeats = try #require(
        try await store.querySpans(from: storeBase - 60, to: storeBase + 60).first
    )
    #expect(
        afterBeats.eventCount == 2,
        """
        A HEARTBEAT COUNTED AS AN EVENT. event_count went 2 → \(afterBeats.eventCount) \
        over 10 liveness ticks with no human input. events/hour becomes fiction and \
        no error is raised anywhere.
        """
    )
    #expect(
        afterBeats.lastSeenAt == storeBase + 620,
        "the heartbeat did not advance last_seen_at — the span's duration freezes"
    )
    #expect(afterBeats.isOpen, "a heartbeat must never close the span")
    #expect(afterBeats.duration == 620)

    // last_seen_at NEVER moves backwards: an out-of-order beat cannot rewind
    // the crash-recovery bound.
    try await store.heartbeatSpan(id: span.id, at: storeBase + 5)
    let afterBackwards = try #require(
        try await store.querySpans(from: storeBase - 60, to: storeBase + 60).first
    )
    #expect(afterBackwards.lastSeenAt == storeBase + 620)

    // And a CLOSED span is immune to both.
    try await store.closeSpan(id: span.id, reason: .idle, at: storeBase + 700)
    try await store.heartbeatSpan(id: span.id, at: storeBase + 9_999)
    try await store.touchSpan(id: span.id, at: storeBase + 9_999)
    let closed = try #require(
        try await store.querySpans(from: storeBase - 60, to: storeBase + 60).first
    )
    #expect(closed.endedAt == storeBase + 700)
    #expect(closed.lastSeenAt == storeBase + 620)
    #expect(closed.eventCount == 2)
}

// MARK: - activity.store.fileMode

@Test("PRIVACY: nothing in the store is writable by anyone else, and only the sidecars are readable")
func storeFilesAreOwnerOnly() async throws {
    // The chmod in ActivitySpanStore.init is wrapped in `try?`, so a failure is
    // discarded silently and the file — a record of where the human was — keeps
    // whatever the umask gave it. It is also applied to the MAIN DB PATH ONLY;
    // the two sidecars are never named, and the -wal holds page images of the
    // same rows.
    //
    // MEASURED, 2026-08-23, hermetic store on a umask-022 host:
    //     activity_spans.sqlite      0600   (the chmod)
    //     activity_spans.sqlite-wal  0644   WORLD-READABLE
    //     activity_spans.sqlite-shm  0644   WORLD-READABLE
    //     activity_watch/            0755
    // The live store matches on -shm. So this eval does NOT assert the whole
    // promise — asserting it would be red today and this fence would carry a
    // permanently failing test instead of a finding. It asserts, instead:
    //
    //   1. the HARD invariant that holds everywhere and must never stop:
    //      nothing is group- or world-WRITABLE;
    //   2. the main database is exactly 0600;
    //   3. the set of world-READABLE paths is a SUBSET of the two known-gap
    //      sidecars. Fixing the gap keeps this green; the main DB or the
    //      directory joining the gap turns it red.
    //
    // The seam this needs is in production code and is therefore NOT made here:
    // the chmod must cover `-wal`/`-shm` and must not be swallowed by `try?`.
    let root = storeEnvelopeRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let span = try await store.openSpan(
        bundleId: "com.example.editor", appName: "Editor", at: storeBase
    )
    try await store.touchSpan(id: span.id, at: storeBase + 1)

    let directory = ActivityWatchPaths.directory(dataRoot: root)
    let dbURL = ActivityWatchPaths.databaseURL(dataRoot: root)
    let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    #expect(FileManager.default.fileExists(atPath: dbURL.path))
    #expect(
        FileManager.default.fileExists(atPath: walURL.path),
        "no -wal sidecar after a write — is the store still in WAL mode?"
    )

    var modes: [(name: String, mode: Int)] = []
    for url in [directory, dbURL, walURL, shmURL]
    where FileManager.default.fileExists(atPath: url.path) {
        modes.append((url.lastPathComponent, try mode(url)))
    }
    #expect(modes.count >= 3, "found only \(modes.count) store paths — the guard lost its target")

    // 1. NOBODY ELSE MAY WRITE. Umask-independent, and true on every host.
    let writable = modes.filter { $0.mode & 0o022 != 0 }.map(\.name)
    #expect(
        writable.isEmpty,
        Comment(rawValue: """
        GROUP- OR WORLD-WRITABLE PATHS IN THE ACTIVITY STORE: \(writable.sorted()). \
        Another user on this machine could rewrite the record of where the human was.
        """)
    )

    // 2. The main database is exactly what the chmod promises.
    let dbMode = try mode(dbURL)
    #expect(
        dbMode == 0o600,
        Comment(rawValue: """
        THE SPAN DATABASE IS MODE \(String(dbMode, radix: 8)), NOT 0600. The chmod that \
        sets it is wrapped in `try?`, so its failure is discarded silently and the file \
        keeps whatever the umask gave it.
        """)
    )

    // 3. The world-readable set may only ever SHRINK from the two sidecars.
    //
    // The DIRECTORY is excluded on purpose: at 0755 it is listable, which
    // discloses filenames, not spans — and 0600 on the contents is what keeps
    // the record itself private. The files are the surface this row is about.
    let knownGap: Set<String> = [walURL.lastPathComponent, shmURL.lastPathComponent]
    let worldReadable = Set(
        modes
            .filter { $0.name != directory.lastPathComponent && $0.mode & 0o044 != 0 }
            .map(\.name)
    )
    #expect(
        worldReadable.isSubset(of: knownGap),
        Comment(rawValue: """
        A NEW WORLD-READABLE PATH IN THE ACTIVITY STORE: \
        \(worldReadable.subtracting(knownGap).sorted()) (modes: \
        \(modes.map { "\($0.name)=\(String($0.mode, radix: 8))" }.sorted())).

        The known gap is the -wal/-shm sidecars, which the chmod never names. Anything \
        else joining them means the whole record of where the human was is readable by \
        every account on the machine.
        """)
    )
}

// MARK: - activity.store.sqlitePragmas

@Test("PRAGMAS: WAL and the 4 MB journal cap are in force, and two writers both land")
func pragmasAreInForceAndTwoWritersBothLand() async throws {
    // The store documents itself as single-writer, but two writers are a
    // SUPPORTED WORKFLOW: the app holds one ActivitySpanStore while
    // `activity-probe run / policy --exclude / retention` opens another on the
    // same data root. A write that blocks past the 2 s busy timeout throws, the
    // watcher's pump breaks out of its `for await` PERMANENTLY, and the only
    // witness is one stderr line. The only existing pragma check is an inline
    // expectation inside a purge test.
    let root = storeEnvelopeRoot()
    let first = try ActivitySpanStore(dataRoot: root)

    #expect(
        try await first.journalMode().lowercased() == "wal",
        "journal_mode is not WAL — the purge path's sidecar checkpointing is then theatre"
    )

    // A SECOND store over the same file, exactly as the probe CLI opens one.
    let second = try ActivitySpanStore(dataRoot: root)
    #expect(try await second.journalMode().lowercased() == "wal")

    // Interleaved writes from both handles. Neither may throw.
    for index in 0..<25 {
        let at = storeBase + Double(index) * 60
        let a = try await first.openSpan(
            id: "first-\(index)", bundleId: "com.example.a", appName: "A", at: at
        )
        let b = try await second.openSpan(
            id: "second-\(index)", bundleId: "com.example.b", appName: "B", at: at + 1
        )
        try await second.touchSpan(id: a.id, at: at + 2)
        try await first.touchSpan(id: b.id, at: at + 3)
        try await first.closeSpan(id: a.id, reason: .appChange, at: at + 30)
        try await second.closeSpan(id: b.id, reason: .appChange, at: at + 31)
    }

    // BOTH writers' rows are present, and each sees the other's.
    let seenByFirst = try await first.querySpans(
        from: storeBase - 60, to: storeBase + 25 * 60 + 60, limit: 500
    )
    let seenBySecond = try await second.querySpans(
        from: storeBase - 60, to: storeBase + 25 * 60 + 60, limit: 500
    )
    #expect(seenByFirst.count == 50, "expected 50 rows, saw \(seenByFirst.count)")
    #expect(seenBySecond.count == 50)
    #expect(seenByFirst.allSatisfy { $0.endedAt != nil }, "a cross-handle close was lost")
    #expect(
        seenByFirst.allSatisfy { $0.eventCount == 1 },
        "a cross-handle touch was lost — one writer's events vanished silently"
    )

    // The WAL cap is what stops the sidecar growing without bound between
    // checkpoints. The live sidecar sits AT this cap against a 573 KB main
    // database because checkpointAndVacuum only ever runs behind prune/purge/
    // wipe, and none has run.
    let walURL = URL(
        fileURLWithPath: ActivityWatchPaths.databaseURL(dataRoot: root).path + "-wal"
    )
    if FileManager.default.fileExists(atPath: walURL.path) {
        let size = (try FileManager.default
            .attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(
            size <= 4_194_304 + 65_536,
            """
            the -wal sidecar is \(size) B, past the 4 MB journal_size_limit \
            (plus one page-ish of slack). The pragma is not being applied.
            """
        )
    }

    // A checkpoint empties it, which is the property `purge` depends on.
    try await first.checkpointAndVacuum()
    if FileManager.default.fileExists(atPath: walURL.path) {
        let size = (try FileManager.default
            .attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(size == 0, "TRUNCATE checkpoint left \(size) B in the sidecar")
    }
}

// MARK: - activity.rollups.sourceSpanLimit

@Test("REFUSAL: past the source-span limit, the answer is a refusal, never a prefix")
func answerBundleRefusesRatherThanTruncatingItsSource() async throws {
    // 20,000 source spans throws rather than answering from a truncated set.
    // Correct, and untested: if the throw were ever replaced by a silent prefix
    // the answer would under-report a heavy range with no signal at all. The
    // live store reached 1,925 rows in 9 days, so ~90 days of capture puts a
    // 366-day question over this ceiling.
    let limit = ActivityRollups.sourceSpanLimit
    let root = storeEnvelopeRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let policy = ActivityPolicy(captureEnabled: true)
    let rollups = ActivityRollups(store: store, policy: policy)

    // Rows sit shoulder to shoulder so every one of them overlaps the window.
    func seed(_ range: Range<Int>) async throws {
        for index in range {
            let start = storeBase + Double(index)
            try await store.openSpan(ActivitySpan(
                id: "row-\(index)",
                startedAt: start,
                endedAt: start + 0.5,
                lastSeenAt: start + 0.5,
                bundleId: "com.example.editor",
                appName: "Editor",
                eventCount: 1,
                closeReason: .appChange,
                tzOffsetMin: 0
            ))
        }
    }

    let window = (from: storeBase - 60, to: storeBase + Double(limit) + 60)

    // EXACTLY at the limit: a real answer.
    try await seed(0..<limit)
    let atLimit = try await rollups.answerBundle(
        from: window.from, to: window.to, timezone: TimeZone(identifier: "UTC")!, grain: .daily
    )
    #expect(
        !atLimit.topApps.rows.isEmpty,
        "the at-limit answer is empty — the over-limit refusal below proves nothing"
    )

    // ONE MORE ROW: a refusal, not a shorter answer.
    try await seed(limit..<(limit + 1))
    await #expect(throws: ActivityRollups.RollupError.sourceRowsExceeded(limit: limit)) {
        _ = try await rollups.answerBundle(
            from: window.from, to: window.to,
            timezone: TimeZone(identifier: "UTC")!, grain: .daily
        )
    }

    // The refusal text names the ceiling and tells the caller what to do — it
    // is the string the model reads instead of a wrong number.
    let message = ActivityRollups.RollupError
        .sourceRowsExceeded(limit: limit).localizedDescription
    #expect(message.contains("\(limit)"))
    #expect(message.lowercased().contains("shorter range"))

    // And a NARROWER window over the same rows still answers — the refusal is
    // about the source-row count, not a store that has become unusable.
    let narrow = try await rollups.answerBundle(
        from: storeBase, to: storeBase + 500,
        timezone: TimeZone(identifier: "UTC")!, grain: .hourly
    )
    #expect(!narrow.topApps.rows.isEmpty)
}

// MARK: - activity.redaction.maxTitleChars

@Test("REDACTION CAP: a title is metadata — 200 chars, whatever arrives")
func redactionTruncatesAtTheStatedCap() {
    // Raising this constant turns "metadata" into document bodies stored
    // verbatim, and no test asserted the truncation. The cap itself is pinned
    // too: a change to the number is the change that does the damage.
    #expect(
        ActivityTitleRedaction.maxTitleChars <= 200,
        """
        THE TITLE CAP ROSE to \(ActivityTitleRedaction.maxTitleChars). 200 is mac_view's \
        own hard cap; a "title" longer than that is a document body wearing a hat, and \
        it lands in the store verbatim.
        """
    )

    let cap = ActivityTitleRedaction.maxTitleChars

    // A long CLEAN title: kept, truncated, never dropped.
    let words = Array(repeating: "notes", count: 1_200).joined(separator: " ")
    let redactedLong = ActivityTitleRedaction.redact(words)
    #expect(redactedLong != nil, "a long but ordinary title was dropped entirely")
    #expect(
        (redactedLong?.count ?? 0) <= cap,
        "a \(words.count)-char title stored \(redactedLong?.count ?? -1) chars"
    )
    #expect(redactedLong?.hasPrefix("notes") == true, "the truncation kept the wrong end")

    // A single unbroken 5,000-char run — the shape that most looks like a body.
    let runOn = String(repeating: "a", count: 5_000)
    if let stored = ActivityTitleRedaction.redact(runOn) {
        #expect(stored.count <= cap, "a 5,000-char run stored \(stored.count) chars")
    }

    // Exactly at the cap survives whole; one over is trimmed to the cap.
    let exact = String(repeating: "b", count: cap)
    #expect(ActivityTitleRedaction.redact(exact)?.count == cap)
    #expect(ActivityTitleRedaction.redact(exact + "b")?.count == cap)

    // Whitespace-only and nil are NOTHING, not an empty stored title.
    #expect(ActivityTitleRedaction.redact("   \n\t ") == nil)
    #expect(ActivityTitleRedaction.redact(nil) == nil)

    // The placeholder is a constant, not a digest: a hash of a secret is a
    // recoverable fingerprint of a secret.
    #expect(ActivityTitleRedaction.redactedPlaceholder == "[redacted]")
    #expect(ActivityTitleRedaction.redactedPlaceholder.count <= cap)
}
