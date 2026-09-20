import AppKit
import Foundation
import Testing
@testable import ActivityWatch

private func productionBoundaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityProductionBoundary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func activityRepositoryRoot() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("Modules").path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { break }
        directory = parent
    }
    throw CocoaError(.fileNoSuchFile)
}

#if canImport(AppKit)
private final class InjectedWorkspaceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ActivityWorkspaceEvent) -> Void)?
    private var installs = 0
    private var cancellations = 0

    var source: ActivityWorkspaceObserverSource {
        ActivityWorkspaceObserverSource { [weak self] handler in
            self?.lock.lock()
            self?.handler = handler
            self?.installs += 1
            self?.lock.unlock()
            return ActivityWorkspaceObserverRegistration { [weak self] in
                self?.lock.lock()
                self?.handler = nil
                self?.cancellations += 1
                self?.lock.unlock()
            }
        }
    }

    var installCount: Int {
        lock.lock(); defer { lock.unlock() }
        return installs
    }
    var cancellationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancellations
    }

    func send(_ event: ActivityWorkspaceEvent) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(event)
    }
}

private final class InjectedIdleSeconds: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(_ value: Double) { self.value = value }

    func read() -> Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}

private func waitForSpan(
    _ store: ActivitySpanStore, bundleID: String, closed: Bool
) async throws -> ActivitySpan? {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        let rows = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude, limit: 100)
        if let row = rows.first(where: { $0.bundleId == bundleID && (closed ? !$0.isOpen : $0.isOpen) }) {
            return row
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

@Test("WATCHER INTEGRATION: injected activation and the real tick persist an idle close at the exact boundary")
func watcherInjectedTickClosesTheActualSpanForIdle() async throws {
    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let wall = Date().timeIntervalSince1970
    let clock = ManualActivityClock(wall: wall, monotonic: 0)
    let events = InjectedWorkspaceEvents()
    let idle = InjectedIdleSeconds(0)
    let watcher = ActivityWatcher(
        store: store, policy: ActivityPolicy(captureEnabled: true), clock: clock,
        heartbeatInterval: 0.02, workspaceObserverSource: events.source,
        accessibilityObservationEnabled: false,
        motorEpochIsAgentDriven: { false },
        idleSecondsSinceLastInput: { idle.read() }, lockProbe: { false }
    )
    #expect(await watcher.startBounded(timeout: 2))
    events.send(.activate(bundleId: "com.example.tick", appName: "Tick", pid: 42_424))
    #expect(try await waitForSpan(store, bundleID: "com.example.tick", closed: false) != nil)
    idle.set(350)
    clock.advance(400)
    let row = try #require(try await waitForSpan(store, bundleID: "com.example.tick", closed: true))
    #expect(row.closeReason == .idle)
    #expect(row.endedAt == wall + 50)
    await watcher.stop()
    #expect(watcher.lifecycleState == .stopped)
    #expect(!watcher.status().workspaceObserversInstalled)
    #expect(events.cancellationCount == 1)
    #expect(await watcher.startBounded(timeout: 2))
    #expect(events.installCount == 2)
    await watcher.stop()
}

@Test("WATCHER INTEGRATION: an injected system sleep closes the actual span once with sleep reason")
func watcherInjectedSystemSleepClosesTheActualSpan() async throws {
    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let wall = Date().timeIntervalSince1970
    let clock = ManualActivityClock(wall: wall, monotonic: 0)
    let events = InjectedWorkspaceEvents()
    let watcher = ActivityWatcher(
        store: store, policy: ActivityPolicy(captureEnabled: true), clock: clock,
        heartbeatInterval: 3_600, workspaceObserverSource: events.source,
        accessibilityObservationEnabled: false,
        motorEpochIsAgentDriven: { false },
        idleSecondsSinceLastInput: { 0 }, lockProbe: { false }
    )
    #expect(await watcher.startBounded(timeout: 2))
    events.send(.activate(bundleId: "com.example.sleep", appName: "Sleep", pid: 42_425))
    #expect(try await waitForSpan(store, bundleID: "com.example.sleep", closed: false) != nil)
    clock.advance(25)
    events.send(.sleep)
    events.send(.sleep) // display + system sleep must not double-close.
    let row = try #require(try await waitForSpan(store, bundleID: "com.example.sleep", closed: true))
    #expect(row.closeReason == .sleep)
    #expect(row.endedAt == wall + 25)
    events.send(.wake)
    clock.advance(1)
    events.send(.activate(bundleId: "com.example.after-wake", appName: "After Wake", pid: 42_426))
    #expect(
        try await waitForSpan(store, bundleID: "com.example.after-wake", closed: false) != nil,
        "wake followed by a real activation did not resume capture"
    )
    await watcher.stop()
}

