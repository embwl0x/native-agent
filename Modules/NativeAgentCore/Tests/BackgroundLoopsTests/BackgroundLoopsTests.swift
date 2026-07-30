import Testing
import Foundation
@testable import BackgroundLoops
import TriggerScheduler
import NativeAgentCore
import PersistenceCore

private actor RecordingSchedulerJobWriter: SchedulerJobWriter {
    var createBody: JSONValue?
    var listCalls = 0
    var createCalls = 0

    func createJob(body: JSONValue) async throws -> JSONValue {
        createCalls += 1
        createBody = body
        return .object([
            "id": .string("writer-created"),
            "kind": .string("notify"),
            "enabled": .bool(true),
        ])
    }

    func cancelJob(jobId: String) async throws -> JSONValue {
        .object(["ok": .bool(true), "job": .object(["id": .string(jobId), "enabled": .bool(false)])])
    }

    func listJobs() async throws -> [JSONValue] {
        listCalls += 1
        return [
            .object([
                "id": .string("writer-job"),
                "kind": .string("improve"),
                "name": .string("Improve"),
                "enabled": .bool(true),
            ]),
        ]
    }
}

// MARK: - Factory

@Test func factoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeBackgroundLoops()
    #expect(impl is SwiftNativeBackgroundLoops)
}

@Test func factoryReturnsSwiftNativeWithoutDaemonFlag() async throws {
    let impl = makeBackgroundLoops()
    #expect(impl is SwiftNativeBackgroundLoops)
}

// MARK: - Codable shape

@Test func WatchdogStatus_round_trips_via_Codable_with_extras() throws {
    let raw = Data("""
    {"daemon":"ok","uptimeSeconds":49554.32,
     "daemonLifecycleStatus":"ok","daemonLifecycleDetail":"Daemon is managed by the NativeAgent app.",
     "launchAgentStatus":"ok","launchAgentDetail":"Daemon is managed by the NativeAgent app.",
     "legacyLaunchAgentStatus":"disabled","legacyLaunchAgentDetail":"Legacy disabled.",
     "runningImprovements":0,"runningMissions":0,
     "lastActivity":{"kind":"harness_learning","status":"ok"},
     "repairAvailable":true,
     "futureField":"hello"}
    """.utf8)
    let w = try JSONDecoder().decode(WatchdogStatus.self, from: raw)
    #expect(w.daemon == "ok")
    #expect(w.uptimeSeconds == 49554.32)
    #expect(w.daemonLifecycleStatus == "ok")
    #expect(w.repairAvailable == true)
    #expect(w.runningImprovements == 0)
    #expect(w.lastActivity != nil)
    guard case .object(let extras)? = w.extras else {
        Issue.record("extras should be object"); return
    }
    #expect(extras["legacyLaunchAgentStatus"] != nil)
    #expect(extras["futureField"] != nil)

    let data = try JSONEncoder().encode(w)
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"legacyLaunchAgentStatus\""))
    #expect(s.contains("\"futureField\""))
}

@Test func SchedulerJob_round_trips_via_Codable_with_extras() throws {
    let raw = Data("""
    {"id":"da6dade7-f2d8-4795-be16-a2d0a5aba02a",
     "kind":"improve","name":"Continuous Self-Improvement",
     "intervalSeconds":86400,"enabled":true,
     "lastRunAt":"2026-05-30T10:18:02.718846+00:00",
     "nextRunAt":"2026-05-31T10:18:02.718824+00:00",
     "nextRunAtEpoch":1780222682.718824,
     "nextRunAtISO":"2026-05-31T10:18:02.718824+00:00",
     "payload":{"objective":"Improve NativeAgent."},
     "oneShot":false}
    """.utf8)
    let j = try JSONDecoder().decode(SchedulerJob.self, from: raw)
    #expect(j.id == "da6dade7-f2d8-4795-be16-a2d0a5aba02a")
    #expect(j.kind == "improve")
    #expect(j.name == "Continuous Self-Improvement")
    #expect(j.intervalSeconds == 86400)
    #expect(j.enabled == true)
    #expect(j.payload != nil)
    #expect(j.oneShot == false)
    guard case .object(let extras)? = j.extras else {
        Issue.record("extras should be object"); return
    }
    #expect(extras["nextRunAtEpoch"] != nil)
    #expect(extras["nextRunAtISO"] != nil)

    let data = try JSONEncoder().encode(j)
    let back = try JSONDecoder().decode(SchedulerJob.self, from: data)
    #expect(back.id == j.id)
    #expect(back.kind == j.kind)
    #expect(back.intervalSeconds == j.intervalSeconds)
}

