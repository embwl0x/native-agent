import Foundation
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — row `public-api.AppRelauncher.relaunchApp`.
//
// "Restart App" spawns a DETACHED /bin/sh helper that polls until this process
// has exited and then `open`s the bundle. The ledger names two silent modes:
// the helper opens the bundle while the old process is still alive (macOS
// treats that as activate-not-relaunch, so Restart quietly becomes Quit), and
// a bundle path with spaces or shell metacharacters is mangled.
//
// Both are testable for real. The app exposes its pure relaunch-helper builder;
// this file executes that exact production script against a controlled pid and
// a recorder standing in for `/usr/bin/open`. The only edit is that single
// substitution, and the test asserts it matched exactly once — so a rewrite of
// the script that drops `/usr/bin/open` fails here rather than passing
// vacuously.
//
// Hang-proofing: no unbounded waits. Every wait polls a marker file (or the
// Process object) against a deadline, and every spawned child is escalated to
// SIGKILL in a defer.

// MARK: - harness

private struct RelaunchHarness {
    let root: URL
    let recorderPath: URL
    let receiptPath: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("na-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recorderPath = root.appendingPathComponent("open-recorder.sh")
        receiptPath = root.appendingPathComponent("open-receipt.txt")

        // Stands in for /usr/bin/open: records its single argument VERBATIM
        // (printf %s, no interpolation) so an argument-mangling regression is
        // visible byte for byte.
        let recorder = "#!/bin/sh\nprintf '%s' \"$1\" > '\(receiptPath.path)'\n"
        try recorder.write(to: recorderPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: recorderPath.path
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    var receipt: String? {
        guard let data = FileManager.default.contents(atPath: receiptPath.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Poll for the recorder receipt up to `deadline` seconds. Returns nil on
    /// timeout rather than blocking forever.
    func awaitReceipt(deadline: TimeInterval) -> String? {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let r = receipt { return r }
            usleep(30_000)
        }
        return receipt
    }
}

/// The exact script passed to the detached helper in production.
private func shippedRelaunchScript() -> String {
    AppRelauncher.relaunchHelperScript()
}

private func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = text.startIndex..<text.endIndex
    while let match = text.range(of: needle, range: searchRange) {
        count += 1
        searchRange = match.upperBound..<text.endIndex
    }
    return count
}

/// Spawn `/bin/sh -c <script> relaunch <pid> <bundlePath>` exactly as the app
/// does, with `/usr/bin/open` swapped for the recorder.
@discardableResult
private func launchHelper(
    script: String, harness: RelaunchHarness, pid: Int32, bundlePath: String
) throws -> Process {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", script, "relaunch", String(pid), bundlePath]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    return task
}

/// A child that lives until it is killed. Returns the Process (never the raw
/// pid — pid reuse would make the later kill dangerous).
private func spawnLongLivedChild() throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 120"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
}

private func waitBounded(_ p: Process, deadline: TimeInterval) -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if !p.isRunning { return true }
        usleep(30_000)
    }
    return !p.isRunning
}

private func killBounded(_ p: Process) {
    guard p.isRunning else { return }
    p.terminate()
    if !waitBounded(p, deadline: 2), p.isRunning { kill(p.processIdentifier, SIGKILL) }
    _ = waitBounded(p, deadline: 2)
}

// MARK: - evals

@Test("the shipped relaunch script is exactly one wait-for-pid loop feeding one open")
func relaunchScript_hasTheShapeTheseTestsExecute() {
    let script = shippedRelaunchScript()

    // Structural pins for the parts that cannot be executed cheaply: the wait
    // is BOUNDED (150 iterations x 0.2s ~= 30s) so a termination that never
    // completes cannot spin forever, and the pid/bundle arrive as POSITIONAL
    // args rather than being interpolated into the script body.
    #expect(script.contains("/bin/kill -0 \"$1\""))
    #expect(script.contains("-lt 150"))
    #expect(script.contains("/bin/sleep 0.2"))
    #expect(script.contains("/usr/bin/open \"$2\""))
    #expect(!script.contains("\\("), "the script interpolates a Swift value — positional args are the contract")

    #expect(
        AppRelauncher.relaunchHelperArguments(pid: 42, bundlePath: "/Applications/NativeAgent.app")
            == ["-c", script, "relaunch", "42", "/Applications/NativeAgent.app"]
    )
}

