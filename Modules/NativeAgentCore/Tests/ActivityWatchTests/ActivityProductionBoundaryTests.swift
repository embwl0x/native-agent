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

private struct ProbeResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct ProbeHarnessError: Error, CustomStringConvertible {
    let description: String
}

/// Locate the probe product built by the outer test gate. Building it from this
/// process would ask SwiftPM to acquire the package lock already held by the
/// parent `swift test`, deadlocking until a timeout. The cached sibling product
/// makes each test exercise one real executable without nested SwiftPM work.
private enum ActivityProbeExecutable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Result<URL, Error>?

    static func resolve() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return try cached.get() }

        do {
            let packageProduct = try activityRepositoryRoot()
                .appendingPathComponent("Modules/NativeAgentCore/.build/debug/activity-probe")
            if FileManager.default.isExecutableFile(atPath: packageProduct.path) {
                cached = .success(packageProduct)
                return packageProduct
            }
            let roots = [Bundle.main.bundleURL, URL(fileURLWithPath: CommandLine.arguments[0])]
            for root in roots {
                var directory = root
                for _ in 0..<12 {
                    let candidate = directory.appendingPathComponent("activity-probe")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        cached = .success(candidate)
                        return candidate
                    }
                    let parent = directory.deletingLastPathComponent()
                    if parent.path == directory.path { break }
                    directory = parent
                }
            }
            throw ProbeHarnessError(
                description: "activity-probe is not built beside the test bundle; "
                    + "run `swift build --package-path Modules/NativeAgentCore "
                    + "--product activity-probe` before this suite"
            )
        } catch {
            cached = .failure(error)
            throw error
        }
    }
}

private func runProbeProcess(
    executable: URL,
    arguments: [String],
    outputRoot: URL,
    timeout: TimeInterval
) throws -> ProbeResult {
    let resultID = UUID().uuidString
    let stdoutURL = outputRoot.appendingPathComponent("probe-\(resultID).out")
    let stderrURL = outputRoot.appendingPathComponent("probe-\(resultID).err")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = try FileHandle(forWritingTo: stdoutURL)
    let err = try FileHandle(forWritingTo: stderrURL)
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        try? out.close()
        try? err.close()
        throw error
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        let grace = Date().addingTimeInterval(2)
        while process.isRunning && Date() < grace {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        try? out.close()
        try? err.close()
        throw ProbeHarnessError(
            description: "probe process timed out after \(Int(timeout)) seconds: "
                + ([executable.path] + arguments).joined(separator: " ")
        )
    }
    try out.close()
    try err.close()
    return ProbeResult(
        status: process.terminationStatus,
        stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
        stderr: try String(contentsOf: stderrURL, encoding: .utf8)
    )
}

private func runProbe(_ arguments: [String], outputRoot: URL) throws -> ProbeResult {
    try runProbeProcess(
        executable: ActivityProbeExecutable.resolve(),
        arguments: arguments,
        outputRoot: outputRoot,
        timeout: 120
    )
}

