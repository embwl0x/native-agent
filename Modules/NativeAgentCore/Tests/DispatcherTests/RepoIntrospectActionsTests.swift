import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Dispatcher

// MARK: - Wave 32 W08: native repo-introspection connector-action tests
//
// Exercises the 5 read-only connector actions ported in §6.76 — grep,
// git_status, git_diff, git_log, repo_dirty_summary — both directly
// (FileSystemActions.*) and through SwiftNativeDispatcher's native-execution
// path (localActions: .fileSystemDefault). Parity targets are the Python
// handlers in the retired daemon (_exec_grep / _exec_git_status /
// _exec_git_diff / _exec_git_log / _exec_repo_dirty_summary).
//
// These tests shell out to real `git` / `rg`-or-`grep`. They build a throwaway
// git repo under NSTemporaryDirectory and tear it down implicitly (temp dir).

// MARK: - fixtures

private func makeRepoSandbox() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("RepoActions-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        Issue.record("repo fixture could not create \(url.path): \(error)")
    }
    return url.resolvingSymlinksInPath()
}

private func rctx(_ sandbox: URL, fileAccess: [String: JSONValue] = [:], dataRoot: String? = nil) -> ConnectorActionContext {
    ConnectorActionContext(repoRoot: sandbox.path, fileAccess: fileAccess, dataRoot: dataRoot)
}

private func robj(_ v: JSONValue) -> [String: JSONValue]? {
    guard case .object(let o) = v else { return nil }
    return o
}
private func rstr(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
private func rint(_ v: JSONValue?) -> Int? {
    switch v ?? .null { case .int(let i): return Int(i); case .double(let d): return Int(d); default: return nil }
}
private func rbool(_ v: JSONValue?) -> Bool? { if case .bool(let b)? = v { return b }; return nil }
private func rarr(_ v: JSONValue?) -> [JSONValue]? { if case .array(let a)? = v { return a }; return nil }

// Hang-proof fixture shell (see RunSandboxTests.swift `runTool_largeOutput_
// drains_without_deadlock` + SelfImprovementTests/SubprocessTestSupport.swift;
// duplicated because test targets don't share sources): pipes are drained
// concurrently so >64KB of output can't wedge the child in write(2), and the
// wait polls `isRunning` under a deadline with SIGTERM → SIGKILL escalation
// instead of an unbounded waitUntilExit.
private struct FixtureCommandFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FixtureCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.withLock { stdout = data } }
    func setStderr(_ data: Data) { lock.withLock { stderr = data } }
    func snapshot() -> (stdout: String, stderr: String) {
        lock.withLock {
            (
                String(decoding: stdout, as: UTF8.self),
                String(decoding: stderr, as: UTF8.self)
            )
        }
    }
}

private final class RepoIntrospectionLoadResults: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    func append(_ failure: String) { lock.withLock { failures.append(failure) } }
    func snapshot() -> [String] { lock.withLock { failures } }
}

/// Fixture construction is not the production concurrency subject. Serialize
/// its short-lived shell commands so the parallel Core suite cannot manufacture
/// a process-launch storm and then blame repo-introspection for a half-built
/// repository. Production `runProcess` calls remain concurrent and are covered
/// by the explicit load proof below.
private let fixtureShellLock = NSLock()

