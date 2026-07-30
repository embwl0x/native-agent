import Testing
import Foundation
@testable import SelfImprovement

// MARK: - U2b wave 1: cold candidate build measurement harness
//
// Env-gated (U2B_MEASURE_COLD_BUILD=1) — NOT part of the normal suite. Runs
// the real EvolutionCandidateBuilder against THIS repo with a trivial
// comment-only diff, exactly as a live evolution candidate would run:
// detached worktree @ HEAD, 3-way apply, FULL root cold `swift build`
// (worktree-local .build), filtered `swift test`. Records wall-clock per
// phase to stderr + the run's result.json. Plan open question #2: this
// number decides whether candidate builds get a warm-cache seed.
//
//   U2B_MEASURE_COLD_BUILD=1 swift test --package-path Modules/NativeAgentCore \
//     --filter EvolutionColdBuildMeasurement
//
// The diff is generated from `git show HEAD:<file>` + `git diff --no-index`
// between temp files — the live tree is never written.

private func capture(_ cwd: URL, _ args: [String]) throws -> (out: String, exit: Int32) {
    let r = try runBoundedProcess(args, cwd: cwd)
    return (r.stdout, r.status)
}

private func locateRepoRoot() -> URL? {
    // Walk up from this file's package dir to the repo root.
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["U2B_MEASURE_COLD_BUILD"] == "1"),
    .timeLimit(.minutes(60))
)
func measure_cold_candidate_build_on_this_repo() async throws {
    let repoRoot = try #require(locateRepoRoot())
    let targetFile = "Modules/NativeAgentCore/Sources/SelfImprovement/SelfImprovement.swift"

    // HEAD content → temp pair → unified diff with proper a/ b/ headers.
    let headContent = try capture(repoRoot, ["git", "show", "HEAD:\(targetFile)"])
    #expect(headContent.exit == 0)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("u2b-measure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let fileA = tmp.appendingPathComponent("a.swift")
    let fileB = tmp.appendingPathComponent("b.swift")
    try headContent.out.write(to: fileA, atomically: true, encoding: .utf8)
    try (headContent.out + "\n// u2b cold-build measurement marker\n")
        .write(to: fileB, atomically: true, encoding: .utf8)
    // Relative paths + cwd=tmp → deterministic "a/a.swift" / "b/b.swift"
    // headers (absolute paths get /var vs /private/var canonicalization).
    // --no-index exits 1 on difference.
    let rawDiff = try capture(tmp, ["git", "diff", "--no-index", "--", "a.swift", "b.swift"])
    var diff = rawDiff.out
    diff = diff.replacingOccurrences(of: "a/a.swift", with: "a/\(targetFile)")
    diff = diff.replacingOccurrences(of: "b/b.swift", with: "b/\(targetFile)")
    #expect(diff.contains("+++ b/\(targetFile)"))

    let head = try capture(repoRoot, ["git", "rev-parse", "HEAD"]).out
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let dataRoot = tmp.appendingPathComponent("data", isDirectory: true)
    let runId = "measure-\(Int(Date().timeIntervalSince1970))"

    let builder = EvolutionCandidateBuilder(
        repoRoot: repoRoot,
        dataRoot: dataRoot,
        config: EvolutionBuildConfig(buildTimeout: 3000, testTimeout: 1800))

    let t0 = Date()
    let result = await builder.build(EvolutionCandidateRequest(
        runId: runId, proposalId: "measure", diffText: diff, expectedHead: head))
    let wall = Date().timeIntervalSince(t0)

    let summary = """
    U2B_COLD_BUILD_MEASUREMENT runId=\(runId) ok=\(result.ok) phase=\(result.phase.rawValue) \
    wallClockSeconds=\(Int(wall)) buildExit=\(result.buildExit.map(String.init) ?? "-") \
    testExit=\(result.testExit.map(String.init) ?? "-") filters=\(result.testFilters.joined(separator: ",")) \
    error=\(result.error ?? "-")
    """
    FileHandle.standardError.write(Data((summary + "\n").utf8))
    #expect(result.ok == true, "cold candidate build failed: \(result.error ?? "-")")
    #expect(result.testFilters == ["SelfImprovementTests"])
}
