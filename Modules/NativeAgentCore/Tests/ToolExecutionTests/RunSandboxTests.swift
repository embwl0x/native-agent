import Testing
import Foundation
import CryptoKit
import Darwin
@testable import ToolExecution
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func makeTempTool(
    entrypointBody: String,
    entrypointName: String = "tool.swift",
    manifestExtras: String = "",
    includeTests: Bool = true
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest = """
    {"id":"t","name":"t","entrypoint":"\(entrypointName)","timeoutSeconds":10\(manifestExtras.isEmpty ? "" : ",\(manifestExtras)")}
    """
    try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
    try Data(entrypointBody.utf8).write(to: dir.appendingPathComponent(entrypointName))
    if includeTests {
        try Data("[]".utf8).write(to: dir.appendingPathComponent("tests.json"))
    }
    return dir
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func processExists(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processExists(pid) { return true }
        usleep(50_000)
    }
    return !processExists(pid)
}

private func killProcessGroupOrPid(_ pid: pid_t) {
    guard pid > 0 else { return }
    if killpg(pid, SIGKILL) != 0 {
        _ = kill(pid, SIGKILL)
    }
}

/// Thread-safe sink for the escalation observer — appended from the reap
/// thread, read on the test's actor.
private final class EscalationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ToolRunEscalationEvent] = []
    func append(_ e: ToolRunEscalationEvent) { lock.lock(); events.append(e); lock.unlock() }
    func snapshot() -> [ToolRunEscalationEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

/// One-shot action latch: `fire()` runs the armed action exactly once, from
/// whichever of arm/fire happens second — so an escalation observer can cancel
/// a Task that is created after the observer is installed, race-free.
private final class OneShotAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var fired = false
    func arm(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let alreadyFired = fired
        lock.unlock()
        if alreadyFired { action() }
    }
    func fire() {
        lock.lock()
        fired = true
        let action = action
        self.action = nil
        lock.unlock()
        action?()
    }
}

// MARK: - Tests

@Test func runTool_returns_stdout_for_simple_echo_tool() async throws {
    let body = """
    import Foundation
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "{}"
    print("{\\"echo\\":\\(raw)}")
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let sandbox = ToolRunSandbox(toolRoot: toolRoot)
    let input: JSONValue = .object(["hi": .string("there")])
    let result = try await runner.runTool(
        sandbox: sandbox, input: input,
        expectedFingerprint: nil, actualFingerprint: nil
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("echo"))
}

@Test func runTool_parses_stdout_JSON_into_parsedOutput() async throws {
    let body = """
    print("{\\"ok\\":true,\\"n\\":7}")
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: .object([:]),
        expectedFingerprint: nil, actualFingerprint: nil
    )
    guard case .some(.object(let obj)) = result.parsedOutput else {
        Issue.record("expected parsed object, got \(String(describing: result.parsedOutput))")
        return
    }
    #expect(obj["ok"] == .bool(true))
    #expect(obj["n"] == .int(7))
}

@Test func runTool_returns_nil_parsedOutput_for_non_JSON_stdout() async throws {
    let body = """
    print("not json at all, sorry")
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: .object([:]),
        expectedFingerprint: nil, actualFingerprint: nil
    )
    #expect(result.parsedOutput == nil)
    #expect(result.exitCode == 0)
}

@Test func runTool_captures_stderr_separately() async throws {
    let body = """
    import Foundation
    FileHandle.standardError.write(Data("warning: something".utf8))
    print("{}")
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: .object([:]),
        expectedFingerprint: nil, actualFingerprint: nil
    )
    #expect(result.stderr.contains("warning"))
    #expect(!result.stdout.contains("warning"))
}

@Test func runTool_non_zero_exit_throws_nonZeroExit() async throws {
    let body = """
    import Foundation
    import Darwin
    FileHandle.standardError.write(Data("boom".utf8))
    exit(3)
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    do {
        _ = try await runner.runTool(
            sandbox: ToolRunSandbox(toolRoot: toolRoot),
            input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
        Issue.record("expected nonZeroExit error")
    } catch ToolRunError.nonZeroExit(let code, let stderr) {
        #expect(code == 3)
        #expect(stderr.contains("boom"))
    }
}

@Test func runTool_timeout_kills_and_throws_timeout() async throws {
    let body = """
    import Foundation
    Thread.sleep(forTimeInterval: 60)
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let sandbox = ToolRunSandbox(toolRoot: toolRoot, timeoutSeconds: 1)
    do {
        _ = try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
        Issue.record("expected timeout error")
    } catch ToolRunError.timeout {
        // expected
    }
}