@Test("WORKSPACE SYSTEM SOURCE: screen sleep/wake map once and cancellation removes the production observers")
func systemWorkspaceSourceMapsAndCancelsNotifications() {
    final class Received: @unchecked Sendable {
        let lock = NSLock(); var events: [ActivityWorkspaceEvent] = []
        func append(_ event: ActivityWorkspaceEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        var snapshot: [ActivityWorkspaceEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }
    let received = Received()
    let registration = ActivityWorkspaceObserverSource.system.install { received.append($0) }
    let center = NSWorkspace.shared.notificationCenter
    let current = NSRunningApplication.current
    center.post(
        name: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        userInfo: [NSWorkspace.applicationUserInfoKey: current]
    )
    center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    let mapped = received.snapshot
    #expect(mapped.count == 3)
    guard case let .activate(bundleId, appName, pid) = mapped[0] else {
        Issue.record("didActivateApplication did not map to .activate")
        registration.cancel()
        return
    }
    #expect(bundleId == current.bundleIdentifier)
    #expect(appName == current.localizedName)
    #expect(pid == current.processIdentifier)
    guard case .sleep = mapped[1], case .wake = mapped[2] else {
        Issue.record("screen sleep/wake did not map to the exact .sleep, .wake sequence")
        registration.cancel()
        return
    }
    registration.cancel()
    center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    #expect(received.snapshot.count == 3)
}
#endif

@Test("GROUND TRUTH: the shipped timeline executes through the real simulator and SQLite store")
func groundTruthTimelineExecutesExactly() async throws {
    let root = try productionBoundaryRoot()
    let scriptURL = try activityRepositoryRoot()
        .appendingPathComponent("tests/activity_watch/ground_truth_script.json")
    let script = try ActivityScript.parse(data: Data(contentsOf: scriptURL))
    let spans = try await ActivitySimulator.replay(script, into: ActivitySpanStore(dataRoot: root))

    let expected: [(String, Double, Double?, ActivityCloseReason?, String?)] = [
        ("com.apple.Terminal", 0, 150, .windowChange, "build - zsh - 80x24"),
        ("com.apple.Terminal", 150, 300, .appChange, "[redacted]"),
        ("com.apple.Safari", 300, 900, .idle, nil),
        ("com.apple.dt.Xcode", 1200, 1500, .lock, nil),
        ("com.apple.dt.Xcode", 1810, 2400, .sleep, nil),
        ("com.apple.Terminal", 3010, 3100, .appChange, nil),
        ("com.apple.Terminal", 3200, nil, nil, nil),
    ]
    let epoch = 1_700_000_000.0
    #expect(spans.count == expected.count)
    for (span, truth) in zip(spans, expected) {
        #expect(span.bundleId == truth.0)
        #expect(span.startedAt == epoch + truth.1)
        #expect(span.endedAt == truth.2.map { epoch + $0 })
        #expect(span.closeReason == truth.3)
        #expect(span.titleRedacted == truth.4)
        #expect(span.endedAt == span.lastSeenAt || span.closeReason != .abandoned)
        #expect((span.endedAt ?? span.lastSeenAt) > span.startedAt)
    }
    #expect(!spans.contains { $0.bundleId == "com.1password.1password" || $0.bundleId == "com.apple.Notes" })
}

@Test("RETENTION: corrupt schedule state is repaired by a real prune, not silently skipped")
func corruptRetentionScheduleRunsAndRepairsItsDurableState() async throws {
    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = 1_700_000_000.0
    try await store.openSpan(ActivitySpan(
        startedAt: now - 3 * 86_400, endedAt: now - 3 * 86_400 + 1,
        lastSeenAt: now - 3 * 86_400 + 1, bundleId: "com.example.expired",
        appName: "Expired", eventCount: 1, closeReason: .idle
    ))
    let runner = ActivityRetentionRunner(dataRoot: root, interval: 60)
    try Data("not json".utf8).write(to: runner.stateURL)

    let result = try await runner.runIfDue(
        store: store, policy: ActivityPolicy(captureEnabled: true, retentionDays: 1), now: now
    )
    #expect(result.ran)
    #expect(result.deleted == 1)
    #expect(try await store.querySpans(from: 0, to: now).isEmpty)
    #expect(runner.lastRunAt() == now)
    #expect(!runner.isDue(now: now + 59))
}

@Test("WATCHER TICK: idle closes at the last-input boundary and never fabricates time")
func watcherIdleTickUsesTheExactTemporalBoundary() async throws {
    let started = 1_700_000_000.0
    #expect(ActivityWatcher.defaultIdleThreshold == 300)
    #expect(ActivityWatcher.idleCloseTimestamp(
        spanStartedAt: started, now: started + 300, secondsSinceLastInput: 300,
        threshold: ActivityWatcher.defaultIdleThreshold
    ) == nil, "the threshold is strict: exactly five minutes is not yet idle")
    #expect(ActivityWatcher.idleCloseTimestamp(
        spanStartedAt: started, now: started + 400, secondsSinceLastInput: 350,
        threshold: ActivityWatcher.defaultIdleThreshold
    ) == started + 50)
    #expect(ActivityWatcher.idleCloseTimestamp(
        spanStartedAt: started, now: started + 100, secondsSinceLastInput: 900,
        threshold: ActivityWatcher.defaultIdleThreshold
    ) == started, "an impossible idle reading must not predate the open span")

    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    var engine = ActivitySpanEngine(policy: ActivityPolicy(captureEnabled: true))
    try await store.apply(engine.process(.activate(
        bundleId: "com.example.editor", appName: "Editor", at: started
    )))
    let close = try #require(ActivityWatcher.idleCloseTimestamp(
        spanStartedAt: started, now: started + 400, secondsSinceLastInput: 350,
        threshold: ActivityWatcher.defaultIdleThreshold
    ))
    try await store.apply(engine.process(.idle(at: close)))
    let row = try #require(try await store.querySpans(from: started - 1, to: started + 500).first)
    #expect(row.closeReason == .idle)
    #expect(row.endedAt == started + 50)
}