private func writeProbeScript(_ body: String, root: URL, name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(body.utf8).write(to: url)
    return url
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

@Test("PROBE PROCESS: implicit data root is refused before a destructive command can open the live store")
func probeProcessRefusesImplicitDataRoot() throws {
    let root = try productionBoundaryRoot()
    let result = try runProbe(["wipe", "--yes"], outputRoot: root)
    #expect(result.status == 64)
    #expect(result.stderr.contains("requires --data-root PATH"))
}

@Test("PROBE PROCESS: invalid policy edits fail and leave the exact policy bytes unchanged")
func probeProcessRejectsInvalidPolicyWithoutMutation() throws {
    let root = try productionBoundaryRoot()
    let policyStore = ActivityPolicyStore(dataRoot: root)
    var policy = ActivityPolicy(captureEnabled: true)
    policy.captureTitles = true
    try policyStore.save(policy)
    let before = try Data(contentsOf: policyStore.fileURL)

    let result = try runProbe(
        ["policy", "--data-root", root.path, "--titles", "yes"], outputRoot: root
    )
    #expect(result.status == 64)
    #expect(result.stderr.contains("must be 'on' or 'off'"))
    #expect(try Data(contentsOf: policyStore.fileURL) == before)
}

@Test("PROBE PROCESS: simulated secret data stays redacted in stats, dump, and rollup output")
func probeProcessReadCommandsUseTheSeededStoreWithoutLeakingRawTitles() throws {
    let root = try productionBoundaryRoot()
    let script = try activityRepositoryRoot()
        .appendingPathComponent("tests/activity_watch/ground_truth_script.json")
    let simulate = try runProbe(
        ["simulate", "--data-root", root.path, "--script", script.path], outputRoot: root
    )
    #expect(simulate.status == 0)
    let secret = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    #expect(!simulate.stdout.contains(secret))

    for (command, expected) in [
        ["stats", "--data-root", root.path, "--days", "36500"],
        ["dump", "--data-root", root.path, "--days", "36500"],
        ["rollup", "--data-root", root.path, "--days", "36500", "--grain", "daily", "--tz", "UTC"],
    ].map({ ($0, $0[0]) }) {
        let result = try runProbe(command, outputRoot: root)
        #expect(result.status == 0, "\(command): \(result.stderr)")
        #expect(!result.stdout.contains(secret), "raw title leaked through \(command[0])")
        switch expected {
        case "stats": #expect(result.stdout.contains("spans           : 7"))
        case "dump": #expect(result.stdout.contains("7 spans"))
        default: #expect(result.stdout.contains("total observed"))
        }
    }

    for command in ["stats", "dump", "rollup"] {
        let rejected = try runProbe(
            [command, "--data-root", root.path, "--days", "not-a-number"], outputRoot: root
        )
        #expect(rejected.status == 64)
        #expect(rejected.stderr.contains("positive finite number"))
    }
}

@Test("PROBE PROCESS: simulate output is independently verified, then reconcile settles a crash at last-seen")
func probeProcessSimulateAndReconcileExecuteTheRealStorePath() async throws {
    let root = try productionBoundaryRoot()
    let script = try activityRepositoryRoot()
        .appendingPathComponent("tests/activity_watch/ground_truth_script.json")
    let simulated = try runProbe(
        ["simulate", "--data-root", root.path, "--script", script.path], outputRoot: root
    )
    #expect(simulated.status == 0)
    let payload = try #require(
        try JSONSerialization.jsonObject(with: Data(simulated.stdout.utf8)) as? [String: Any]
    )
    let rows = try #require(payload["spans"] as? [[String: Any]])
    #expect(rows.count == 7)
    #expect(rows.map { $0["bundle_id"] as? String } == [
        "com.apple.Terminal", "com.apple.Terminal", "com.apple.Safari",
        "com.apple.dt.Xcode", "com.apple.dt.Xcode", "com.apple.Terminal", "com.apple.Terminal",
    ])
    #expect(rows.last?["close_reason"] is NSNull)
    #expect(rows.last?["ended_at"] is NSNull)

    // A crash deliberately leaves the row open. The next launch owns the
    // abandoned close, exactly as the real watcher does.
    #expect(try runProbe(["reconcile", "--data-root", root.path], outputRoot: root).status == 0)
    let store = try ActivitySpanStore(dataRoot: root)
    let reconciledRows = try await store.querySpans(
        from: 0, to: .greatestFiniteMagnitude, limit: 100_000
    )
    let reconciledJSON = ActivitySimulator.spansJSON(reconciledRows)
    let reconciledPayload = try #require(
        try JSONSerialization.jsonObject(with: Data(reconciledJSON.utf8)) as? [String: Any]
    )
    let settled = try #require(reconciledPayload["spans"] as? [[String: Any]])
    #expect(settled.count == 7)
    #expect(settled.allSatisfy { $0["ended_at"] is Double })
    #expect(settled.last?["close_reason"] as? String == "abandoned")
    #expect(settled.last?["ended_at"] as? Double == settled.last?["last_seen_at"] as? Double)

    let crashScript = try writeProbeScript("""
    {"version":1,"policy":{"captureEnabled":true},"events":[
      {"type":"activate","bundleId":"com.example.crash","appName":"Crash","at":1700000000},
      {"type":"focusEvent","at":1700000010},{"type":"crash","at":1700000020}
    ]}
    """, root: root, name: "crash.json")
    #expect(try runProbe(
        ["simulate", "--data-root", root.path, "--script", crashScript.path], outputRoot: root
    ).status == 0)
    #expect(try runProbe(["reconcile", "--data-root", root.path], outputRoot: root).status == 0)
    let dump = try runProbe(
        ["dump", "--data-root", root.path, "--days", "36500"], outputRoot: root
    )
    #expect(dump.status == 0)
    #expect(dump.stdout.contains("com.example.crash"))
    #expect(dump.stdout.contains("reason=abandoned"))
}