@Test func SchedulerJobCreateResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "id": .string("new-job-id"),
        "kind": .string("notify"),
        "enabled": .bool(true),
        "intervalSeconds": .int(3600),
    ])
    let r = SchedulerJobCreateResult(rawResponse: raw)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(SchedulerJobCreateResult.self, from: data)
    #expect(back == r)
    #expect(back.rawResponse == raw)
}

// MARK: - SwiftNative native default

@Test func swiftNative_getWatchdog_reportsSwiftBackend() async throws {
    let manager = BackgroundLoopsManager()
    let start = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 160)
    let sn = SwiftNativeBackgroundLoops(
        jobWriter: RecordingSchedulerJobWriter(),
        manager: manager,
        startedAt: start,
        now: { now }
    )
    let w = try await sn.getWatchdog()
    #expect(w.daemon == "swift")
    #expect(w.uptimeSeconds == 60)
    #expect(w.daemonLifecycleStatus == "stopped")
    #expect(w.launchAgentStatus == "not_applicable")
    #expect(w.repairAvailable == false)
    guard case .object(let extras)? = w.extras else {
        Issue.record("expected watchdog extras"); return
    }
    #expect(extras["backend"] == .string("swift"))
    #expect(extras["running"] == .bool(false))
}

@Test func swiftNative_listAndCreateUseSchedulerJobWriter() async throws {
    let writer = RecordingSchedulerJobWriter()
    let sn = SwiftNativeBackgroundLoops(
        jobWriter: writer,
        manager: BackgroundLoopsManager()
    )
    let jobs = try await sn.listSchedulerJobs()
    #expect(jobs.count == 1)
    #expect(jobs[0].id == "writer-job")
    #expect(jobs[0].kind == "improve")
    #expect(await writer.listCalls == 1)

    let result = try await sn.createSchedulerJob(.object(["kind": .string("notify")]))
    if case .object(let obj) = result.rawResponse, case .string(let id)? = obj["id"] {
        #expect(id == "writer-created")
    } else {
        Issue.record("rawResponse missing id")
    }
    #expect(await writer.createCalls == 1)
    guard case .object(let body)? = await writer.createBody else {
        Issue.record("writer did not receive body"); return
    }
    #expect(body["kind"] == .string("notify"))
}

// MARK: - Phase B: Scheduler + DoctorAutoRunLoop tests

import DoctorChecks

private actor CounterLoop: LoopRunner {
    nonisolated let loopId: String
    nonisolated let interval: TimeInterval
    private var count: Int = 0
    init(loopId: String = "counter", interval: TimeInterval) {
        self.loopId = loopId
        self.interval = interval
    }
    func currentCount() -> Int { count }
    nonisolated func tickOutcome() async -> LoopTickOutcome {
        await bump()
        return .completed(result: nil)
    }
    private func bump() { count += 1 }
}

private struct FailedOutcomeLoop: LoopRunner {
    let loopId = "typed_failure"
    let interval: TimeInterval = 60
    func tickOutcome() async -> LoopTickOutcome {
        .failed(error: "typed failure evidence")
    }
}

@Test func loopScheduler_register_then_loopState_returns_initial() async {
    let sched = SwiftNativeLoopScheduler()
    let loop = CounterLoop(loopId: "a", interval: 1.0)
    await sched.register(loop)
    let st = await sched.loopState(loopId: "a")
    #expect(st != nil)
    #expect(st?.loopId == "a")
    #expect(st?.tickCount == 0)
    #expect(st?.lastTickAt == nil)
    await sched.stop()
}

@Test func loopScheduler_start_runs_tick_after_interval() async throws {
    let sched = SwiftNativeLoopScheduler()
    let loop = CounterLoop(loopId: "fast", interval: 0.05)
    await sched.register(loop)
    await sched.start()
    await sched._testRunOneTick(loopId: "fast")
    await sched.stop()
    let count = await loop.currentCount()
    #expect(count > 0)
    let st = await sched.loopState(loopId: "fast")
    #expect((st?.tickCount ?? 0) > 0)
    #expect(st?.lastTickAt != nil)
}