@Test func runTool_timeout_sigkills_term_ignoring_tool() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-\(UUID().uuidString).pid")
    let body = """
    printf '%s\\n' "$$" > \(shellSingleQuoted(pidURL.path))
    trap '' TERM
    # Orphan-proof (2026-07-02): an interrupted swift-test (SIGKILL — worker
    # timeout, kill mid-suite) skips Swift defers, and this loop ignores TERM by
    # design — so it must self-terminate: exit when the spawning test process
    # dies (kill -0 $PPID) or after a 120s hard cap. Six of these burned 100%
    # CPU for User after two interrupted runs.
    while kill -0 $PPID 2>/dev/null && [ "${SECONDS:-0}" -lt 120 ]; do :; done
    """
    let toolRoot = try makeTempTool(entrypointBody: body, entrypointName: "tool.sh")
    var spawnedPid: pid_t?
    defer {
        if let spawnedPid {
            killProcessGroupOrPid(spawnedPid)
        }
        try? FileManager.default.removeItem(at: pidURL)
    }
    let runner = ToolRunSandboxRunner()
    let sandbox = ToolRunSandbox(
        toolRoot: toolRoot,
        entrypoint: "tool.sh",
        timeoutSeconds: 1,
        executableCommand: "/bin/sh"
    )
    let started = Date()
    do {
        _ = try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
        Issue.record("expected timeout error")
    } catch ToolRunError.timeout {
        #expect(Date().timeIntervalSince(started) < 20)
        let rawPid = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = pid_t(rawPid) ?? -1
        spawnedPid = pid
        #expect(waitForProcessExit(pid, timeout: 3), "TERM-ignoring tool pid \(pid) was still running after sandbox timeout")
    }
}

@Test func runTool_missing_entrypoint_throws_entrypointMissing() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let runner = ToolRunSandboxRunner()
    do {
        _ = try await runner.runTool(
            sandbox: ToolRunSandbox(toolRoot: dir),
            input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
        Issue.record("expected entrypointMissing")
    } catch ToolRunError.entrypointMissing {
        // expected
    }
}

@Test func runTool_fingerprint_mismatch_throws_fingerprintMismatch() async throws {
    let body = "print(\"{}\")\n"
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    do {
        _ = try await runner.runTool(
            sandbox: ToolRunSandbox(toolRoot: toolRoot),
            input: .object([:]),
            expectedFingerprint: "deadbeef",
            actualFingerprint: "feedface"
        )
        Issue.record("expected fingerprintMismatch")
    } catch ToolRunError.fingerprintMismatch(let expected, let actual) {
        #expect(expected == "deadbeef")
        #expect(actual == "feedface")
    }
}

@Test func runTool_fingerprint_match_proceeds_normally() async throws {
    let body = "print(\"{\\\"ok\\\": true}\")\n"
    let toolRoot = try makeTempTool(entrypointBody: body)
    let fp = computeToolCodeFingerprint(toolRoot: toolRoot, entrypointName: "tool.swift")
    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: .object([:]),
        expectedFingerprint: fp, actualFingerprint: fp
    )
    #expect(result.exitCode == 0)
}

