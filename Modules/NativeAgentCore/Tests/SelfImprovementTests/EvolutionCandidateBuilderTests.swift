import Testing
import Foundation
@testable import SelfImprovement

// MARK: - Fixture: tiny git repo with a buildable + testable package

private struct FixtureRepo {
    let root: URL

    static func make() throws -> FixtureRepo {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evobuilder-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("Sources/FixtureLib", isDirectory: true),
            withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("Tests/FixtureLibTests", isDirectory: true),
            withIntermediateDirectories: true)

        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Fixture",
            targets: [
                .target(name: "FixtureLib", path: "Sources/FixtureLib"),
                .testTarget(name: "FixtureLibTests", dependencies: ["FixtureLib"], path: "Tests/FixtureLibTests"),
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try """
        public func answer() -> Int { 42 }
        """.write(to: root.appendingPathComponent("Sources/FixtureLib/Lib.swift"), atomically: true, encoding: .utf8)

        try """
        import XCTest
        import FixtureLib
        final class LibTests: XCTestCase {
            func testAnswer() { XCTAssertEqual(answer(), 42) }
        }
        """.write(to: root.appendingPathComponent("Tests/FixtureLibTests/LibTests.swift"), atomically: true, encoding: .utf8)

        try "fixture readme\n".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try git(root, ["init", "-q", "-b", "main"])
        try git(root, ["config", "user.email", "test@local"])
        try git(root, ["config", "user.name", "Test User"])
        try git(root, ["config", "commit.gpgsign", "false"])
        try git(root, ["add", "-A"])
        try git(root, ["commit", "-q", "-m", "seed"])
        return FixtureRepo(root: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func head() throws -> String {
        try gitCapture(root, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a diff by mutating a file, capturing `git diff`, restoring.
    func diff(file: String, newContent: String) throws -> String {
        let target = root.appendingPathComponent(file)
        let original = try String(contentsOf: target, encoding: .utf8)
        try newContent.write(to: target, atomically: true, encoding: .utf8)
        let d = try gitCapture(root, ["diff"])
        try original.write(to: target, atomically: true, encoding: .utf8)
        return d
    }
}

@discardableResult
private func git(_ cwd: URL, _ args: [String]) throws -> Int32 {
    let r = try runBoundedProcess(["git", "-C", cwd.path] + args)
    if r.status != 0 {
        throw NSError(domain: "git", code: Int(r.status))
    }
    return r.status
}

private func gitCapture(_ cwd: URL, _ args: [String]) throws -> String {
    try runBoundedProcess(["git", "-C", cwd.path] + args).stdout
}

private func tempDataRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("evobuilder-data-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Fixture config: root package IS the test package; generous-but-bounded
/// timeouts for a tiny package.
private func fixtureConfig() -> EvolutionBuildConfig {
    EvolutionBuildConfig(
        buildTimeout: 600,
        testTimeout: 600,
        gitTimeout: 60,
        testPackageSubpath: nil
    )
}

// MARK: - Pipeline scenarios (real builds, tiny package)

@Test(.timeLimit(.minutes(15)))
func builder_green_diff_full_pipeline() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    let diff = try repo.diff(
        file: "Sources/FixtureLib/Lib.swift",
        newContent: "public func answer() -> Int { 42 }\npublic func bonus() -> Int { 7 }\n")
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "green-1", proposalId: "evo_g", diffText: diff,
        expectedHead: try repo.head(),
        expectedDiffSHA256: EvolutionSupport.sha256Hex(diff)))

    #expect(result.ok == true, "error: \(result.error ?? "-")")
    #expect(result.phase == .complete)
    #expect(result.buildExit == 0)
    #expect(result.testExit == 0)
    #expect(result.escalatedFullSuite == true) // fixture paths are outside the core-module prefixes
    #expect(result.worktreeCleaned == true)
    // Receipts on disk: result.json + logs kept, worktree gone.
    #expect(FileManager.default.fileExists(atPath: builder.resultPath(runId: "green-1").path))
    #expect(FileManager.default.fileExists(
        atPath: builder.candidateDir(runId: "green-1").appendingPathComponent("build.log").path))
    #expect(!FileManager.default.fileExists(atPath: builder.worktreeDir(runId: "green-1").path))
    // Live repo untouched.
    let status = try gitCapture(repo.root, ["status", "--porcelain"])
    #expect(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    // Persisted verdict round-trips.
    let loaded = try await builder.loadResult(runId: "green-1")
    #expect(loaded == result)
}