@Test("a bundle path with spaces and shell metacharacters reaches open verbatim")
func relaunchHelper_deliversTheBundlePathUnmangled() throws {
    let harness = try RelaunchHarness()
    defer { harness.cleanup() }

    var script = shippedRelaunchScript()
    #expect(occurrences(of: "/usr/bin/open", in: script) == 1)
    script = script.replacingOccurrences(of: "/usr/bin/open", with: harness.recorderPath.path)

    // Every metacharacter that a naive interpolation would honour. The canary
    // file must NOT exist afterwards: if the path were interpolated into the
    // script body, `$(…)` would execute.
    let canary = harness.root.appendingPathComponent("canary.txt")
    let nasty = "/Applications/My App $(touch '\(canary.path)') `id` \"quoted\" ;rm -rf x& .app"

    // pid 0 is never a live process we can signal, so the loop falls straight
    // through to the open — this test is about argument fidelity.
    let deadPID: Int32 = {
        // A child that has already exited: its pid is reaped, kill -0 fails.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exit 0"]
        try? p.run()
        _ = waitBounded(p, deadline: 5)
        return p.processIdentifier
    }()

    let helper = try launchHelper(script: script, harness: harness, pid: deadPID, bundlePath: nasty)
    defer { killBounded(helper) }

    let receipt = harness.awaitReceipt(deadline: 10)
    #expect(receipt == nasty, "bundle path was mangled: \(receipt ?? "<none>")")
    #expect(
        !FileManager.default.fileExists(atPath: canary.path),
        "the bundle path was evaluated by the shell — positional-arg contract broken"
    )
}

@Test("the helper does not open the bundle while the old process is still alive")
func relaunchHelper_waitsForTheProcessToDie() throws {
    let harness = try RelaunchHarness()
    defer { harness.cleanup() }

    var script = shippedRelaunchScript()
    script = script.replacingOccurrences(of: "/usr/bin/open", with: harness.recorderPath.path)

    let victim = try spawnLongLivedChild()
    defer { killBounded(victim) }

    let helper = try launchHelper(
        script: script, harness: harness,
        pid: victim.processIdentifier, bundlePath: "/Applications/NativeAgent.app"
    )
    defer { killBounded(helper) }

    // This is the "Restart quietly became Quit" mode: `open` on a running app
    // just activates it. Nothing may be recorded while the victim lives.
    let end = Date().addingTimeInterval(1.5)
    while Date() < end {
        #expect(harness.receipt == nil, "the helper opened the bundle before the process exited")
        usleep(50_000)
    }
    #expect(victim.isRunning)

    // …and once it dies, the relaunch happens promptly (the poll interval is
    // 0.2s, so anything inside a couple of seconds proves the loop is live).
    killBounded(victim)
    let receipt = harness.awaitReceipt(deadline: 10)
    #expect(receipt == "/Applications/NativeAgent.app")
}

@Test("the wait is bounded — a process that never exits still yields a relaunch")
func relaunchHelper_boundedBudgetOpensAnyway() throws {
    let harness = try RelaunchHarness()
    defer { harness.cleanup() }

    var script = shippedRelaunchScript()
    script = script.replacingOccurrences(of: "/usr/bin/open", with: harness.recorderPath.path)
    // Shorten ONLY the iteration budget so the bounded-ness is provable in
    // about a second instead of thirty. The loop, the sleep, the kill -0 probe
    // and the open are the shipped ones; the assertion above pins the real 150.
    #expect(occurrences(of: "-lt 150", in: script) == 1)
    script = script.replacingOccurrences(of: "-lt 150", with: "-lt 5")

    let victim = try spawnLongLivedChild()
    defer { killBounded(victim) }

    let helper = try launchHelper(
        script: script, harness: harness,
        pid: victim.processIdentifier, bundlePath: "/Applications/NativeAgent.app"
    )
    defer { killBounded(helper) }

    // 5 x 0.2s, then open regardless — the helper must not spin forever.
    let receipt = harness.awaitReceipt(deadline: 10)
    #expect(receipt == "/Applications/NativeAgent.app")
    #expect(waitBounded(helper, deadline: 5), "the helper did not exit after its budget")
}