@Test("PROBE PROCESS: no-root simulation uses scratch while the supplied live fixture remains byte-identical")
func probeProcessNoRootSimulationDoesNotTouchFixtureStore() async throws {
    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    try await store.openSpan(ActivitySpan(
        id: "fixture", startedAt: 1_700_000_000, endedAt: 1_700_000_001,
        lastSeenAt: 1_700_000_001, bundleId: "com.example.fixture", appName: "Fixture",
        eventCount: 1, closeReason: .idle, tzOffsetMin: 0
    ))
    let before = try Data(contentsOf: ActivityWatchPaths.databaseURL(dataRoot: root))
    let script = try activityRepositoryRoot()
        .appendingPathComponent("tests/activity_watch/ground_truth_script.json")
    let simulated = try runProbe(["simulate", "--script", script.path], outputRoot: root)
    #expect(simulated.status == 0)
    #expect(simulated.stderr.contains("scratch store"))
    #expect(try Data(contentsOf: ActivityWatchPaths.databaseURL(dataRoot: root)) == before)
}

@Test("PROBE PROCESS: run cannot grant capture consent and records no rows")
func probeProcessRunEnableRefusalLeavesStoreEmpty() async throws {
    let root = try productionBoundaryRoot()
    let result = try runProbe(
        ["run", "--data-root", root.path, "--enable-capture"], outputRoot: root
    )
    #expect(result.status == 64)
    #expect(result.stderr.contains("run cannot enable capture"))
    let store = try ActivitySpanStore(dataRoot: root)
    #expect(try await store.querySpans(from: 0, to: .greatestFiniteMagnitude).isEmpty)
}

@Test("PROBE PROCESS: exclude then include in one command preserves the seeded rows")
func probeProcessMixedPolicyTransactionDoesNotPurgeIncludedBundle() throws {
    let root = try productionBoundaryRoot()
    let script = try activityRepositoryRoot()
        .appendingPathComponent("tests/activity_watch/ground_truth_script.json")
    #expect(try runProbe(
        ["simulate", "--data-root", root.path, "--script", script.path], outputRoot: root
    ).status == 0)
    let policy = try runProbe(
        ["policy", "--data-root", root.path, "--exclude", "com.apple.Terminal", "--include", "com.apple.Terminal"],
        outputRoot: root
    )
    #expect(policy.status == 0)
    #expect(!policy.stdout.contains("retro-deleted"))
    #expect(policy.stdout.contains("no rows were deleted"))
    let dump = try runProbe(
        ["dump", "--data-root", root.path, "--days", "36500"], outputRoot: root
    )
    #expect(dump.stdout.contains("com.apple.Terminal"))
}

@Test("PROBE PROCESS: sequential exclude then include permanently purges old rows and says so")
func probeProcessSequentialPolicyPurgeIsHonestAndIrreversible() throws {
    let root = try productionBoundaryRoot()
    let script = try activityRepositoryRoot()
        .appendingPathComponent("tests/activity_watch/ground_truth_script.json")
    #expect(try runProbe(
        ["simulate", "--data-root", root.path, "--script", script.path], outputRoot: root
    ).status == 0)
    let excluded = try runProbe(
        ["policy", "--data-root", root.path, "--exclude", "com.apple.Terminal"], outputRoot: root
    )
    #expect(excluded.status == 0)
    #expect(excluded.stdout.contains("retro-deleted"))
    let included = try runProbe(
        ["policy", "--data-root", root.path, "--include", "com.apple.Terminal"], outputRoot: root
    )
    #expect(included.status == 0)
    #expect(included.stdout.contains("already deleted history is not restored"))
    let dump = try runProbe(["dump", "--data-root", root.path, "--days", "36500"], outputRoot: root)
    #expect(!dump.stdout.contains("com.apple.Terminal"))
}

@Test("PROBE PROCESS: dump exceeds the old 5k cap and reports the exact excess past 20k")
func probeProcessDumpReportsExactOmittedRowCount() async throws {
    let root = try productionBoundaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let start = 1_700_000_000.0
    for index in 0...20_000 {
        let at = start + Double(index)
        try await store.openSpan(ActivitySpan(
            id: "dump-\(index)", startedAt: at, endedAt: at + 0.5, lastSeenAt: at + 0.5,
            bundleId: "com.example.dump", appName: "Dump", eventCount: 1,
            closeReason: .idle, tzOffsetMin: 0
        ))
    }
    let result = try runProbe(
        ["dump", "--data-root", root.path, "--days", "36500"], outputRoot: root
    )
    #expect(result.status == 0)
    #expect(result.stdout.contains("20,000 spans"))
    #expect(result.stdout.contains("20,000 shown; 1 omitted"))
    #expect(
        result.stdout.components(separatedBy: "reason=idle").count - 1 == 20_000,
        "the old 5,000-row cap survived"
    )
}

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