@Test(.timeLimit(.minutes(15)))
func builder_broken_build_diff_fails_at_build() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    let diff = try repo.diff(
        file: "Sources/FixtureLib/Lib.swift",
        newContent: "public func answer() -> Int { 42 \n") // missing brace
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "broken-1", proposalId: "evo_b", diffText: diff,
        expectedHead: try repo.head()))

    #expect(result.ok == false)
    #expect(result.phase == .build)
    #expect(result.buildExit != 0)
    #expect(result.worktreeCleaned == true)
    let log = try String(
        contentsOf: builder.candidateDir(runId: "broken-1").appendingPathComponent("build.log"),
        encoding: .utf8)
    #expect(log.contains("error"))
}

@Test(.timeLimit(.minutes(15)))
func builder_conflicting_diff_fails_at_apply() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    // Diff against the seeded content…
    let diff = try repo.diff(
        file: "Sources/FixtureLib/Lib.swift",
        newContent: "public func answer() -> Int { 43 }\n")
    // …then move HEAD so the base no longer matches.
    try "public func answer() -> Int { 100 } // divergent\n".write(
        to: repo.root.appendingPathComponent("Sources/FixtureLib/Lib.swift"),
        atomically: true, encoding: .utf8)
    try git(repo.root, ["commit", "-q", "-am", "divergent"])

    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "conflict-1", proposalId: "evo_c", diffText: diff,
        expectedHead: try repo.head()))

    #expect(result.ok == false)
    #expect(result.phase == .apply)
    #expect(result.error?.contains("apply") == true || result.error?.contains("conflict") == true)
    #expect(result.buildExit == nil) // never reached build
}

@Test(.timeLimit(.minutes(15)))
func builder_test_failing_diff_fails_at_test() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    let diff = try repo.diff(
        file: "Sources/FixtureLib/Lib.swift",
        newContent: "public func answer() -> Int { 41 }\n") // compiles, breaks the test
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "testfail-1", proposalId: "evo_t", diffText: diff,
        expectedHead: try repo.head()))

    #expect(result.ok == false)
    #expect(result.phase == .test)
    #expect(result.buildExit == 0)
    #expect(result.testExit != 0)
    #expect(FileManager.default.fileExists(
        atPath: builder.candidateDir(runId: "testfail-1").appendingPathComponent("test.log").path))
}

@Test(.timeLimit(.minutes(15)))
func builder_docs_only_diff_skips_tests() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    let diff = try repo.diff(file: "README.md", newContent: "fixture readme\nmore docs\n")
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "docs-1", proposalId: "evo_d", diffText: diff,
        expectedHead: try repo.head()))

    #expect(result.ok == true, "error: \(result.error ?? "-")")
    #expect(result.testsSkippedReason == "no_code_paths_touched")
    #expect(result.testExit == nil)
    #expect(result.buildExit == 0) // build always runs
}

// MARK: - Refusals (cheap, no builds)

@Test func builder_refuses_unsafe_run_id() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "../escape", proposalId: "p", diffText: "x", expectedHead: "HEAD"))
    #expect(result.ok == false)
    #expect(result.error?.contains("invalid_run_id") == true)
}

@Test func builder_refuses_diff_sha_mismatch() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let diff = try repo.diff(file: "README.md", newContent: "x\n")
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "sha-1", proposalId: "p", diffText: diff,
        expectedHead: try repo.head(),
        expectedDiffSHA256: "0000000000000000000000000000000000000000000000000000000000000000"))
    #expect(result.ok == false)
    #expect(result.phase == .validate)
    #expect(result.error?.contains("diff_sha_mismatch") == true)
}