#if canImport(AppKit)
@Test("WATCHER RETENTION: capture startup creates the due-state receipt without an app-controller call")
func watcherStartupOwnsRetentionScheduling() async throws {
    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = Date().timeIntervalSince1970
    try await store.openSpan(ActivitySpan(
        id: "expired", startedAt: now - 3 * 86_400, endedAt: now - 3 * 86_400 + 1,
        lastSeenAt: now - 3 * 86_400 + 1, bundleId: "com.example.expired",
        appName: "Expired", eventCount: 1, closeReason: .idle, tzOffsetMin: 0
    ))
    let watcher = ActivityWatcher(
        store: store,
        policy: ActivityPolicy(captureEnabled: true, retentionDays: 1)
    )
    defer { Task { await watcher.stop() } }

    #expect(await watcher.startBounded(timeout: 2))
    #expect(watcher.status().workspaceObserversInstalled)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    let receipt = ActivityWatchPaths.retentionStateURL(dataRoot: root)
    while !FileManager.default.fileExists(atPath: receipt.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(
        FileManager.default.fileExists(atPath: receipt.path),
        "a running watcher never recorded retention state; app-only wiring is still the sole scheduler"
    )
    let rows = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude)
    #expect(!rows.contains { $0.id == "expired" })
    await watcher.stop()
}
#endif