@Test func runTool_input_serialized_as_valid_JSON_on_stdin() async throws {
    let body = """
    import Foundation
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(raw)
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let input: JSONValue = .object(["a": .int(1), "b": .int(2)])
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: input,
        expectedFingerprint: nil, actualFingerprint: nil
    )
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = Data(trimmed.utf8)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Int]
    #expect(parsed == ["a": 1, "b": 2])
}

@Test func computeToolCodeFingerprint_matches_expected_hash() async throws {
    let body = "print(\"hello\")\n"
    let toolRoot = try makeTempTool(entrypointBody: body)
    let swiftFp = computeToolCodeFingerprint(toolRoot: toolRoot, entrypointName: "tool.swift")

    var digest = SHA256()
    for path in [
        toolRoot.appendingPathComponent("manifest.json"),
        toolRoot.appendingPathComponent("tool.swift"),
        toolRoot.appendingPathComponent("tests.json"),
    ] {
        digest.update(data: Data(path.lastPathComponent.utf8))
        digest.update(data: Data([0]))
        if let bytes = try? Data(contentsOf: path) {
            digest.update(data: bytes)
        }
        digest.update(data: Data([0]))
    }
    let expected = digest.finalize().map { String(format: "%02x", $0) }.joined()
    #expect(swiftFp == expected)
}

@Test func computeToolCodeFingerprint_changes_when_entrypoint_modified() async throws {
    let toolRoot = try makeTempTool(entrypointBody: "print(\"v1\")\n")
    let fp1 = computeToolCodeFingerprint(toolRoot: toolRoot, entrypointName: "tool.swift")
    try Data("print(\"v2\")\n".utf8).write(to: toolRoot.appendingPathComponent("tool.swift"))
    let fp2 = computeToolCodeFingerprint(toolRoot: toolRoot, entrypointName: "tool.swift")
    #expect(fp1 != fp2)
}

// MARK: - W3d (R2b): Task cancellation reaps the subprocess promptly

/// A cancelled Task running a sleep-forever tool must (1) surface
/// CancellationError promptly (< 3s, well under the sandbox's own 60s
/// timeout), and (2) leave NO orphaned subprocess — the child pid must be
/// gone. The tool writes its own pid to a file so we can prove the reap.
@Test func runTool_taskCancellation_reapsSubprocess_promptly() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-cancel-\(UUID().uuidString).pid")
    let body = """
    printf '%s\\n' "$$" > \(shellSingleQuoted(pidURL.path))
    # Orphan-proof: self-terminates on parent death / 120s cap (see the
    # busy-loop fixtures for the full rationale).
    while kill -0 $PPID 2>/dev/null && [ "${SECONDS:-0}" -lt 120 ]; do sleep 1; done
    """
    let toolRoot = try makeTempTool(entrypointBody: body, entrypointName: "tool.sh")
    var spawnedPid: pid_t?
    defer {
        if let spawnedPid { killProcessGroupOrPid(spawnedPid) }
        try? FileManager.default.removeItem(at: pidURL)
    }
    let runner = ToolRunSandboxRunner()
    // 60s sandbox timeout — far longer than the cancel path should take, so a
    // prompt return proves cancellation (not the watchdog) unblocked us.
    let sandbox = ToolRunSandbox(
        toolRoot: toolRoot,
        entrypoint: "tool.sh",
        timeoutSeconds: 60,
        executableCommand: "/bin/sh"
    )

    let task = Task<ToolRunResult, Error> {
        try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
    }

    // Wait for the child to actually spawn (its pid file to appear) before
    // cancelling, so we exercise the mid-wait cancel path, not the pre-spawn
    // Task.checkCancellation shortcut.
    var pid: pid_t = -1
    for _ in 0..<200 {  // 10s deadline — spawn is a positive step under suite load
        if let raw = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let p = pid_t(raw), p > 0 {
            pid = p
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(pid > 0, "tool subprocess never wrote its pid; cannot prove reap")
    spawnedPid = pid
    #expect(processExists(pid), "child should be alive right before cancel")

    let started = Date()
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected CancellationError from cancelled runTool")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
    let elapsed = Date().timeIntervalSince(started)
    // 10s, not 3s: still far under the tool's wedge it must beat, while a 3s
    // bound loses to scheduler noise under full-suite parallelism.
    #expect(elapsed < 10, "cancellation should return promptly; took \(elapsed)s")
    #expect(
        waitForProcessExit(pid, timeout: 3),
        "cancelled tool pid \(pid) must be reaped, not orphaned"
    )
}

/// A tool that traps SIGTERM must still be reaped on cancel — the escalation
/// path SIGKILLs after the grace window. Same prompt-return + no-orphan
/// contract as above.
@Test func runTool_taskCancellation_sigkills_term_ignoring_tool() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-cancel-term-\(UUID().uuidString).pid")
    let body = """
    printf '%s\\n' "$$" > \(shellSingleQuoted(pidURL.path))
    trap '' TERM
    # Orphan-proof (2026-07-02): an interrupted swift-test (SIGKILL — worker
    # timeout, kill mid-suite) skips Swift defers, and this loop ignores TERM by
    # design — so it must self-terminate: exit when the spawning test process
    # dies (kill -0 $PPID) or after a 120s hard cap. Six of these burned 100%
    # CPU for User after two interrupted runs.
    while kill -0 $PPID 2>/dev/null && [ "${SECONDS:-0}" -lt 120 ]; do :; done
    """
    let toolRoot = try makeTempTool(entrypointBody: body, entrypointName: "tool.sh")
    var spawnedPid: pid_t?
    defer {
        if let spawnedPid { killProcessGroupOrPid(spawnedPid) }
        try? FileManager.default.removeItem(at: pidURL)
    }
    let runner = ToolRunSandboxRunner()
    let sandbox = ToolRunSandbox(
        toolRoot: toolRoot,
        entrypoint: "tool.sh",
        timeoutSeconds: 60,
        executableCommand: "/bin/sh"
    )
    let task = Task<ToolRunResult, Error> {
        try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
    }
    var pid: pid_t = -1
    for _ in 0..<200 {  // 10s deadline — spawn is a positive step under suite load
        if let raw = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let p = pid_t(raw), p > 0 {
            pid = p
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(pid > 0, "TERM-ignoring tool never wrote its pid")
    spawnedPid = pid

    let started = Date()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected CancellationError")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
    // SIGTERM ignored → SIGKILL after ~200ms grace. 10s, not 3s: the bound
    // only needs to beat the tool's wedge; 3s lost to scheduler noise.
    #expect(Date().timeIntervalSince(started) < 10)
    #expect(
        waitForProcessExit(pid, timeout: 3),
        "TERM-ignoring tool pid \(pid) must be SIGKILLed on cancel, not orphaned"
    )
}

/// Cancelling BEFORE the wait (already-cancelled Task) must throw
/// CancellationError without hanging — exercises the early
/// Task.checkCancellation shortcut / immediate onCancel.
@Test func runTool_preCancelledTask_throwsCancellation() async throws {
    let body = """
    # Orphan-proof: self-terminates on parent death / 120s cap (see the
    # busy-loop fixtures for the full rationale).
    while kill -0 $PPID 2>/dev/null && [ "${SECONDS:-0}" -lt 120 ]; do sleep 1; done
    """
    let toolRoot = try makeTempTool(entrypointBody: body, entrypointName: "tool.sh")
    let runner = ToolRunSandboxRunner()
    let sandbox = ToolRunSandbox(
        toolRoot: toolRoot, entrypoint: "tool.sh",
        timeoutSeconds: 60, executableCommand: "/bin/sh"
    )
    let task = Task<ToolRunResult, Error> {
        // Yield once so cancel() below can land before runTool starts.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected CancellationError from pre-cancelled Task")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
}

/// Uncancelled happy path is unchanged — a normal tool still returns its
/// result with no CancellationError leaking in.
@Test func runTool_noCancellation_returnsNormally() async throws {
    let body = """
    print("{\\"ok\\":true}")
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: .object([:]),
        expectedFingerprint: nil, actualFingerprint: nil
    )
    #expect(result.exitCode == 0)
    #expect(result.timedOut == false)
}

