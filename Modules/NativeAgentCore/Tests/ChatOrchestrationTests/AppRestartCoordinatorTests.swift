import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - AppRestartCoordinator (restart_app / Telegram /restart core)
//
// All tests run against a tmp-dir dataRoot and seam the Process spawn +
// terminate scheduling behind injectable closures — NOTHING here spawns a
// relauncher or terminates a process for real. The recorder also snapshots
// audit/stamp file existence AT SPAWN TIME, which is how we prove the
// required ordering (audit → stamp → spawn → reply → terminate-scheduled)
// rather than just final state.

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("restart-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Lock-protected event recorder shared across @Sendable seams.
private final class RestartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    private(set) var spawnedArgvs: [[String]] = []
    private(set) var terminateGraces: [TimeInterval] = []
    /// Snapshot taken inside the spawn seam: (auditFileCount, stampExists).
    private(set) var stateAtSpawn: (auditFiles: Int, stampExists: Bool)?

    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func recordSpawn(argv: [String], dataRoot: URL) {
        lock.lock(); defer { lock.unlock() }
        events.append("spawn")
        spawnedArgvs.append(argv)
        let auditDir = dataRoot.appendingPathComponent("restart_audit", isDirectory: true)
        let stamp = auditDir.appendingPathComponent("last_restart.json")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: auditDir.path)) ?? []
        stateAtSpawn = (
            auditFiles: files.filter { $0.hasSuffix(".json") && $0 != "last_restart.json" }.count,
            stampExists: FileManager.default.fileExists(atPath: stamp.path)
        )
    }

    func recordTerminate(grace: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        events.append("terminate_scheduled")
        terminateGraces.append(grace)
    }
}

private struct SpawnBoom: Error {}

private func makeCoordinator(
    dataRoot: URL,
    recorder: RestartRecorder,
    now: @escaping @Sendable () -> Date = { Date() },
    spawnError: Bool = false,
    configureTerminate: Bool = true
) -> AppRestartCoordinator {
    let spawn: @Sendable ([String]) throws -> Void = { argv in
        if spawnError { throw SpawnBoom() }
        recorder.recordSpawn(argv: argv, dataRoot: dataRoot)
    }
    var terminate: (@Sendable (TimeInterval) -> Void)?
    if configureTerminate {
        terminate = { grace in recorder.recordTerminate(grace: grace) }
    }
    return AppRestartCoordinator(
        dataRoot: dataRoot,
        currentPID: 4242,
        now: now,
        spawnRelauncher: spawn,
        scheduleTerminate: terminate
    )
}

private func envString(_ envelope: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = envelope, case .string(let s)? = obj[key] else { return nil }
    return s
}

private func envNumber(_ envelope: JSONValue, _ key: String) -> Double? {
    guard case .object(let obj) = envelope, case .double(let n)? = obj[key] else { return nil }
    return n
}

@Suite("AppRestartCoordinator")
struct AppRestartCoordinatorTests {

    @Test func restart_fires_in_order_audit_stamp_spawn_reply_terminate() async throws {
        let root = try makeTempRoot("order")
        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(dataRoot: root, recorder: recorder)

        let envelope = await coordinator.requestRestart(reason: "wedged tool loop", source: "test")

        // Reply envelope is honest and complete.
        #expect(envString(envelope, "status") == "restarting")
        #expect(envString(envelope, "reason") == "wedged tool loop")
        #expect(envNumber(envelope, "graceSeconds") == AppRestartCoordinator.terminateGraceSeconds)

        // Seam order: spawn before terminate_scheduled; nothing else fired.
        #expect(recorder.events == ["spawn", "terminate_scheduled"])
        // Audit + stamp were already on disk AT SPAWN TIME (audit → stamp → spawn).
        let atSpawn = try #require(recorder.stateAtSpawn)
        #expect(atSpawn.auditFiles == 1)
        #expect(atSpawn.stampExists)
        // Terminate scheduled with the configured grace (constant seam —
        // sized to outlive the final reply LLM call + persistence).
        #expect(recorder.terminateGraces == [AppRestartCoordinator.terminateGraceSeconds])
        // The success note instructs reply brevity: the final reply must be
        // composed + persisted inside the fixed grace window.
        let note = try #require(envString(envelope, "note"))
        #expect(note.contains("brief"))
        #expect(note.contains("\(Int(AppRestartCoordinator.terminateGraceSeconds))s"))
    }

