import Foundation
import Testing

// MARK: - Hang-proof subprocess runner for SelfImprovementTests helpers
//
// Replaces the per-file `Pipe() + waitUntilExit()` helpers. Two hazards those
// had (see RunSandboxTests.swift `runTool_largeOutput_drains_without_deadlock`
// and the 2026-07-01 flock-helper hardening):
//   1. Pipes read only AFTER waitUntilExit — a child emitting more than the
//      ~64KB pipe buffer blocks in write(2), never exits, and wedges the
//      serial suite.
//   2. waitUntilExit is unbounded — a wedged child hangs the whole run.
// Here both pipes are drained concurrently while the child runs, and the wait
// polls `isRunning` under a deadline with SIGTERM → grace → SIGKILL
// escalation through the Process object (never a stored raw pid).

struct BoundedProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct BoundedProcessTimeout: Error, CustomStringConvertible {
    let argv: [String]
    let waited: TimeInterval
    let stderr: String
    var description: String {
        "subprocess timed out after \(String(format: "%.1f", waited))s: "
            + "`\(argv.joined(separator: " "))` — stderr: "
            + (stderr.isEmpty ? "<empty>" : stderr)
    }
}

/// Drains one pipe to EOF on a dedicated Thread. EOF is guaranteed once the
/// child is dead (the kill escalation closes the write end), so `awaitData`
/// only blocks meaningfully while the child is alive.
///
/// A dedicated Thread, NOT DispatchQueue.global(): this suite runs many
/// subprocesses concurrently (candidate-builder tests spawn real swift
/// builds) and the GCD pool starves under that load — a queued drain that
/// hasn't started when the post-exit wait expires silently yielded empty
/// stdout (observed 2026-07-02 as `git reset --hard ''` / empty-sha
/// failures across GitOpsTests).
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        let thread = Thread { [self] in
            // Incremental reads into the locked buffer (not one
            // readDataToEndOfFile) so a timeout diagnostic can still see
            // whatever the child wrote before it wedged — EOF-only
            // publishing would report "<empty>" stderr for a child that
            // logged plenty and then hung.
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            done.signal()
        }
        thread.name = "SubprocessTestSupport.PipeDrain"
        thread.start()
    }

    /// Returns nil if the drain hasn't hit EOF within `timeout`.
    func awaitData(timeout: TimeInterval) -> Data? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    /// Best-effort view of what's been read so far — for timeout diagnostics
    /// when EOF never arrived.
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Run `/usr/bin/env <argv>` with both pipes drained concurrently and a
/// bounded wait. Throws BoundedProcessTimeout (with stderr + duration) if the
/// child outlives `timeout`; the child is SIGTERM→SIGKILLed first so nothing
/// leaks past the failure.
@discardableResult
func runBoundedProcess(
    _ argv: [String], cwd: URL? = nil, timeout: TimeInterval = 60
) throws -> BoundedProcessResult {
    let p = Process()
    p.launchPath = "/usr/bin/env"
    p.arguments = argv
    if let cwd { p.currentDirectoryURL = cwd }
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    let outDrain = PipeDrain(outPipe)
    let errDrain = PipeDrain(errPipe)

    let start = Date()
    let exitedOnItsOwn = pollExitBounded(p, deadline: timeout)
    // Exit is observed (or the child was killed) — EOF on both pipes is now
    // imminent; the drain wait is a formality with a safety margin.
    guard exitedOnItsOwn else {
        // EOF may never arrive on a killed/wedged child — use the partial
        // snapshot so the diagnostic carries whatever stderr made it out.
        _ = errDrain.awaitData(timeout: 1)
        throw BoundedProcessTimeout(
            argv: argv, waited: Date().timeIntervalSince(start),
            stderr: String(data: errDrain.snapshot(), encoding: .utf8) ?? ""
        )
    }
    let out = outDrain.awaitData(timeout: 10)
    let err = errDrain.awaitData(timeout: 10)
    let stdout = String(data: out ?? Data(), encoding: .utf8) ?? ""
    let stderr = String(data: err ?? Data(), encoding: .utf8) ?? ""
    // Undrained pipes after a normal exit mean something (a live grandchild?)
    // still holds the write end. Returning partial/empty output here corrupts
    // the caller silently — fail loudly instead.
    guard out != nil, err != nil else {
        throw NSError(domain: "proc", code: 125, userInfo: [NSLocalizedDescriptionKey:
            "pipes not drained within 10s after exit: `\(argv.joined(separator: " "))`"])
    }
    return BoundedProcessResult(status: p.terminationStatus, stdout: stdout, stderr: stderr)
}

/// Bounded replacement for waitUntilExit(): poll `isRunning` to the deadline,
/// then SIGTERM → 2s grace → SIGKILL, all through the live Process object.
/// Returns true iff the process exited on its own before the deadline.
private func pollExitBounded(_ p: Process, deadline: TimeInterval) -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    if !p.isRunning { return true }
    p.terminate()
    let grace = Date().addingTimeInterval(2)
    while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning {
        kill(p.processIdentifier, SIGKILL)
        let killEnd = Date().addingTimeInterval(2)
        while p.isRunning && Date() < killEnd { Thread.sleep(forTimeInterval: 0.02) }
    }
    return false
}

// MARK: - Self-tests (pin the two contracts the runner exists for)

@Suite("SubprocessTestSupport")
struct SubprocessTestSupportTests {
    @Test func largeOutput_drains_without_deadlock() throws {
        // >64KB on BOTH pipes — the exact shape that wedged waitUntilExit.
        let r = try runBoundedProcess([
            "/bin/sh", "-c",
            "head -c 262144 /dev/zero | tr '\\000' 'x'; head -c 262144 /dev/zero | tr '\\000' 'y' >&2",
        ], timeout: 30)
        #expect(r.status == 0)
        #expect(r.stdout.count == 262_144)
        #expect(r.stderr.count == 262_144)
    }

    @Test func timeout_fails_loudly_and_reaps_the_child() throws {
        do {
            _ = try runBoundedProcess(
                ["/bin/sh", "-c", "printf 'holding\\n' >&2; sleep 600"],
                timeout: 1
            )
            Issue.record("expected BoundedProcessTimeout")
        } catch let e as BoundedProcessTimeout {
            #expect(e.description.contains("holding"), "diagnostic must carry stderr: \(e)")
        }
    }
}