// MARK: - W3d review finding 1: cancel during the SIGTERM→SIGKILL grace

/// Regression for the terminationSignal double-duty bug: a Task cancelled
/// DURING the escalation grace window (after a TIMEOUT already fired SIGTERM
/// on a TERM-trapping child) must STILL reach SIGKILL and reap the child.
/// Under the old code `onCancel` signalled the same semaphore the grace-wait
/// consumed, so a cancel arriving mid-grace ended the wait early and the
/// SIGKILL was skipped. We widen the grace window via a test seam so the
/// cancel lands deterministically inside it, and assert via the escalation
/// observer that SIGKILL actually fired after a TIMEOUT-triggered SIGTERM.
@Test func runTool_cancelDuringGrace_stillSigkillsAndReaps() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-grace-\(UUID().uuidString).pid")
    let body = """
    printf '%s\\n' "$$" > \(shellSingleQuoted(pidURL.path))
    trap '' TERM
    # Orphan-proof (2026-07-02): an interrupted swift-test (SIGKILL — worker
    # timeout, kill mid-suite) skips Swift defers, and this loop ignores TERM by
    # design — so it must self-terminate: exit when the spawning test process
    # dies (kill -0 $PPID) or after a 120s hard cap. Six of these burned 100%
    # CPU for User after two interrupted runs.
    while kill -0 $PPID 2>/dev/null && [ "${SECONDS:-0}" -lt 120 ]; do :; done
    """
    let toolRoot = try makeTempTool(entrypointBody: body, entrypointName: "tool.sh")
    var spawnedPid: pid_t?
    defer {
        if let spawnedPid { killProcessGroupOrPid(spawnedPid) }
        try? FileManager.default.removeItem(at: pidURL)
    }
    let runner = ToolRunSandboxRunner()
    // Widen the SIGTERM→SIGKILL grace to 3s so the cancel (fired from the
    // escalation observer on .sigterm) has a roomy window to prove it did NOT
    // shortcut the SIGKILL.
    await runner._setEscalationGraceMillis(3000)

    // Record the escalation timeline off the reap thread — and cancel the
    // runner task synchronously the moment SIGTERM fires. The observer runs on
    // the reap thread after `.sigterm` is emitted but BEFORE the grace-wait
    // consumes `terminationSignal`, so the cancel lands inside the grace window
    // by construction, with no scheduler-timing dependence. (A blind 1.3s sleep
    // raced the 1s timeout under full-suite parallel load and produced
    // cancelled:true; a test-side poll for .sigterm still left a late-wake vs
    // 3s-grace race. Under the old single-semaphore bug, a cancel signal armed
    // right here is exactly what shortcut the SIGKILL.)
    let events = EscalationLog()
    let cancelOnSigterm = OneShotAction()
    await runner._setEscalationObserver { event in
        events.append(event)
        if event == .sigterm { cancelOnSigterm.fire() }
    }

    // 1s sandbox timeout — the TIMEOUT (not the cancel) is what fires SIGTERM.
    let sandbox = ToolRunSandbox(
        toolRoot: toolRoot, entrypoint: "tool.sh",
        timeoutSeconds: 1, executableCommand: "/bin/sh"
    )
    let task = Task<ToolRunResult, Error> {
        try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
    }
    // Arm the cancel-on-SIGTERM latch (SIGTERM can't beat this: the runner's
    // 1s timeout must elapse first).
    cancelOnSigterm.arm { task.cancel() }
    // Wait for the child to spawn.
    var pid: pid_t = -1
    for _ in 0..<200 {  // 10s deadline — spawn is a positive step under suite load
        if let raw = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let p = pid_t(raw), p > 0 {
            pid = p
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(pid > 0, "TERM-trapping tool never wrote its pid")
    spawnedPid = pid

    // Await the run. Bounded by the runner's own escalation deadlines
    // (1s timeout → 3s grace → SIGKILL → 2s+1s backstops); if the timeout
    // never fires the run returns a normal result and the Issue below records
    // it loudly — no unbounded path.
    do {
        _ = try await task.value
        Issue.record("expected CancellationError from cancel-during-grace")
    } catch is CancellationError {
        // expected — cancel takes priority over the timeout error.
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }

    // The child must be dead (SIGKILL reached it — it traps TERM).
    #expect(
        waitForProcessExit(pid, timeout: 3),
        "TERM-trapping child must be SIGKILLed even when cancel lands mid-grace"
    )
    // And the timeline must prove it: the escalation was TIMEOUT-triggered and
    // still reached SIGKILL — i.e. the cancel did NOT shortcut the grace.
    let log = events.snapshot()
    #expect(
        log.contains(.initialWaitEnded(exited: false, cancelled: false, timedOut: true)),
        "escalation must have been triggered by the timeout, not the cancel; got \(log)"
    )
    #expect(log.contains(.sigkill),
            "SIGKILL must fire after a TIMEOUT-triggered SIGTERM even under a mid-grace cancel; got \(log)")
}