@Test func builder_refuses_missing_expected_head() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let diff = try repo.diff(file: "README.md", newContent: "x\n")
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "nohead-1", proposalId: "p", diffText: diff,
        expectedHead: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"))
    #expect(result.ok == false)
    #expect(result.phase == .worktreeAdd)
    #expect(result.error?.contains("not found") == true)
}

@Test func builder_refuses_result_overwrite() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let resultPath = builder.resultPath(runId: "dup-1")
    try FileManager.default.createDirectory(
        at: resultPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{}".write(to: resultPath, atomically: true, encoding: .utf8)

    let diff = try repo.diff(file: "README.md", newContent: "x\n")
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "dup-1", proposalId: "p", diffText: diff, expectedHead: try repo.head()))
    #expect(result.ok == false)
    #expect(result.error == "result_exists_for_run_id")
    // Evidence NOT overwritten.
    let onDisk = try String(contentsOf: resultPath, encoding: .utf8)
    #expect(onDisk == "{}")
}

@Test func builder_loadResult_corrupt_fails_closed() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let resultPath = builder.resultPath(runId: "corrupt-1")
    try FileManager.default.createDirectory(
        at: resultPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "not json".write(to: resultPath, atomically: true, encoding: .utf8)
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await builder.loadResult(runId: "corrupt-1")
    }
    #expect(try await builder.loadResult(runId: "absent-1") == nil)
}

@Test func builder_sweep_removes_aged_candidate_dirs() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let t0 = Date()
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig(),
        now: { t0.addingTimeInterval(15 * 24 * 3600) })
    // Fabricate an aged candidate dir (mtime = now-real-time, builder clock +15d).
    let dir = builder.candidateDir(runId: "old-run")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let removed = await builder.sweepCandidates(olderThanDays: 14)
    #expect(removed == ["old-run"])
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

// MARK: - Cross-process claim CAS (review finding 1)

@Test func builder_refuses_run_claimed_by_another_process() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    // Simulate another process's live claim (claim.json present, no result yet).
    let claim = builder.claimPath(runId: "claimed-1")
    try FileManager.default.createDirectory(
        at: claim.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"runId":"claimed-1","pid":"99999","claimedAt":"2026-06-10T00:00:00Z"}"#
        .write(to: claim, atomically: true, encoding: .utf8)

    let diff = try repo.diff(file: "README.md", newContent: "x\n")
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "claimed-1", proposalId: "p", diffText: diff, expectedHead: try repo.head()))
    #expect(result.ok == false)
    #expect(result.error == "run_claimed_by_another_process")
    // The loser leaves no result.json and no worktree — the claim owner owns both.
    #expect(!FileManager.default.fileExists(atPath: builder.resultPath(runId: "claimed-1").path))
    #expect(!FileManager.default.fileExists(atPath: builder.worktreeDir(runId: "claimed-1").path))
}

@Test(.timeLimit(.minutes(15)))
func builder_concurrent_same_run_id_exactly_one_winner() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let diff = try repo.diff(file: "README.md", newContent: "fixture readme\nrace docs\n")
    let head = try repo.head()

    // Two INSTANCES = two actor-local inFlight sets = the cross-process
    // shape. The flocked claim CAS is the only thing between them and a
    // shared candidate dir (flock contends across distinct fds in-process
    // exactly as it does across processes).
    let b1 = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let b2 = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    async let r1Async = b1.build(EvolutionCandidateRequest(
        runId: "race-1", proposalId: "p", diffText: diff, expectedHead: head))
    async let r2Async = b2.build(EvolutionCandidateRequest(
        runId: "race-1", proposalId: "p", diffText: diff, expectedHead: head))
    let (r1, r2) = await (r1Async, r2Async)

    let winners = [r1, r2].filter { $0.ok }
    let losers = [r1, r2].filter { !$0.ok }
    #expect(winners.count == 1, "r1: \(r1.error ?? "ok"), r2: \(r2.error ?? "ok")")
    #expect(losers.count == 1)
    let loserError = losers.first?.error
    #expect(loserError == "run_claimed_by_another_process"
        || loserError == "result_exists_for_run_id")
    // The persisted verdict is the WINNER's green result — never overwritten
    // by the loser (the exact failure mode from the review).
    let persisted = try await b1.loadResult(runId: "race-1")
    #expect(persisted?.ok == true)
}