@Test func loopScheduler_stop_cancels_all_tasks() async throws {
    let sched = SwiftNativeLoopScheduler()
    let loop = CounterLoop(loopId: "s1", interval: 60)
    await sched.register(loop)
    await sched.start()
    let task = try #require(await sched._testTaskHandle(loopId: "s1"))
    await sched.stop()
    #expect(task.isCancelled == true)
    #expect(await sched._testTaskHandle(loopId: "s1") == nil)
}

@Test func loopScheduler_tick_failure_lands_in_lastError() async {
    let sched = SwiftNativeLoopScheduler()
    let loop = CounterLoop(loopId: "errloop", interval: 60)
    await sched.register(loop)
    await sched.recordFailure(loopId: "errloop", error: "boom")
    let st = await sched.loopState(loopId: "errloop")
    #expect(st?.lastError == "boom")
    #expect(st?.tickCount == 1)
}

@Test func loopScheduler_typedFailureUpdatesStateAndDurableReceipt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LoopOutcomeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipts = root.appendingPathComponent("failures.jsonl")
    let sched = SwiftNativeLoopScheduler(failureReceiptsPath: receipts)
    await sched.register(FailedOutcomeLoop())

    await sched._testRunOneTick(loopId: "typed_failure")

    let state = await sched.loopState(loopId: "typed_failure")
    #expect(state?.lastResult == "failed")
    #expect(state?.lastError == "typed failure evidence")
    #expect(state?.tickCount == 1)
    let text = try String(contentsOf: receipts, encoding: .utf8)
    #expect(text.contains("background_loop.failure"))
    #expect(text.contains("typed_failure"))
    #expect(text.contains("typed failure evidence"))
}

@Test func loopScheduler_concurrent_register_does_not_corrupt() async {
    let sched = SwiftNativeLoopScheduler()
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<20 {
            group.addTask {
                await sched.register(CounterLoop(loopId: "loop_\(i)", interval: 60))
            }
        }
    }
    let all = await sched.allLoopStates()
    #expect(all.count == 20)
    let ids = Set(all.map { $0.loopId })
    #expect(ids.count == 20)
}

@Test func loopScheduler_unregister_removes_loop() async {
    let sched = SwiftNativeLoopScheduler()
    await sched.register(CounterLoop(loopId: "rm", interval: 60))
    #expect(await sched.loopState(loopId: "rm") != nil)
    await sched.unregister(loopId: "rm")
    #expect(await sched.loopState(loopId: "rm") == nil)
}

@Test func loopScheduler_allLoopStates_lists_all_registered() async {
    let sched = SwiftNativeLoopScheduler()
    await sched.register(CounterLoop(loopId: "b", interval: 60))
    await sched.register(CounterLoop(loopId: "a", interval: 60))
    await sched.register(CounterLoop(loopId: "c", interval: 60))
    let all = await sched.allLoopStates()
    #expect(all.map { $0.loopId } == ["a", "b", "c"])
}

// MARK: DoctorAutoRunLoop tests

private struct MockDoctorChecks: DoctorChecksProtocol {
    let results: [CheckResult]
    let throwOnRun: Bool
    init(results: [CheckResult] = [], throwOnRun: Bool = false) {
        self.results = results
        self.throwOnRun = throwOnRun
    }
    func runAll(repair: Bool, checkLLM: Bool) async throws -> [CheckResult] {
        if throwOnRun { throw DoctorChecksError.underlying("mock boom") }
        return results
    }
    func runCheck(id: String, repair: Bool) async throws -> CheckResult? {
        results.first { $0.id == id }
    }
}

private func tempDoctorDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctorAutoRun_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func doctorAutoRunLoop_writes_latest_results_to_disk() async throws {
    let dir = tempDoctorDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockDoctorChecks(results: [
        CheckResult(id: "x", title: "X", status: "ok", detail: "fine", repair: nil)
    ])
    let loop = DoctorAutoRunLoop(
        interval: 60,
        doctorChecks: mock,
        storage: { dir }
    )
    await loop.tick()
    let path = dir.appendingPathComponent("latest.json")
    #expect(FileManager.default.fileExists(atPath: path.path))
    let data = try Data(contentsOf: path)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let checks = obj?["checks"] as? [[String: Any]]
    #expect(checks?.count == 1)
    #expect(checks?.first?["id"] as? String == "x")
    #expect(checks?.first?["status"] as? String == "ok")
}

