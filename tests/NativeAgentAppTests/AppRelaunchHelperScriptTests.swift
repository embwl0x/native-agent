// Fence app.background — ledger row app.background.selfRestart.relaunchApp.
//
// `AppRelauncher.relaunchApp()` cannot be called from a test process: it ends
// with NSApplication.terminate. But the load-bearing part is not the AppKit
// call — it is the detached /bin/sh helper that has to (a) actually WAIT for
// this pid to exit before `open`ing the bundle, (b) bound that wait so a
// cancelled termination cannot leave a spinner forever, and (c) receive the pid
// and bundle path as POSITIONAL arguments so a bundle path containing spaces or
// shell metacharacters survives verbatim instead of being executed.
//
// Silent-failure mode: every one of those regressions produces a "Restart App"
// click that appears to work — the app quits — and simply never comes back, or
// comes back having run whatever was embedded in the path. Nothing is logged.
//
// The test extracts the REAL script literal from the source (so an edit to the
// script is an edit to the test's input) and runs it with exactly one
// substitution, asserted below: `/usr/bin/open "$2"` is replaced by a marker
// writer, because `open` would launch a real application.

import Foundation
import Testing
@testable import NativeAgentApp

private func runBoundedShell(
    script: String,
    args: [String],
    deadline: TimeInterval
) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", script, "relaunch"] + args
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    let end = Date().addingTimeInterval(deadline)
    while task.isRunning && Date() < end {
        usleep(20_000)
    }
    if task.isRunning {
        task.terminate()
        usleep(200_000)
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        task.waitUntilExit()
        return -1
    }
    task.waitUntilExit()
    return task.terminationStatus
}

@Suite("app.background self-restart helper")
struct AppRelaunchHelperScriptTests {

    /// The exact literal from `AppRelauncher.relaunchApp()`.
    private func productionScript() throws -> String {
        let source = try AppSourceScraping.appSource("NativeAgentWindowChrome.swift")
        guard let start = source.range(of: "let script = \"") else {
            throw AppSourceScraping.ScrapeError("relaunch helper script literal not found")
        }
        var literal = ""
        var index = start.upperBound
        while index < source.endIndex {
            let ch = source[index]
            if ch == "\\" {
                let next = source.index(after: index)
                guard next < source.endIndex else { break }
                // The literal only uses \" escapes.
                literal.append(source[next])
                index = source.index(after: next)
                continue
            }
            if ch == "\"" { break }
            literal.append(ch)
            index = source.index(after: index)
        }
        return literal
    }

    /// The literal EXACTLY as written in source (escapes intact), so the test
    /// can prove no Swift interpolation was spliced into the script body.
    private func rawScriptLiteral() throws -> String {
        let source = try AppSourceScraping.appSource("NativeAgentWindowChrome.swift")
        guard let start = source.range(of: "let script = \"") else {
            throw AppSourceScraping.ScrapeError("relaunch helper script literal not found")
        }
        guard let end = source[start.upperBound...].firstIndex(of: "\n") else {
            throw AppSourceScraping.ScrapeError("unterminated script literal")
        }
        return String(source[start.upperBound..<end])
    }