// MARK: - W3d review finding 2: cancel reaps grandchildren via the group kill

/// A cancelled tool that spawned a background GRANDCHILD must have that
/// grandchild reaped too — the reap targets the child's process group
/// (`killpg`), not just the direct child. The script writes the grandchild's
/// pid to a file so we can prove it's gone after the cancel.
@Test func runTool_taskCancellation_reapsGrandchild() async throws {
    let gcURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-gc-\(UUID().uuidString).pid")
    let childURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunSandboxTests-gcchild-\(UUID().uuidString).pid")
    let body = """
    printf '%s\\n' "$$" > \(shellSingleQuoted(childURL.path))
    sleep 300 &
    printf '%s\\n' "$!" > \(shellSingleQuoted(gcURL.path))
    # Orphan-proof: self-terminates on parent death / 120s cap (see the
    # busy-loop fixtures for the full rationale).
    while kill -0 $PPID 2>/dev/null && [ "${SECONDS:-0}" -lt 120 ]; do sleep 1; done
    """
    let toolRoot = try makeTempTool(entrypointBody: body, entrypointName: "tool.sh")
    var childPid: pid_t?
    var gcPid: pid_t?
    defer {
        if let childPid { killProcessGroupOrPid(childPid) }
        if let gcPid { _ = kill(gcPid, SIGKILL) }
        try? FileManager.default.removeItem(at: gcURL)
        try? FileManager.default.removeItem(at: childURL)
    }
    let runner = ToolRunSandboxRunner()
    let sandbox = ToolRunSandbox(
        toolRoot: toolRoot, entrypoint: "tool.sh",
        timeoutSeconds: 60, executableCommand: "/bin/sh"
    )
    let task = Task<ToolRunResult, Error> {
        try await runner.runTool(
            sandbox: sandbox, input: .object([:]),
            expectedFingerprint: nil, actualFingerprint: nil
        )
    }
    // Wait for BOTH the child and grandchild pid files.
    var child: pid_t = -1
    var gc: pid_t = -1
    for _ in 0..<120 {
        if child <= 0, let raw = try? String(contentsOf: childURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let p = pid_t(raw), p > 0 { child = p }
        if gc <= 0, let raw = try? String(contentsOf: gcURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let p = pid_t(raw), p > 0 { gc = p }
        if child > 0 && gc > 0 { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(child > 0, "tool child never wrote its pid")
    #expect(gc > 0, "grandchild never wrote its pid")
    childPid = child
    gcPid = gc
    #expect(processExists(gc), "grandchild should be alive right before cancel")

    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected CancellationError")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
    // The GRANDCHILD must be reaped by the group kill, not left orphaned.
    #expect(
        waitForProcessExit(gc, timeout: 4),
        "grandchild pid \(gc) must be reaped by the process-group kill on cancel"
    )
    #expect(
        waitForProcessExit(child, timeout: 2),
        "direct child pid \(child) must also be reaped"
    )
}

@Test func runTool_largeOutput_drains_without_deadlock() async throws {
    // Regression (audit 2026-06-09): pipes were read only AFTER
    // waitUntilExit, so any tool emitting more than the ~64KB pipe buffer
    // blocked in write(2), never exited, and was killed by the watchdog —
    // the run misreported as a timeout with the real output discarded.
    // 256KB of stdout must come back intact, fast, with exit 0.
    let body = """
    print(String(repeating: "x", count: 262_144))
    """
    let toolRoot = try makeTempTool(entrypointBody: body)
    let runner = ToolRunSandboxRunner()
    let result = try await runner.runTool(
        sandbox: ToolRunSandbox(toolRoot: toolRoot),
        input: .object([:]),
        expectedFingerprint: nil, actualFingerprint: nil
    )
    #expect(result.exitCode == 0)
    #expect(result.timedOut == false)
    #expect(result.stdout.count >= 262_144)
}