@Test func doctorAutoRunLoop_tick_does_not_throw_on_doctor_failure() async {
    let dir = tempDoctorDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockDoctorChecks(throwOnRun: true)
    let loop = DoctorAutoRunLoop(
        interval: 60,
        doctorChecks: mock,
        storage: { dir }
    )
    // Must remain nonthrowing while reporting honest failure to the scheduler.
    guard case .failed(let error) = await loop.tickOutcome() else {
        Issue.record("expected typed doctor failure")
        return
    }
    #expect(error.contains("mock boom"))
    let path = dir.appendingPathComponent("latest.json")
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func doctorAutoRunLoop_persists_atomically() async throws {
    let dir = tempDoctorDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockDoctorChecks(results: [
        CheckResult(id: "a", title: "A", status: "ok", detail: "d", repair: nil)
    ])
    let loop = DoctorAutoRunLoop(interval: 60, doctorChecks: mock, storage: { dir })
    // Per-write atomicity: 8 sequential writes via temp+rename. Concurrent
    // contention is exercised separately by
    // doctorAutoRunLoop_concurrent_writes_produce_valid_final_file.
    for _ in 0..<8 {
        await loop.tick()
    }
    let path = dir.appendingPathComponent("latest.json")
    let data = try Data(contentsOf: path)
    // The file must be a complete, parseable JSON object — never torn.
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(obj?["checks"] != nil)
    // No stray .tmp leftovers in the directory.
    let leftover = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".tmp") }
    #expect(leftover.isEmpty)
}

@Test func doctorAutoRunLoop_concurrent_writes_produce_valid_final_file() async throws {
    // Separate concern from per-write atomicity: this exercises
    // caller-side concurrent contention on the same target path.
    // Yield first so any leftover Tasks from prior tests drain before
    // we spawn our TaskGroup.
    await Task.yield()
    let dir = tempDoctorDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockDoctorChecks(results: [
        CheckResult(id: "a", title: "A", status: "ok", detail: "d", repair: nil)
    ])
    let loop = DoctorAutoRunLoop(interval: 60, doctorChecks: mock, storage: { dir })
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask { await loop.tick() }
        }
    }
    let path = dir.appendingPathComponent("latest.json")
    let data = try Data(contentsOf: path)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(obj?["checks"] != nil)
    let leftover = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".tmp") }
    #expect(leftover.isEmpty)
}

@Test func doctorAutoRunLoop_default_interval_is_600_seconds() {
    let loop = DoctorAutoRunLoop(doctorChecks: MockDoctorChecks())
    #expect(loop.interval == 600)
    #expect(loop.loopId == "doctor_auto_run")
}

// MARK: - Cancellation / lifecycle hardening

/// Loop whose first tick suspends on a continuation until explicitly
/// released. Subsequent ticks return immediately. Lets a test sandwich
/// an `unregister()` between "tick started" and "tick returned" so we
/// can prove the generation guard works.
private actor GateLoop: LoopRunner {
    nonisolated let loopId: String
    nonisolated let interval: TimeInterval
    private var resume: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var ticksStarted = 0

    init(loopId: String, interval: TimeInterval) {
        self.loopId = loopId
        self.interval = interval
    }

    nonisolated func tickOutcome() async -> LoopTickOutcome {
        await body()
        return .completed(result: nil)
    }

    private func body() async {
        ticksStarted += 1
        if ticksStarted > 1 { return }
        hasEntered = true
        if let e = entered {
            e.resume()
            entered = nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.resume = cont
        }
    }

    func waitForEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.entered = cont
        }
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}