    @Test("the relaunch helper takes pid and bundle path positionally and bounds its wait")
    func relaunchScriptShapeIsPinned() throws {
        let script = try productionScript()
        // Positional only: the pid and bundle path must never be interpolated
        // into the script body (that is the injection surface).
        #expect(script.contains("\"$1\""), "pid must be read positionally")
        #expect(script.contains("\"$2\""), "bundle path must be read positionally")
        let raw = try rawScriptLiteral()
        #expect(!raw.contains("\\("),
                "no Swift interpolation may appear inside the script body — that is the injection surface")
        // Wait-for-exit, not a blind sleep.
        #expect(script.contains("/bin/kill -0 \"$1\""))
        // Bounded: 150 × 0.2s ≈ 30s.
        #expect(script.contains("-lt 150"))
        #expect(script.contains("/bin/sleep 0.2"))
        // And it opens the bundle afterwards — the one line this test replaces.
        #expect(script.hasSuffix("/usr/bin/open \"$2\""))
    }

    @Test("the helper waits for the pid to exit, then passes the bundle path through verbatim")
    func relaunchHelperWaitsForExitAndPreservesTheBundlePath() throws {
        let script = try productionScript()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let marker = tmp.appendingPathComponent("opened.txt")

        // ONE substitution: `open` becomes a marker writer. Everything before it
        // — the wait loop, the bound, the positional reads — is byte-identical
        // to production, and the pin above proves the suffix we replaced.
        #expect(script.hasSuffix("/usr/bin/open \"$2\""))
        let harness = script.replacingOccurrences(
            of: "/usr/bin/open \"$2\"",
            with: "printf '%s' \"$2\" > \"$3\""
        )

        // A sacrificial child that stays alive until we kill it.
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["20"]
        try victim.run()
        let victimPid = victim.processIdentifier

        // A bundle path full of the things a naive interpolation would execute.
        let nastyBundlePath = "/Applications/My App $(touch \(tmp.path)/pwned); rm -rf x.app"

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", harness, "relaunch", String(victimPid), nastyBundlePath, marker.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()

        // While the victim lives, the helper must NOT have opened anything.
        usleep(600_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "the helper opened the bundle while the old process was still alive")
        #expect(helper.isRunning, "the helper exited before the old process did")

        victim.terminate()
        victim.waitUntilExit()

        // Now it must finish promptly (poll bound, not a fixed sleep).
        let deadline = Date().addingTimeInterval(10)
        while helper.isRunning && Date() < deadline { usleep(20_000) }
        if helper.isRunning {
            helper.terminate()
            usleep(200_000)
            if helper.isRunning { kill(helper.processIdentifier, SIGKILL) }
            helper.waitUntilExit()
            Issue.record("the helper never completed after the old process exited")
            return
        }
        helper.waitUntilExit()

        let opened = try String(contentsOf: marker, encoding: .utf8)
        #expect(opened == nastyBundlePath,
                "the bundle path did not survive verbatim — quoting or positional passing regressed")
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("pwned").path),
                "the bundle path was evaluated by the shell — command substitution executed")
    }

    @Test("the wait is bounded: a pid that never exits still reaches the open step")
    func relaunchHelperWaitIsBounded() throws {
        // Proving the real 150-iteration bound would cost 30s of wall clock. Run
        // the byte-identical script with only the ITERATION CAP scaled down —
        // the pin above asserts production's cap is 150, and this proves the
        // loop is actually cap-terminated rather than `while kill -0` forever.
        let script = try productionScript()
        #expect(script.contains("-lt 150"))
        let scaled = script
            .replacingOccurrences(of: "-lt 150", with: "-lt 5")
            .replacingOccurrences(of: "/usr/bin/open \"$2\"", with: "printf ok")
        #expect(scaled.contains("-lt 5"))

        // A child WE own that outlives the scaled bound, so `kill -0` keeps
        // succeeding (pid 1 is root-owned: kill -0 there fails with EPERM and
        // would exit the loop immediately, proving nothing).
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["30"]
        try victim.run()
        defer {
            if victim.isRunning { victim.terminate() }
            victim.waitUntilExit()
        }

        let started = Date()
        let status = try runBoundedShell(
            script: scaled, args: [String(victim.processIdentifier), "/tmp/whatever.app"], deadline: 15)
        #expect(status == 0,
                "the wait loop never terminated while the old process stayed alive (status \(status))")
        // 5 × 0.2s: it waited, then gave up — it neither returned instantly nor spun.
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.8, "the loop did not actually wait (elapsed \(elapsed)s)")
        #expect(victim.isRunning, "sanity: the victim must still be alive when the bound fires")
    }
}
