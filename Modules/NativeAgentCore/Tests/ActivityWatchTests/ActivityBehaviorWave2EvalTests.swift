import Foundation
import Testing
@testable import ActivityWatch

@Suite("Activity behavior wave 2")
struct ActivityBehaviorWave2EvalTests {
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-behavior-wave2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    @Test("Browser title consent applies to every shipped browser identifier")
    func browserIDsUseSeparateTitleConsent() {
        var policy = ActivityPolicy(captureEnabled: true, captureTitles: true, browserTitlesEnabled: false)
        #expect(!ActivityPolicy.browserBundleIDs.isEmpty)
        for id in ActivityPolicy.browserBundleIDs {
            #expect(!policy.allowsTitleCapture(bundleID: id), "browser \(id) bypassed its explicit consent")
        }
        policy.browserTitlesEnabled = true
        for id in ActivityPolicy.browserBundleIDs {
            #expect(policy.allowsTitleCapture(bundleID: id), "browser \(id) remained incorrectly suppressed")
        }
        #expect(policy.allowsTitleCapture(bundleID: "com.example.editor"))
    }

    @Test("Fresh watcher status and lifecycle are honest while capture is disabled")
    func disabledWatcherReportsNoCaptureState() async throws {
        let store = try ActivitySpanStore(dataRoot: root())
        let watcher = ActivityWatcher(store: store, policy: ActivityPolicy())
        let status = watcher.status()
        #expect(watcher.lifecycleState == .stopped)
        #expect(!watcher.isCapturing)
        #expect(status.spansOpened == 0)
        #expect(status.eventsRecorded == 0)
        #expect(status.titlesCaptured == 0)
        #expect(status.currentApp == nil)
        #expect(!status.isPaused)
        #expect(!status.isLocked)
        await watcher.stop()
    }

    @Test("Persisted timezone offset survives a real SQLite round trip")
    func timezoneOffsetRoundTripsThroughStore() async throws {
        let store = try ActivitySpanStore(dataRoot: root())
        try await store.openSpan(ActivitySpan(
            startedAt: 1_700_000_000, endedAt: 1_700_000_030, lastSeenAt: 1_700_000_030,
            bundleId: "com.example.time", appName: "Time", eventCount: 1,
            closeReason: .idle, tzOffsetMin: 330
        ))
        let rows = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude)
        #expect(rows.count == 1)
        #expect(rows[0].tzOffsetMin == 330)
    }

    @Test("Sub-second evidence remains visible in the actual answer bundle")
    func subSecondRowIsNotRoundedAway() async throws {
        let store = try ActivitySpanStore(dataRoot: root())
        try await store.openSpan(ActivitySpan(
            startedAt: 1_700_000_000, endedAt: 1_700_000_000.5, lastSeenAt: 1_700_000_000.5,
            bundleId: "com.example.short", appName: "Short", eventCount: 0,
            closeReason: .quit, tzOffsetMin: 0
        ))
        let bundle = try await ActivityRollups(
            store: store, policy: ActivityPolicy(captureEnabled: true)
        ).answerBundle(
            from: 1_699_999_999, to: 1_700_000_001,
            timezone: TimeZone(secondsFromGMT: 0)!, rowCap: 12
        )
        #expect(bundle.topApps.rows.first?.seconds == 0.5)
        #expect(bundle.exemplars.first?.duration == 0.5)
    }

    // REPORTS-ONLY -> executable boundary checks (Wave 1):
    // core.activity / activity.answer.subSecondRowShare
    @Test("Sub-second spans keep their fractional share when a longer peer exists")
    func subSecondShareSurvivesMixedDurationAnswer() async throws {
        let store = try ActivitySpanStore(dataRoot: root())
        for (id, seconds) in [("short", 0.25), ("long", 0.75)] {
            try await store.openSpan(ActivitySpan(
                id: id, startedAt: 1_700_000_000, endedAt: 1_700_000_000 + seconds,
                lastSeenAt: 1_700_000_000 + seconds, bundleId: "com.example.\(id)",
                appName: id, eventCount: 1, closeReason: .idle, tzOffsetMin: 0
            ))
        }
        let answer = try await ActivityRollups(
            store: store, policy: ActivityPolicy(captureEnabled: true)
        ).answerBundle(
            from: 1_699_999_999, to: 1_700_000_002,
            timezone: TimeZone(secondsFromGMT: 0)!, rowCap: 12
        )
        #expect(answer.topApps.rows.map(\.seconds).reduce(0, +) == 1)
        #expect(answer.topApps.rows.contains(where: { $0.seconds == 0.25 }))
    }

    // REPORTS-ONLY -> executable boundary checks (Wave 1):
    // core.activity / activity.watcher.status
    // core.activity / activity.watcher.lifecycleState
    @Test("Disabled watcher remains stopped after control calls and writes no history")
    func disabledWatcherCannotBecomeAnApparentlyLiveRecorder() async throws {
        let store = try ActivitySpanStore(dataRoot: root())
        let watcher = ActivityWatcher(store: store, policy: ActivityPolicy(captureEnabled: false))
        watcher.pause()
        watcher.resume()
        watcher.updatePolicy(ActivityPolicy(captureEnabled: false, captureTitles: true))
        #expect(watcher.lifecycleState == .stopped)
        #expect(!watcher.isCapturing)
        #expect(watcher.status().currentApp == nil)
        #expect(try await store.querySpans(from: 0, to: .greatestFiniteMagnitude).isEmpty)
        await watcher.stop()
    }

    // REPORTS-ONLY -> executable boundary check (Wave 1):
    // core.activity / activity.retention.defaultInterval
    @Test("Retention uses the injected interval and persists the next due boundary")
    func retentionIntervalDoesNotRunEarlyButRunsAtTheExactBoundary() async throws {
        let root = try root()
        let store = try ActivitySpanStore(dataRoot: root)
        let runner = ActivityRetentionRunner(dataRoot: root, interval: 60)
        let policy = ActivityPolicy(captureEnabled: true, retentionDays: 1)
        let first = try await runner.runIfDue(store: store, policy: policy, now: 1_700_000_000)
        let early = try await runner.runIfDue(store: store, policy: policy, now: 1_700_000_059)
        let boundary = try await runner.runIfDue(store: store, policy: policy, now: 1_700_000_060)
        #expect(first.ran)
        #expect(!early.ran)
        #expect(boundary.ran)
        #expect(boundary.nextDueAt == 1_700_000_120)
    }

    // REPORTS-ONLY -> executable boundary check (Wave 1):
    // core.activity / activity.store.sqlitePragmas
    @Test("Activity store opens in WAL mode and preserves data across a fresh handle")
    func sqliteStoreUsesDurableWALAcrossRealHandles() async throws {
        let dataRoot = try root()
        let first = try ActivitySpanStore(dataRoot: dataRoot)
        #expect(try await first.journalMode().lowercased() == "wal")
        try await first.openSpan(ActivitySpan(
            id: "durable", startedAt: 1_700_000_000, endedAt: 1_700_000_001,
            lastSeenAt: 1_700_000_001, bundleId: "com.example.durable", appName: "Durable",
            eventCount: 1, closeReason: .idle, tzOffsetMin: 0
        ))
        let reloaded = try ActivitySpanStore(dataRoot: dataRoot)
        #expect(try await reloaded.journalMode().lowercased() == "wal")
        #expect(try await reloaded.querySpans(
            from: 1_699_999_999, to: 1_700_000_002
        ).map(\.id) == ["durable"])
    }
}