/// Cooperative gated loop that only commits after it has been released and
/// after checking the current task's cancellation flag. This covers the
/// LoopRunner contract without depending on wall-clock sleeps or an
/// already-started tick racing `stop()`.
private actor CancellableGateLoop: LoopRunner {
    nonisolated let loopId: String
    nonisolated let interval: TimeInterval
    private var resume: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var committed = 0

    init(loopId: String, interval: TimeInterval) {
        self.loopId = loopId
        self.interval = interval
    }

    nonisolated func tickOutcome() async -> LoopTickOutcome {
        await body()
        return .completed(result: nil)
    }

    private func body() async {
        hasEntered = true
        if let e = entered {
            e.resume()
            entered = nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.resume = cont
        }
        if Task.isCancelled { return }
        committed += 1
    }

    func waitForEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.entered = cont
        }
    }

    func release() {
        resume?.resume()
        resume = nil
    }

    func committedCount() -> Int {
        committed
    }
}

@Test func loopScheduler_inflight_tick_does_not_resurrect_state_after_unregister() async throws {
    // Repro of FAIL 1: actor reentrancy lets unregister() drop state while
    // a tick is suspended; when the tick returns, runOneTick must NOT
    // recreate the state entry. The generation token enforces this.
    let sched = SwiftNativeLoopScheduler()
    let loop = GateLoop(loopId: "gate", interval: 0.01)
    await sched.register(loop)
    await sched.start()
    // Wait until the spawned tick is suspended inside body().
    await loop.waitForEntered()
    // Unregister while the tick is still suspended.
    await sched.unregister(loopId: "gate")
    // Release the tick — runOneTick now resumes and tries to write state.
    await loop.release()
    // Give the actor a moment to process the post-tick code path.
    try await Task.sleep(nanoseconds: 100_000_000)
    let st = await sched.loopState(loopId: "gate")
    #expect(st == nil)
    await sched.stop()
}

/// Tick that sleeps for a long time but HONORS cooperative cancellation
/// via `Task.sleep`. This is the contract: well-behaved ticks let the
/// timeout primitive interrupt them. When the surrounding Task is
/// cancelled, `Task.sleep` throws `CancellationError` and the body
/// exits cleanly so the structured `withThrowingTaskGroup` inside
/// `tickWithTimeout` can return.
private actor SlowTickLoop: LoopRunner {
    nonisolated let loopId: String = "slow"
    nonisolated let interval: TimeInterval = 0.01

    nonisolated func tickOutcome() async -> LoopTickOutcome {
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        } catch {
            // Cooperative cancellation — exit cleanly.
        }
        return .completed(result: nil)
    }
}

@Test func loopScheduler_stop_prevents_cooperative_midflight_side_effect() async throws {
    let sched = SwiftNativeLoopScheduler()
    let loop = CancellableGateLoop(loopId: "cooperative-stop", interval: 0.01)
    await sched.register(loop)
    await sched.start()
    await loop.waitForEntered()
    await sched.stop()
    await loop.release()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await loop.committedCount() == 0)
}

// `tickWithTimeout` assumes the tick body honors `Task.isCancelled` /
// `Task.sleep` cancellation propagation. A tick that ignores cancellation
// (e.g. uses a never-resumed continuation) WILL leak past the timeout fire —
// that's the cost of violating the LoopRunner contract. `tickWithTimeout`
// cannot `kill -9` a misbehaving body; structured concurrency requires the
// child task to return before the group can.
@Test func loopScheduler_stop_midflight_tick_does_not_update_state() async throws {
    // FAIL 1 repro: when stop() cancels a task while its tick is suspended,
    // the post-tick state update must be skipped — observers should see the
    // pre-stop snapshot, not a tick that landed after stop().
    let sched = SwiftNativeLoopScheduler()
    let loop = GateLoop(loopId: "midflight", interval: 0.01)
    await sched.register(loop)
    let before = await sched.loopState(loopId: "midflight")
    await sched.start()
    await loop.waitForEntered()
    // stop() while the tick is still suspended.
    await sched.stop()
    // Release the tick — runOneTick now resumes; the cancel check must skip
    // the state update.
    await loop.release()
    try await Task.sleep(nanoseconds: 100_000_000)
    let after = await sched.loopState(loopId: "midflight")
    #expect(after?.tickCount == before?.tickCount)
    #expect(after?.lastTickAt == before?.lastTickAt)
}