// MARK: - Hermetic temp HOME / TMPDIR (review finding 2)

@Test(.timeLimit(.minutes(15)))
func builder_children_get_temp_home_and_tmpdir() async throws {
    let repo = try FixtureRepo.make()
    defer { repo.cleanup() }
    let dataRoot = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    // Diff swaps the fixture test for one that prints its env — the markers
    // land in test.log, proving what the CHILD actually saw.
    let diff = try repo.diff(
        file: "Tests/FixtureLibTests/LibTests.swift",
        newContent: """
        import XCTest
        import FixtureLib
        final class LibTests: XCTestCase {
            func testAnswer() { XCTAssertEqual(answer(), 42) }
            func testEnvMarkers() {
                let env = ProcessInfo.processInfo.environment
                print("HOME_MARKER=\\(env["HOME"] ?? "nil")")
                print("TMPDIR_MARKER=\\(env["TMPDIR"] ?? "nil")")
            }
        }
        """ + "\n")
    let builder = EvolutionCandidateBuilder(
        repoRoot: repo.root, dataRoot: dataRoot, config: fixtureConfig())
    let result = await builder.build(EvolutionCandidateRequest(
        runId: "hermetic-1", proposalId: "evo_h", diffText: diff,
        expectedHead: try repo.head()))
    #expect(result.ok == true, "error: \(result.error ?? "-")")

    let log = try String(
        contentsOf: builder.candidateDir(runId: "hermetic-1").appendingPathComponent("test.log"),
        encoding: .utf8)
    let home = builder.homeDir(runId: "hermetic-1").path
    let tmp = builder.tmpDir(runId: "hermetic-1").path
    #expect(log.contains("HOME_MARKER=\(home)"), "child HOME is not the candidate-local home")
    #expect(log.contains("TMPDIR_MARKER=\(tmp)"), "child TMPDIR is not the candidate-local tmp")
    // Sandbox dirs are cleaned at terminal status; receipts stay.
    #expect(!FileManager.default.fileExists(atPath: home))
    #expect(!FileManager.default.fileExists(atPath: tmp))
}

@Test func hermetic_env_overlays_home_tmpdir_xdg() {
    let env = EvolutionSupport.hermeticEnvironment(
        base: [
            "PATH": "/usr/bin",
            "HOME": "/Users/real",
            "TMPDIR": "/var/real/",
            "XDG_CACHE_HOME": "/Users/real/.cache",
        ],
        homeDir: URL(fileURLWithPath: "/tmp/cand/home"),
        tmpDir: URL(fileURLWithPath: "/tmp/cand/tmp"))
    #expect(env["HOME"] == "/tmp/cand/home")
    #expect(env["TMPDIR"] == "/tmp/cand/tmp/")
    #expect(env["XDG_CACHE_HOME"] == "/tmp/cand/home/.cache")
    #expect(env["XDG_CONFIG_HOME"] == "/tmp/cand/home/.config")
    #expect(env["XDG_DATA_HOME"] == "/tmp/cand/home/.local/share")
    #expect(env["PATH"] == "/usr/bin") // untouched passthrough
}

// MARK: - Pure units: mapping + env scrub + support