    // BLOCKER (2026-06-10): the FIRST-ever restart has no prior stamp. The
    // audit dictionary used to carry `Optional<String> as Any` for
    // lastRestartAt — this pins the no-prior-stamp path end to end: the
    // restart succeeds and the audit JSON serializes without the key.
    @Test func first_restart_with_no_prior_stamp_succeeds() async throws {
        let root = try makeTempRoot("first")
        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(dataRoot: root, recorder: recorder)

        let stamp = root
            .appendingPathComponent("restart_audit", isDirectory: true)
            .appendingPathComponent("last_restart.json")
        #expect(!FileManager.default.fileExists(atPath: stamp.path))

        let envelope = await coordinator.requestRestart(reason: "first ever", source: "test")
        #expect(envString(envelope, "status") == "restarting")
        #expect(recorder.events == ["spawn", "terminate_scheduled"])

        // Audit receipt exists, parses, and omits lastRestartAt entirely.
        let auditPath = try #require(envString(envelope, "audit_path"))
        let data = try Data(contentsOf: URL(fileURLWithPath: auditPath))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["lastRestartAt"] == nil)
        #expect(obj["runId"] as? String != nil)
    }

    // BLOCKER (2026-06-10): a stamp in the FUTURE (cross-process race —
    // another process wrote a fresh stamp while we waited on the flock — or
    // clock skew) must count as cooling-down, not bypass the cooldown the
    // way the old `elapsed >= 0` guard allowed.
    @Test func future_stamp_refuses_as_cooling_down() async throws {
        let root = try makeTempRoot("future")
        let t0 = Date()

        // First restart fires 300s in the FUTURE relative to the second
        // request's clock — simulating the cross-process stamp race.
        let firstRecorder = RestartRecorder()
        let first = makeCoordinator(
            dataRoot: root, recorder: firstRecorder, now: { t0.addingTimeInterval(300) }
        )
        let fired = await first.requestRestart(reason: "future stamp", source: "test")
        #expect(envString(fired, "status") == "restarting")

        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(dataRoot: root, recorder: recorder, now: { t0 })
        let refusal = await coordinator.requestRestart(reason: "raced", source: "test")
        #expect(envString(refusal, "status") == "failed")
        #expect(envString(refusal, "reason") == "cooldown")
        // No spawn, no terminate for a refused request.
        #expect(recorder.events.isEmpty)
        // retryAfter accounts for the negative elapsed (> full window).
        let retryAfter = try #require(envNumber(refusal, "retryAfterSeconds"))
        #expect(retryAfter > AppRestartCoordinator.cooldownSeconds)
    }

    // Counterpart to the first-restart test: a restart AFTER the cooldown
    // window records the prior stamp in its audit (the non-nil branch must
    // serialize too).
    @Test func post_window_restart_audit_records_prior_stamp() async throws {
        let root = try makeTempRoot("priorstamp")
        let t0 = Date()
        let first = makeCoordinator(dataRoot: root, recorder: RestartRecorder(), now: { t0 })
        _ = await first.requestRestart(reason: "first", source: "test")

        let later = makeCoordinator(
            dataRoot: root, recorder: RestartRecorder(),
            now: { t0.addingTimeInterval(AppRestartCoordinator.cooldownSeconds + 5) }
        )
        let envelope = await later.requestRestart(reason: "second", source: "test")
        #expect(envString(envelope, "status") == "restarting")
        let auditPath = try #require(envString(envelope, "audit_path"))
        let data = try Data(contentsOf: URL(fileURLWithPath: auditPath))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["lastRestartAt"] as? String != nil)
    }

    // BLOCKER (2026-06-10): the deferred variant commits the restart but
    // must NOT arm termination until the caller invokes the returned
    // closure (Telegram sends the reply in between).
    @Test func deferred_variant_arms_terminate_only_when_invoked() async throws {
        let root = try makeTempRoot("deferred")
        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(dataRoot: root, recorder: recorder)

        let (envelope, armTerminate) = await coordinator.requestRestartDeferringTerminate(
            reason: "telegram ordering", source: "telegram:/restart"
        )
        #expect(envString(envelope, "status") == "restarting")
        // Restart committed (spawned), but NO terminate scheduled yet.
        #expect(recorder.events == ["spawn"])

        let arm = try #require(armTerminate)
        arm()
        #expect(recorder.events == ["spawn", "terminate_scheduled"])
        #expect(recorder.terminateGraces == [AppRestartCoordinator.terminateGraceSeconds])
    }

    @Test func deferred_variant_returns_no_arm_on_refusal() async throws {
        let root = try makeTempRoot("deferred-refusal")
        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(
            dataRoot: root, recorder: recorder, configureTerminate: false
        )
        let (envelope, armTerminate) = await coordinator.requestRestartDeferringTerminate(
            reason: "x", source: "test"
        )
        #expect(envString(envelope, "status") == "failed")
        #expect(armTerminate == nil)
    }

    @Test func audit_envelope_written_with_reason_and_cooldown_state() async throws {
        let root = try makeTempRoot("audit")
        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(dataRoot: root, recorder: recorder)

        let envelope = await coordinator.requestRestart(reason: "memory pressure", source: "chat:mac")
        let auditPath = try #require(envString(envelope, "audit_path"))
        let data = try Data(contentsOf: URL(fileURLWithPath: auditPath))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(obj["reason"] as? String == "memory pressure")
        #expect(obj["source"] as? String == "chat:mac")
        #expect(obj["toolName"] as? String == "restart_app")
        #expect(obj["requestedAt"] as? String != nil)
        #expect(obj["pid"] as? Int == 4242)
        // First-ever restart: cooldown state records no prior stamp.
        #expect(obj["lastRestartAt"] is NSNull || obj["lastRestartAt"] == nil)
    }

    @Test func cooldown_refuses_inside_window_and_allows_after() async throws {
        let root = try makeTempRoot("cooldown")
        let recorder = RestartRecorder()

        // First restart fires at t0.
        let t0 = Date()
        let first = makeCoordinator(dataRoot: root, recorder: recorder, now: { t0 })
        let ok = await first.requestRestart(reason: "first", source: "test")
        #expect(envString(ok, "status") == "restarting")

        // Second request 60s later: inside the 600s window → honest refusal.
        let blockedRecorder = RestartRecorder()
        let blocked = makeCoordinator(
            dataRoot: root, recorder: blockedRecorder, now: { t0.addingTimeInterval(60) }
        )
        let refusal = await blocked.requestRestart(reason: "second", source: "test")
        #expect(envString(refusal, "status") == "failed")
        #expect(envString(refusal, "reason") == "cooldown")
        let retryAfter = try #require(envNumber(refusal, "retryAfterSeconds"))
        #expect(retryAfter > 0 && retryAfter <= AppRestartCoordinator.cooldownSeconds)
        // Refusal means no spawn, no terminate.
        #expect(blockedRecorder.events.isEmpty)

        // Third request 601s later: window elapsed → allowed again.
        let lateRecorder = RestartRecorder()
        let late = makeCoordinator(
            dataRoot: root, recorder: lateRecorder,
            now: { t0.addingTimeInterval(AppRestartCoordinator.cooldownSeconds + 1) }
        )
        let again = await late.requestRestart(reason: "third", source: "test")
        #expect(envString(again, "status") == "restarting")
        #expect(lateRecorder.events == ["spawn", "terminate_scheduled"])
    }

    @Test func relauncher_command_construction() {
        let argv = AppRestartCoordinator.relauncherArgv(
            pid: 4242, appPath: "/Users/example/Applications/NativeAgent.app"
        )
        #expect(argv.count == 3)
        #expect(argv[0] == "/bin/sh")
        #expect(argv[1] == "-c")
        let script = argv[2]
        // Polls OUR pid, bounded at 30 iterations, then execs `open`.
        #expect(script.contains("/bin/kill -0 4242"))
        #expect(script.contains("-ge \(AppRestartCoordinator.relauncherPollSeconds)"))
        #expect(script.contains("/bin/sleep 1"))
        #expect(script.contains("exec /usr/bin/open '/Users/example/Applications/NativeAgent.app'"))
    }

    @Test func unconfigured_terminate_refuses_honestly() async throws {
        let root = try makeTempRoot("unconfigured")
        let recorder = RestartRecorder()
        let coordinator = makeCoordinator(
            dataRoot: root, recorder: recorder, configureTerminate: false
        )

        let envelope = await coordinator.requestRestart(reason: "x", source: "test")
        #expect(envString(envelope, "status") == "failed")
        #expect(envString(envelope, "reason") == "restart_unavailable")
        // Fail closed: no spawn, no audit, no stamp.
        #expect(recorder.events.isEmpty)
        let stamp = root
            .appendingPathComponent("restart_audit", isDirectory: true)
            .appendingPathComponent("last_restart.json")
        #expect(!FileManager.default.fileExists(atPath: stamp.path))
    }

    @Test func spawn_failure_rolls_back_stamp_so_retry_is_not_blocked() async throws {
        let root = try makeTempRoot("spawnfail")
        let recorder = RestartRecorder()
        let failing = makeCoordinator(dataRoot: root, recorder: recorder, spawnError: true)

        let envelope = await failing.requestRestart(reason: "x", source: "test")
        #expect(envString(envelope, "status") == "failed")
        #expect(envString(envelope, "reason") == "relauncher_spawn_failed")
        // No terminate armed for a restart that never fired.
        #expect(recorder.terminateGraces.isEmpty)
        // Stamp rolled back: an immediate retry with a working spawner succeeds.
        let retryRecorder = RestartRecorder()
        let retry = makeCoordinator(dataRoot: root, recorder: retryRecorder)
        let second = await retry.requestRestart(reason: "retry", source: "test")
        #expect(envString(second, "status") == "restarting")
    }

    // L4 sanity: the FileAccessGatedDispatcher block lists cover app lifecycle tools
    // in BOTH none and read_only modes (defense in depth below the catalog gate).
    @Test func file_access_gate_blocks_app_lifecycle_tools_in_none_and_read_only() async throws {
        final class StubInner: ToolDispatchClient, @unchecked Sendable {
            func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
                .object(["status": .string("reached_inner")])
            }
            func listAvailableTools() async throws -> [String] { ["restart_app", "install_app"] }
            func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
        }
        for mode in ["none", "read_only"] {
            for tool in ["restart_app", "install_app"] {
                let gated = FileAccessGatedDispatcher(inner: StubInner(), fileAccess: mode)
                await #expect(throws: (any Error).self, "fileAccess=\(mode) must block \(tool)") {
                    _ = try await gated.dispatch(tool: tool, input: [:], surface: "chat")
                }
            }
        }
    }
}