@Test func loopScheduler_reregister_same_loopId_runs_new_runner() async throws {
    // FAIL 2 repro: re-registering the same loopId while running must cancel
    // the old task so spawnTaskIfNeeded can install a fresh task bound to
    // the new registrationId. Without that, the old task lingers, fails the
    // new generation guard forever, and the new loop never ticks.
    let sched = SwiftNativeLoopScheduler()
    let original = CounterLoop(loopId: "reused", interval: 0.02)
    await sched.register(original)
    await sched.start()
    let oldTask = await sched._testTaskHandle(loopId: "reused")
    let replacement = CounterLoop(loopId: "reused", interval: 0.02)
    await sched.register(replacement)
    #expect(oldTask?.isCancelled == true)
    await sched._testRunOneTick(loopId: "reused")
    await sched.stop()
    let newCount = await replacement.currentCount()
    #expect(newCount > 0)
}

@Test func tickWithTimeout_throws_when_tick_runs_past_deadline() async throws {
    let loop = SlowTickLoop()
    do {
        try await tickWithTimeout(loop, timeout: 0.05)
        Issue.record("expected TickTimeoutError")
    } catch is TickTimeoutError {
        // pass
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func loopScheduler_timed_out_tick_records_error_and_releases_scheduler() async throws {
    let sched = SwiftNativeLoopScheduler(tickTimeout: 0.05)
    let loop = SlowTickLoop()
    await sched.register(loop)
    await sched._testRunOneTick(loopId: "slow")
    let st = await sched.loopState(loopId: "slow")
    #expect(st?.tickCount == 1)
    #expect(st?.lastTickAt != nil)
    #expect(st?.nextTickAt != nil)
    #expect(st?.lastError == "timeout after 0.05s")
    await sched.stop()
}

// MARK: - A4.2: ok→fail transition push (cooldown-gated)

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    func advance(_ dt: TimeInterval) { lock.lock(); _now += dt; lock.unlock() }
    func time() -> Date { lock.lock(); defer { lock.unlock() }; return _now }
}

private actor PushSpy {
    private(set) var events: [(String, String)] = []
    func record(_ loopId: String, _ error: String) { events.append((loopId, error)) }
    var count: Int { events.count }
}

@Test func loopFailurePush_firesOnPersistentStreak_notPerFailure() async {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    // A4.8: the FIRST failure could be a self-healing blip — no push yet.
    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "e1")
    #expect(await spy.count == 0)

    // Second consecutive failure with the streak spanning >= 2 minutes →
    // a real outage → ONE push.
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "e2")
    #expect(await spy.count == 1)

    // Still failing → cooldown suppresses further knocks for this window.
    clock.advance(60)
    await sched.recordFailure(loopId: "L", error: "e3")
    await sched.recordFailure(loopId: "L", error: "e4")
    #expect(await spy.count == 1)
}

@Test func loopFailurePush_rapidBlipPairOnShortIntervalLoopStaysSilent() async {
    // A4.8 round 2 — the 2026-07-24 14:43 page: slack retries every 2s, so
    // one network hiccup produced two "consecutive" failures 2 seconds
    // apart and paged, then recovered 4s later. A streak that hasn't
    // PERSISTED for the minimum duration must stay silent no matter how
    // many failures it packs in.
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "socket not connected")
    clock.advance(2)
    await sched.recordFailure(loopId: "L", error: "network connection lost")
    #expect(await spy.count == 0)

    // Recovered 4 seconds later — the blip never pages.
    clock.advance(4)
    await sched.recordResult(loopId: "L", result: "completed")
    #expect(await spy.count == 0)

    // But the SAME shape persisting past the duration floor DOES page:
    // failures every 2s for 2+ minutes.
    for _ in 0..<70 {
        clock.advance(2)
        await sched.recordFailure(loopId: "L", error: "still down")
    }
    #expect(await spy.count == 1)
}

@Test func loopFailurePush_singleTransientBlipThatRecoversNeverPushes() async {
    // A4.8: the 03:17 double-page incident — one network blip failed
    // telegram_poll + github_tracking once each, then both recovered on the
    // next tick. A one-off failure followed by success must stay silent.
    let sched = SwiftNativeLoopScheduler()
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "blip")
    await sched.recordResult(loopId: "L", result: "completed")
    #expect(await spy.count == 0)

    // The recovery reset the streak: a later single blip is still silent.
    await sched.recordFailure(loopId: "L", error: "blip2")
    await sched.recordResult(loopId: "L", result: "completed")
    #expect(await spy.count == 0)
}