@discardableResult
private func sh(_ launch: String, _ args: [String], cwd: URL? = nil) throws -> Int32 {
    fixtureShellLock.lock()
    defer { fixtureShellLock.unlock() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        throw FixtureCommandFailure(
            description: "fixture command failed to launch: \(launch) \(args.joined(separator: " ")): \(error)"
        )
    }
    // Dedicated Threads, not DispatchQueue.global(): under parallel-suite
    // load the GCD pool starves and a queued drain may not start before the
    // child fills the pipe buffer — the exact wedge this helper exists to
    // prevent.
    let output = FixtureCommandOutput()
    let discard = DispatchGroup()
    discard.enter()
    let outThread = Thread {
        output.setStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
        discard.leave()
    }
    outThread.name = "RepoIntrospectActionsTests.sh.stdout"
    outThread.start()
    discard.enter()
    let errThread = Thread {
        output.setStderr(errPipe.fileHandleForReading.readDataToEndOfFile())
        discard.leave()
    }
    errThread.name = "RepoIntrospectActionsTests.sh.stderr"
    errThread.start()
    let deadline = Date().addingTimeInterval(60)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning {
        p.terminate()
        let grace = Date().addingTimeInterval(2)
        while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        let killEnd = Date().addingTimeInterval(2)
        while p.isRunning && Date() < killEnd { Thread.sleep(forTimeInterval: 0.02) }
        _ = discard.wait(timeout: .now() + 5)
        let captured = output.snapshot()
        throw FixtureCommandFailure(
            description: "fixture command timed out after 60s: \(launch) \(args.joined(separator: " ")); "
                + "stdout=\(captured.stdout.debugDescription) stderr=\(captured.stderr.debugDescription)"
        )
    }
    guard discard.wait(timeout: .now() + 5) == .success else {
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        throw FixtureCommandFailure(
            description: "fixture command pipe drain timed out: \(launch) \(args.joined(separator: " "))"
        )
    }
    let captured = output.snapshot()
    guard p.terminationStatus == 0 else {
        throw FixtureCommandFailure(
            description: "fixture command exited \(p.terminationStatus): \(launch) \(args.joined(separator: " ")); "
                + "stdout=\(captured.stdout.debugDescription) stderr=\(captured.stderr.debugDescription)"
        )
    }
    return p.terminationStatus
}

private func gitBin() -> String? { which("git") }

