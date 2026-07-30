import Foundation
import Testing
@testable import NativeAgentApp
@testable import BackgroundLoops
import NativeAgentCore
import TriggerScheduler

private actor TriggerPhysiologyCounter {
    private(set) var value = 0
    private(set) var activeSnapshots: [[String]] = []

    func record(_ names: [String]) {
        value += 1
        activeSnapshots.append(names)
    }
}

private func triggerPhysiologyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("trigger-physiology-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeJSONObject(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func eventually(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition did not become true before timeout")
}

@Suite("Trigger scheduler event/deadline physiology", .serialized)
struct TriggerSchedulerPhysiologyTests {
    @Test("trigger due work has no second periodic lifecycle owner")
    func noSeparatePeriodicOwner() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stubs = try String(contentsOf: repo.appendingPathComponent(
            "Sources/NativeAgentApp/BackgroundLoopsManagerComposition.swift"
        ))
        let launch = try String(contentsOf: repo.appendingPathComponent(
            "Sources/NativeAgentApp/AppDelegate+Launch.swift"
        ))
        let assembly = try String(contentsOf: repo.appendingPathComponent(
            "Sources/NativeAgentApp/BackgroundLoopsAssembly.swift"
        ))

        #expect(!stubs.contains("startBackgroundLoop"))
        #expect(!stubs.contains("60 * 1_000_000_000"))
        #expect(!launch.contains("TriggerScheduler.shared.start"))
        #expect(!launch.contains("TriggerScheduler.shared.stop"))
        #expect(!stubs.contains("public actor TriggerScheduler"))
        #expect(assembly.contains("makeTriggerSchedulerLoop(dataRoot: dataRoot)"))
    }

    @Test("runner chooses the exact earliest persisted schedule")
    func exactEarliestDeadline() async throws {
        let root = try triggerPhysiologyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 10, minute: 0
        )))
        let triggerDue = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 10, minute: 45
        )))
        let jobDue = now.addingTimeInterval(2 * 60 * 60)

        try writeJSONObject([[
            "name": "exact-time",
            "kind": "time",
            "enabled": true,
            "config": ["hour": 10, "minute": 45],
        ]], to: root.appendingPathComponent("inbox/trigger_config.json"))

        let scheduler = SwiftNativeTriggerScheduler(
            root: root,
            now: { now },
            worklogPath: root.appendingPathComponent("no-worklog.jsonl")
        )
        let runner = TriggerSchedulerEventDeadlineRunner(
            dataRoot: root,
            schedulerJobsPath: root.appendingPathComponent("scheduler/jobs.json"),
            triggerScheduler: scheduler,
            runDueJobs: { [] },
            nextSchedulerJobDeadline: { _ in jobDue },
            mirrorFire: { _ in true }
        )

        #expect(await runner.nextMeaningfulDeadline(after: now) == triggerDue)
    }

    @Test("scheduler jobs expose their persisted next-run instant")
    func exactSchedulerJobDeadline() async throws {
        let root = try triggerPhysiologyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exact = now.addingTimeInterval(1_337)
        let runner = SchedulerDueJobRunner(root: root)
        try writeJSONObject([
            [
                "id": "later",
                "enabled": true,
                "nextRunAtEpoch": exact.timeIntervalSince1970,
            ],
            [
                "id": "disabled-earlier",
                "enabled": false,
                "nextRunAtEpoch": now.addingTimeInterval(10).timeIntervalSince1970,
            ],
        ], to: runner.jobsPath)

        #expect(await runner.nextMeaningfulDeadline(after: now) == exact)
    }

    @Test("source bursts coalesce and startup plus restart each reconcile once")
    func startupRestartAndCoalescing() async throws {
        let root = try triggerPhysiologyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = root.appendingPathComponent("scheduler/jobs.json")
        try writeJSONObject([], to: root.appendingPathComponent("inbox/trigger_config.json"))
        try writeJSONObject([], to: root.appendingPathComponent("workshop/triggers.json"))
        try writeJSONObject([], to: jobs)

        let counter = TriggerPhysiologyCounter()
        let scheduler = SwiftNativeTriggerScheduler(
            root: root,
            worklogPath: root.appendingPathComponent("no-worklog.jsonl")
        )
        let runner = TriggerSchedulerEventDeadlineRunner(
            dataRoot: root,
            schedulerJobsPath: jobs,
            triggerScheduler: scheduler,
            runDueJobs: {
                await counter.record([])
                return []
            },
            nextSchedulerJobDeadline: { _ in nil },
            mirrorFire: { _ in true }
        )
        let manager = BackgroundLoops.BackgroundLoopsManager()
        _ = await manager.start(loops: [runner])
        await manager._testWaitForPhysiologyStartup(loopId: runner.loopId)
        #expect(await counter.value == 1)

        for index in 0..<12 {
            try writeJSONObject([["id": index]], to: jobs)
        }
        try await eventually { await counter.value >= 2 }
        try await Task.sleep(for: .milliseconds(800))
        #expect(await counter.value == 2)

        await manager.restartLoop(id: runner.loopId, newLoop: runner)
        await manager._testWaitForPhysiologyStartup(loopId: runner.loopId)
        #expect(await counter.value == 3)

        try writeJSONObject([["id": "after-restart"]], to: jobs)
        try await eventually { await counter.value >= 4 }
        try await Task.sleep(for: .milliseconds(650))
        #expect(await counter.value == 4)
        await manager.stop()
    }

    @Test("overlapping due passes cannot fire one trigger occurrence twice")
    func duplicateOccurrenceIsClaimedOnce() async throws {
        let root = try triggerPhysiologyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 10, minute: 5
        )))
        try writeJSONObject([[
            "name": "once-only",
            "kind": "time",
            "enabled": true,
            "config": ["hour": 10, "minute": 0, "notify": false],
        ]], to: root.appendingPathComponent("inbox/trigger_config.json"))
        try writeJSONObject([], to: root.appendingPathComponent("workshop/triggers.json"))

        let counter = TriggerPhysiologyCounter()
        let scheduler = SwiftNativeTriggerScheduler(
            root: root,
            now: { now },
            uuid: { UUID().uuidString.lowercased() },
            worklogPath: root.appendingPathComponent("no-worklog.jsonl")
        )
        let runner = TriggerSchedulerEventDeadlineRunner(
            dataRoot: root,
            schedulerJobsPath: root.appendingPathComponent("scheduler/jobs.json"),
            triggerScheduler: scheduler,
            runDueJobs: { [] },
            nextSchedulerJobDeadline: { _ in nil },
            mirrorFire: { result in
                if let name = result.name {
                    await counter.record([name])
                }
                return true
            }
        )

        async let first = runner.tickOutcome()
        async let second = runner.tickOutcome()
        _ = await (first, second)

        let snapshots = await counter.activeSnapshots
        let firedNames = snapshots.flatMap { $0 }
        let occurrenceCount = firedNames.filter { $0 == "once-only" }.count
        #expect(occurrenceCount == 1)
        let state = try Data(contentsOf: root.appendingPathComponent(
            "inbox/trigger_state.json"
        ))
        let object = try #require(
            JSONSerialization.jsonObject(with: state) as? [String: Any]
        )
        #expect(object.keys.filter { $0 == "once-only" }.count == 1)
    }
}