@Test func loopFailurePush_cooldownSuppressesFlapWithinWindow_thenReFires() async {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "first")
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "first-b")  // persistent streak → push #1
    #expect(await spy.count == 1)

    // Recover then a real streak again 1h later — inside the 6h cooldown →
    // suppressed.
    await sched.recordResult(loopId: "L", result: "completed")
    clock.advance(60 * 60)
    await sched.recordFailure(loopId: "L", error: "flap")
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "flap-b")
    #expect(await spy.count == 1)

    // Recover then a streak PAST the 6h cooldown → pushes again.
    await sched.recordResult(loopId: "L", result: "completed")
    clock.advance(6 * 60 * 60 + 1)
    await sched.recordFailure(loopId: "L", error: "second")
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "second-b")
    #expect(await spy.count == 2)
}

@Test func loopFailurePush_stillFailingStreakRePushesAfterCooldown() async {
    // gpt-5.5 BLOCKING (A4.8 round): with a `streak == threshold` gate, a
    // streak whose threshold tick was cooldown-suppressed stayed push-silent
    // for the rest of the outage. Past-threshold ticks must keep re-checking
    // the cooldown so a persistent outage knocks once per window.
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "a1")
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "a2")   // persistent streak → push #1
    #expect(await spy.count == 1)

    // Recover, then a new streak 1h later — inside cooldown, threshold tick
    // suppressed.
    await sched.recordResult(loopId: "L", result: "completed")
    clock.advance(60 * 60)
    await sched.recordFailure(loopId: "L", error: "b1")
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "b2")
    #expect(await spy.count == 1)

    // The SAME streak keeps failing past the cooldown boundary — no recovery
    // in between. The next failure tick must re-push.
    clock.advance(6 * 60 * 60)
    await sched.recordFailure(loopId: "L", error: "b3")
    #expect(await spy.count == 2)

    // And immediately after that push, the fresh stamp suppresses again.
    await sched.recordFailure(loopId: "L", error: "b4")
    #expect(await spy.count == 2)
}

@Test func loopFailurePush_coalescedSkipDoesNotResetStreak() async {
    // gpt-5.5 BLOCKING (A4.8 round): a periodic tick that coalesces with an
    // active (failing) execution proves nothing about health — resetting the
    // streak on it could hold a genuinely failing loop below the push
    // threshold forever under overlapping wake traffic.
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    struct CoalescedSkipLoop: LoopRunner {
        let loopId = "L"
        let interval: TimeInterval = 86_400
        func tickOutcome() async -> LoopTickOutcome {
            .skipped(reason: LoopTickOutcome.coalescedSkipReason)
        }
    }
    await sched.register(CoalescedSkipLoop())

    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "e1")   // streak 1
    await sched._testRunOneTick(loopId: "L")              // coalesced skip
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "e2")   // persistent streak → push
    #expect(await spy.count == 1)

    // A real (non-coalesced) skip still resets.
    await sched.recordResult(loopId: "L", result: "skipped: not due")
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "e3")   // streak 1 again
    #expect(await spy.count == 1)
}

@Test func loopFailurePush_unregisterClearsStreakButKeepsCooldown() async {
    // gpt-5.5 BLOCKING (A4.8 round 2): a hot reload (restartLoop →
    // unregister + register) must not hand the replacement loop a stale
    // streak — one old failure plus one fresh failure >=120s later would
    // otherwise read as a persistent streak and page on the new loop's
    // FIRST failure.
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let sched = SwiftNativeLoopScheduler(clock: { clock.time() })
    let spy = PushSpy()
    await sched.setFailureTransitionPush { id, err in await spy.record(id, err) }

    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "pre-reload")   // streak 1
    await sched.unregister(loopId: "L")

    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "post-reload")  // must be streak 1
    #expect(await spy.count == 0)

    // A real persistent streak on the replacement still pages.
    clock.advance(150)
    await sched.recordFailure(loopId: "L", error: "post-reload-b")
    #expect(await spy.count == 1)
}

@Test func loopFailurePush_noPushWhenNoNotifierInstalled() async {
    // Default (headless / test) scheduler has no push wired — must stay silent
    // but still record the failure receipt/state.
    let sched = SwiftNativeLoopScheduler()
    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "boom")
    let st = await sched.loopState(loopId: "L")
    #expect(st?.lastError == "boom")
    #expect(st?.lastResult == "failed")
}