/// Build a minimal git repo with one committed file + one uncommitted edit +
/// one untracked file. Returns nil when git is unavailable (tests skip).
private func makeGitRepo() throws -> URL? {
    guard let git = gitBin() else { return nil }
    let sb = makeRepoSandbox()
    try sh(git, ["init", "-q"], cwd: sb)
    try sh(git, ["config", "user.email", "t@t.test"], cwd: sb)
    try sh(git, ["config", "user.name", "Tester"], cwd: sb)
    try sh(git, ["config", "commit.gpgsign", "false"], cwd: sb)
    try "first line\nsecond line\n".write(to: sb.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try "stage me\n".write(to: sb.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
    try sh(git, ["add", "tracked.txt"], cwd: sb)
    try sh(git, ["commit", "-q", "-m", "initial commit"], cwd: sb)
    try sh(git, ["branch", "-M", "fixture-main"], cwd: sb)
    // unstaged edit to tracked.txt
    try "first line CHANGED\nsecond line\n".write(to: sb.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    // staged NEW file (X = 'A')
    try sh(git, ["add", "staged.txt"], cwd: sb)
    // untracked file
    try "junk".write(to: sb.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
    return sb
}

private func makeCleanGitRepo(
    filename: String = "a.txt",
    contents: String = "x"
) throws -> URL? {
    guard let git = gitBin() else { return nil }
    let sb = makeRepoSandbox()
    try sh(git, ["init", "-q"], cwd: sb)
    try sh(git, ["config", "user.email", "t@t.test"], cwd: sb)
    try sh(git, ["config", "user.name", "Tester"], cwd: sb)
    try sh(git, ["config", "commit.gpgsign", "false"], cwd: sb)
    try contents.write(
        to: sb.appendingPathComponent(filename),
        atomically: true,
        encoding: .utf8
    )
    try sh(git, ["add", filename], cwd: sb)
    try sh(git, ["commit", "-q", "-m", "c"], cwd: sb)
    return sb
}

// MARK: - grep

@Test func grepFindsMatchesAndReportsCount() throws {
    let sb = makeRepoSandbox()
    try "alpha\nbravo needle\ncharlie\nneedle again\n".write(
        to: sb.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.grep(["pattern": .string("needle"), "path": .string(sb.path)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    #expect(rstr(obj["pattern"]) == "needle")
    #expect((rint(obj["matches"]) ?? 0) == 2)
    let out = rstr(obj["output"]) ?? ""
    #expect(out.contains("needle"))
}

@Test func grepMissingPatternIsBadInput() {
    let sb = makeRepoSandbox()
    let res = FileSystemActions.grep([:], rctx(sb))
    let obj = robj(res)!
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "bad_input")
}

@Test func grepBadMaxResultsIsBadInput() {
    let sb = makeRepoSandbox()
    let res = FileSystemActions.grep(["pattern": .string("x"), "max_results": .string("oops")], rctx(sb))
    let obj = robj(res)!
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "bad_input")
}

@Test func grepNoMatchesIsOkWithZeroCount() throws {
    let sb = makeRepoSandbox()
    try "nothing here\n".write(to: sb.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.grep(["pattern": .string("ZZZ_absent"), "path": .string(sb.path)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)   // exit 1 = no matches, still ok
    #expect((rint(obj["matches"]) ?? -1) == 0)
}

@Test func grepHardCapsAt50() throws {
    let sb = makeRepoSandbox()
    var body = ""
    for _ in 0..<120 { body += "needle\n" }
    try body.write(to: sb.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)
    // request 60 — Python caps at min(60, _GREP_MAX_RESULTS=50) = 50; with 120
    // matching lines this proves the 50 hard cap (not the request value).
    let res = FileSystemActions.grep(
        ["pattern": .string("needle"), "path": .string(sb.path), "max_results": .int(60)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rint(obj["matches"]) == 50)
}

@Test func grepCapsAtRequestedWhenBelow50() throws {
    let sb = makeRepoSandbox()
    var body = ""
    for _ in 0..<120 { body += "needle\n" }
    try body.write(to: sb.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.grep(
        ["pattern": .string("needle"), "path": .string(sb.path), "max_results": .int(7)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rint(obj["matches"]) == 7)
}

@Test func grepNegativeMaxResultsHitsGrepError() throws {
    // PARITY: Python passes the negative value to `rg -m -3`/`grep -m -3` which
    // rejects it (exit 2 → grep_error) BEFORE slicing. Swift must reach the same
    // grep_error, not silently clamp to a 0-match ok result.
    let sb = makeRepoSandbox()
    try "needle\n".write(to: sb.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.grep(
        ["pattern": .string("needle"), "path": .string(sb.path), "max_results": .int(-3)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "grep_error")
}

@Test func grepOutsideSandboxBlocked() {
    let sb = makeRepoSandbox()
    // sandbox mode on; search /etc which is outside repo_root.
    let res = FileSystemActions.grep(
        ["pattern": .string("root"), "path": .string("/etc")],
        rctx(sb, fileAccess: ["sandbox": .string("workspace-write")]))
    let obj = robj(res)!
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "path_not_allowed")
}

@Test func grepSensitiveDataPathBlocked() throws {
    // data_root threaded; search under data_root/oauth → blocked even in full mode.
    let sb = makeRepoSandbox()
    let dataRoot = sb.appendingPathComponent("data")
    let oauth = dataRoot.appendingPathComponent("oauth")
    try FileManager.default.createDirectory(at: oauth, withIntermediateDirectories: true)
    try "token".write(to: oauth.appendingPathComponent("t.json"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.grep(
        ["pattern": .string("token"), "path": .string(oauth.path)],
        rctx(sb, fileAccess: ["mode": .string("full")], dataRoot: dataRoot.path))
    let obj = robj(res)!
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "path_not_allowed")
}

// MARK: - git_status

@Test func gitStatusParsesStagedUnstagedUntracked() throws {
    guard let sb = try makeGitRepo() else { return }   // skip if no git
    let res = FileSystemActions.gitStatus([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    func names(_ k: String) -> [String] {
        (rarr(obj[k]) ?? []).compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
    #expect(names("staged").contains("staged.txt"))      // X = 'A' (added)
    #expect(names("unstaged").contains("tracked.txt"))    // Y = 'M' (modified, not staged)
    #expect(names("untracked").contains("untracked.txt")) // ??
    #expect(rstr(obj["branch"]) == "fixture-main")
    #expect(rint(obj["ahead"]) == 0)
    #expect(rint(obj["behind"]) == 0)
    #expect(rbool(obj["clean"]) == false)
    #expect(rstr(obj["raw"]) != nil)
}

@Test func gitStatusOutsideSandboxBlocked() throws {
    guard try makeGitRepo() != nil else { return }
    let sb = makeRepoSandbox()
    let res = FileSystemActions.gitStatus(
        ["cwd": .string("/etc")],
        rctx(sb, fileAccess: ["sandbox": .string("workspace-write")]))
    let obj = robj(res)!
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "path_not_allowed")
}

@Test func gitStatusNonRepoIsGitUnavailable() throws {
    guard gitBin() != nil else { return }
    let sb = makeRepoSandbox()   // a dir that is NOT a git repo
    let res = FileSystemActions.gitStatus([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "git_unavailable")
}

// MARK: - git_diff

@Test func gitDiffShowsUnstagedChange() throws {
    guard let sb = try makeGitRepo() else { return }
    let res = FileSystemActions.gitDiff([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    #expect(rbool(obj["staged"]) == false)
    let diff = rstr(obj["diff"]) ?? ""
    #expect(diff.contains("CHANGED"))
    // Diff is far under the 30k truncate cap, so `diff` == full stdout and
    // `bytes` must equal its Unicode-scalar count exactly (Python len()).
    #expect(rint(obj["bytes"]) == diff.unicodeScalars.count)
    #expect((rint(obj["bytes"]) ?? 0) > 0)
}

@Test func gitDiffBytesUsesCodePointCount() throws {
    guard let git = gitBin() else { return }
    let sb = makeRepoSandbox()
    try sh(git, ["init", "-q"], cwd: sb)
    try sh(git, ["config", "user.email", "t@t.test"], cwd: sb)
    try sh(git, ["config", "user.name", "Tester"], cwd: sb)
    try sh(git, ["config", "commit.gpgsign", "false"], cwd: sb)
    try "base\n".write(to: sb.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
    try sh(git, ["add", "e.txt"], cwd: sb)
    try sh(git, ["commit", "-q", "-m", "c"], cwd: sb)
    // Add a multi-scalar grapheme (family emoji = several scalars, 1 cluster).
    try "base\n👨‍👩‍👧 done\n".write(to: sb.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.gitDiff([:], rctx(sb))
    let obj = try #require(robj(res))
    let diff = rstr(obj["diff"]) ?? ""
    // bytes counts code points: must be >= grapheme count and == scalar count.
    #expect(rint(obj["bytes"]) == diff.unicodeScalars.count)
    #expect((rint(obj["bytes"]) ?? 0) >= diff.count)
}

@Test func gitDiffStagedShowsStagedAddition() throws {
    guard let sb = try makeGitRepo() else { return }   // fixture stages staged.txt
    let res = FileSystemActions.gitDiff(["staged": .bool(true)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    #expect(rbool(obj["staged"]) == true)
    // The fixture `git add staged.txt`-es a new file, so the cached diff is
    // non-empty and names it. (Distinct from the unstaged `git_diff` above,
    // which shows tracked.txt's working-tree edit.)
    #expect((rstr(obj["diff"]) ?? "").contains("staged.txt"))
}

@Test func gitDiffStagedEmptyOnFreshlyCommittedRepo() throws {
    // A repo with nothing staged → empty cached diff (proves the staged path
    // returns empty when there's genuinely nothing in the index above HEAD).
    guard let sb = try makeCleanGitRepo() else { return }
    let res = FileSystemActions.gitDiff(["staged": .bool(true)], rctx(sb))
    let obj = try #require(robj(res))
    guard rbool(obj["ok"]) == true else {
        let errorCode = rstr(obj["error_code"]) ?? "<none>"
        let errorMessage = rstr(obj["error"]) ?? "<none>"
        Issue.record("git diff --staged failed after a verified fixture commit: error_code=\(errorCode) error=\(errorMessage)")
        return
    }
    #expect((rstr(obj["diff"]) ?? "").isEmpty)
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["NATIVE_AGENT_RUN_REPO_PROCESS_STRESS"] == "1"
    )
)
func concurrentGitDiffStagedUsesVerifiedReposUnderProcessLoad() throws {
    let workerCount = 16
    var repos: [URL] = []
    for index in 0..<workerCount {
        guard let repo = try makeCleanGitRepo(
            filename: "file-\(index).txt",
            contents: "value-\(index)"
        ) else { return }
        repos.append(repo)
    }

    let start = DispatchSemaphore(value: 0)
    let completed = DispatchGroup()
    let results = RepoIntrospectionLoadResults()
    for repo in repos {
        completed.enter()
        let thread = Thread {
            start.wait()
            let value = FileSystemActions.gitDiff(["staged": .bool(true)], rctx(repo))
            guard let object = robj(value), rbool(object["ok"]) == true else {
                let object = robj(value) ?? [:]
                let errorCode = rstr(object["error_code"]) ?? "<none>"
                let errorMessage = rstr(object["error"]) ?? "<none>"
                results.append("\(repo.lastPathComponent): error_code=\(errorCode) error=\(errorMessage)")
                completed.leave()
                return
            }
            if !(rstr(object["diff"]) ?? "").isEmpty {
                results.append("\(repo.lastPathComponent): expected empty staged diff")
            }
            completed.leave()
        }
        thread.name = "RepoIntrospectActionsTests.production-load"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    for _ in repos { start.signal() }

    #expect(completed.wait(timeout: .now() + 60) == .success)
    #expect(results.snapshot().isEmpty, "\(results.snapshot())")
}

// MARK: - git_log

@Test func gitLogReturnsCommits() throws {
    guard let sb = try makeGitRepo() else { return }
    let res = FileSystemActions.gitLog([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    let commits = rarr(obj["commits"]) ?? []
    #expect(commits.count == 1)
    #expect(rint(obj["count"]) == 1)
    if case .object(let c) = commits[0] {
        #expect(rstr(c["subject"]) == "initial commit")
        #expect(rstr(c["author"]) == "Tester")
        #expect((rstr(c["hash"]) ?? "").isEmpty == false)
        #expect((rstr(c["date"]) ?? "").isEmpty == false)
    } else {
        Issue.record("expected a commit object")
    }
}

@Test func gitLogBadLimitDefaultsTo10NotBadInput() throws {
    guard let sb = try makeGitRepo() else { return }
    // Python: min(_safe_int(limit) or 10, 100) — unparseable → 10, NOT bad_input.
    let res = FileSystemActions.gitLog(["limit": .string("nonsense")], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)   // did NOT bad_input
    #expect(rint(obj["count"]) == 1)    // only 1 commit exists
}

@Test func gitLogZeroLimitFallsBackTo10() throws {
    guard let sb = try makeGitRepo() else { return }
    // `0 or 10 == 10` in Python → limit 10.
    let res = FileSystemActions.gitLog(["limit": .int(0)], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    #expect(rint(obj["count"]) == 1)
}

@Test func gitLogSubjectWithPipeStaysIntact() throws {
    guard let sb = try makeGitRepo(), let git = gitBin() else { return }
    try sh(git, ["commit", "-q", "--allow-empty", "-m", "subject | with | pipes"], cwd: sb)
    let res = FileSystemActions.gitLog(["limit": .int(1)], rctx(sb))
    let obj = try #require(robj(res))
    let commits = rarr(obj["commits"]) ?? []
    if case .object(let c) = commits.first {
        // maxsplit=3 keeps the trailing pipes inside subject.
        #expect(rstr(c["subject"]) == "subject | with | pipes")
    } else {
        Issue.record("expected commit")
    }
}

// MARK: - repo_dirty_summary

@Test func repoDirtySummaryReportsDirtyState() throws {
    guard let sb = try makeGitRepo() else { return }
    let res = FileSystemActions.repoDirtySummary([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    #expect(rbool(obj["clean"]) == false)
    let unstaged = (rarr(obj["unstaged"]) ?? []).compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    let untracked = (rarr(obj["untracked"]) ?? []).compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    #expect(unstaged.contains("tracked.txt"))
    #expect(untracked.contains("untracked.txt"))
    #expect((rstr(obj["branch"]) ?? "").isEmpty == false)
    #expect((rarr(obj["commits"]) ?? []).count == 1)
}

@Test func repoDirtySummaryCleanRepo() throws {
    guard let git = gitBin() else { return }
    let sb = makeRepoSandbox()
    try sh(git, ["init", "-q"], cwd: sb)
    try sh(git, ["config", "user.email", "t@t.test"], cwd: sb)
    try sh(git, ["config", "user.name", "Tester"], cwd: sb)
    try sh(git, ["config", "commit.gpgsign", "false"], cwd: sb)
    try "x".write(to: sb.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try sh(git, ["add", "a.txt"], cwd: sb)
    try sh(git, ["commit", "-q", "-m", "c"], cwd: sb)
    let res = FileSystemActions.repoDirtySummary([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == true)
    #expect(rbool(obj["clean"]) == true)
    #expect(rint(obj["ahead"]) == 0)
    #expect(rint(obj["behind"]) == 0)
}

@Test func repoDirtySummaryNonRepoIsGitUnavailable() throws {
    guard gitBin() != nil else { return }
    let sb = makeRepoSandbox()
    let res = FileSystemActions.repoDirtySummary([:], rctx(sb))
    let obj = try #require(robj(res))
    #expect(rbool(obj["ok"]) == false)
    #expect(rstr(obj["error_code"]) == "git_unavailable")
}

// MARK: - helper unit tests (no subprocess)

@Test func splitNKeepsTrailingSeparators() {
    #expect(splitN("a|b|c|d", separator: "|", maxSplits: 1) == ["a", "b|c|d"])
    #expect(splitN("a|b|c|d", separator: "|", maxSplits: 3) == ["a", "b", "c", "d"])
    #expect(splitN("nopipe", separator: "|", maxSplits: 3) == ["nopipe"])
}

@Test func parseTrailingIntExtractsAheadBehind() {
    #expect(parseTrailingInt("main...origin/main [ahead 3]", after: "[ahead ") == 3)
    #expect(parseTrailingInt("main...origin/main [ahead 2, behind 5]", after: "behind ") == 5)
    #expect(parseTrailingInt("main...origin/main [ahead 2, behind 5]", after: "[ahead ") == 2)
    #expect(parseTrailingInt("clean", after: "[ahead ") == nil)
}

@Test func whichResolvesGit() {
    // git is virtually always present in CI/dev; tolerate absence.
    if let g = which("git") { #expect(FileManager.default.isExecutableFile(atPath: g)) }
    #expect(which("definitely-not-a-real-binary-xyz") == nil)
}

@Test func sharedFilePathResolutionExpandsHomeBeforeSandboxing() {
    let expected = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    #expect(FileSystemActions.resolvePath("~/Projects", repoRoot: "/tmp") == expected)
}

// MARK: - native dispatch path

@Test func nativeDispatchRunsGitStatusWithoutHTTP() async throws {
    guard let sb = try makeGitRepo() else { return }
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .fileSystemDefault)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: [:]
    )
    let result = try await d.dispatch(tool: "git_status", input: [:], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.autonomySource == "native")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)   // no HTTP round-trip
}

@Test func nativeDispatchGrepFailedMapsToFailed() async throws {
    let sb = makeRepoSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .fileSystemDefault)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: [:]
    )
    // missing pattern → bad_input → failed status, executed=true.
    let result = try await d.dispatch(tool: "grep", input: [:], ctx: dctx, dryRun: false)
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == true)
    #expect(result.error?.code == "bad_input")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - registry

@Test func registryNowKnowsTenActions() {
    let reg = LocalConnectorActions.fileSystemDefault
    // Wave 32 W08 additions:
    #expect(reg.canHandle("grep"))
    #expect(reg.canHandle("git_status"))
    #expect(reg.canHandle("git_diff"))
    #expect(reg.canHandle("git_log"))
    #expect(reg.canHandle("repo_dirty_summary"))
    // None of the new ones are side-effecting.
    #expect(!reg.isSideEffecting("grep"))
    #expect(!reg.isSideEffecting("git_status"))
    #expect(!reg.isSideEffecting("git_diff"))
    #expect(!reg.isSideEffecting("git_log"))
    #expect(!reg.isSideEffecting("repo_dirty_summary"))
    // The original 5 still present; write_file still the only side-effecting one.
    #expect(reg.isSideEffecting("write_file"))
    // Wave 34 W06 added 4 persona/system read-only handlers → total 14.
    #expect(reg.toolNames.count == 14)
}