@Test func mapping_core_source_paths_to_module_filters() {
    let diff = """
    --- a/Modules/NativeAgentCore/Sources/MemoryV2/Foo.swift
    +++ b/Modules/NativeAgentCore/Sources/MemoryV2/Foo.swift
    @@ -1 +1 @@
    -a
    +b
    --- a/Modules/NativeAgentCore/Tests/SkillsTests/Bar.swift
    +++ b/Modules/NativeAgentCore/Tests/SkillsTests/Bar.swift
    @@ -1 +1 @@
    -a
    +b
    """
    let m = EvolutionCandidateBuilder.mapTouchedPathsToTests(
        diffText: diff,
        sourcePrefix: "Modules/NativeAgentCore/Sources/",
        testPrefix: "Modules/NativeAgentCore/Tests/")
    #expect(m.escalate == false)
    #expect(m.filters == ["MemoryV2Tests", "SkillsTests"])
}

@Test func mapping_out_of_module_path_escalates() {
    let diff = """
    --- a/Modules/NativeAgentCore/Sources/Skills/A.swift
    +++ b/Modules/NativeAgentCore/Sources/Skills/A.swift
    @@ -1 +1 @@
    -a
    +b
    --- a/Sources/NativeAgentApp/NativeClient.swift
    +++ b/Sources/NativeAgentApp/NativeClient.swift
    @@ -1 +1 @@
    -a
    +b
    """
    let m = EvolutionCandidateBuilder.mapTouchedPathsToTests(
        diffText: diff,
        sourcePrefix: "Modules/NativeAgentCore/Sources/",
        testPrefix: "Modules/NativeAgentCore/Tests/")
    #expect(m.escalate == true)
    #expect(m.filters.isEmpty)
}

@Test func mapping_docs_only_no_tests_no_escalation() {
    let diff = """
    --- a/docs/notes.md
    +++ b/docs/notes.md
    @@ -1 +1 @@
    -a
    +b
    """
    let m = EvolutionCandidateBuilder.mapTouchedPathsToTests(
        diffText: diff,
        sourcePrefix: "Modules/NativeAgentCore/Sources/",
        testPrefix: "Modules/NativeAgentCore/Tests/")
    #expect(m.escalate == false)
    #expect(m.filters.isEmpty)
}

@Test func env_scrub_drops_secrets_keeps_allowlist() {
    let scrubbed = EvolutionSupport.scrubbedEnvironment(from: [
        "PATH": "/usr/bin",
        "HOME": "/Users/x",
        "LC_MESSAGES": "en_US",
        "OPENAI_API_KEY": "sk-secret",
        "GITHUB_TOKEN": "ghp_secret",
        "ANTHROPIC_API_KEY": "sk-ant",
    ])
    #expect(scrubbed["PATH"] == "/usr/bin")
    #expect(scrubbed["HOME"] == "/Users/x")
    #expect(scrubbed["LC_MESSAGES"] == "en_US")
    #expect(scrubbed["OPENAI_API_KEY"] == nil)
    #expect(scrubbed["GITHUB_TOKEN"] == nil)
    #expect(scrubbed["ANTHROPIC_API_KEY"] == nil)
}

@Test func sha_matches_prefix_and_fail_closed() {
    #expect(EvolutionSupport.shaMatches("abc123def456", "abc123d") == true)
    #expect(EvolutionSupport.shaMatches("abc123d", "abc123def456") == true)
    #expect(EvolutionSupport.shaMatches("abc123def456", "zzz999") == false)
    #expect(EvolutionSupport.shaMatches(nil, "abc123d") == false)
    #expect(EvolutionSupport.shaMatches("abc123d", "") == false)
    #expect(EvolutionSupport.shaMatches("abc", "abc") == false) // <7 chars refused
}

@Test func safe_path_component_guard() {
    #expect(EvolutionSupport.isSafePathComponent("run-1_a.2") == true)
    #expect(EvolutionSupport.isSafePathComponent("../escape") == false)
    #expect(EvolutionSupport.isSafePathComponent(".hidden") == false)
    #expect(EvolutionSupport.isSafePathComponent("") == false)
    #expect(EvolutionSupport.isSafePathComponent("a/b") == false)
}
