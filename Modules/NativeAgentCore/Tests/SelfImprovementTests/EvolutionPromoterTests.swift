import Testing
import Foundation
@testable import SelfImprovement

// MARK: - U2b wave 2: EvolutionPromoter tests
//
// The promote seam's fail-closed gates, the green-evidence requirement
// (design #2 — a promote without a green candidate result.json must refuse),
// and the crash-window idempotency (re-promote returns the existing commit,
// never a duplicate). All on throwaway tmp git repos + tmp data roots.

private struct PromoterFixture {
    let repoRoot: URL
    let dataRoot: URL

    static func make() throws -> PromoterFixture {
        let repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evopromote-repo-\(UUID().uuidString)")
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evopromote-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try shell("git", ["-C", repoRoot.path, "init", "-q", "-b", "main"])
        try shell("git", ["-C", repoRoot.path, "config", "user.email", "test@local"])
        try shell("git", ["-C", repoRoot.path, "config", "user.name", "Test User"])
        try shell("git", ["-C", repoRoot.path, "config", "commit.gpgsign", "false"])
        try "hello\n".write(
            to: repoRoot.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try shell("git", ["-C", repoRoot.path, "add", "-A"])
        try shell("git", ["-C", repoRoot.path, "commit", "-q", "-m", "seed"])
        return PromoterFixture(repoRoot: repoRoot, dataRoot: dataRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: repoRoot)
        try? FileManager.default.removeItem(at: dataRoot)
    }

    func headSha() throws -> String {
        try shellCapture("git", ["-C", repoRoot.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func diffChangingSeed(to newContent: String) throws -> String {
        let target = repoRoot.appendingPathComponent("seed.txt")
        let original = try String(contentsOf: target, encoding: .utf8)
        try newContent.write(to: target, atomically: true, encoding: .utf8)
        let diff = try shellCapture("git", ["-C", repoRoot.path, "diff"])
        try original.write(to: target, atomically: true, encoding: .utf8)
        return diff
    }

    /// Plant a candidate result.json the way the builder persists verdicts.
    /// `resultRunId` lets a test plant FOREIGN-run content at this runId's
    /// path (the copied/stale-evidence attack the promoter must refuse).
    func plantResult(
        runId: String,
        proposalId: String,
        ok: Bool,
        diffSHA256: String,
        expectedHead: String,
        resultRunId: String? = nil
    ) throws {
        let result = EvolutionCandidateResult(
            runId: resultRunId ?? runId, proposalId: proposalId, ok: ok,
            phase: ok ? .complete : .build,
            expectedHead: expectedHead, diffSHA256: diffSHA256,
            touchedPaths: ["seed.txt"], testFilters: [], escalatedFullSuite: false,
            testsSkippedReason: nil, buildExit: ok ? 0 : 1, testExit: ok ? 0 : nil,
            timedOutPhase: nil, error: ok ? nil : "build_failed",
            startedAt: "2026-06-11T00:00:00Z", finishedAt: "2026-06-11T00:01:00Z",
            worktreeCleaned: true)
        let dir = dataRoot
            .appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("candidates", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(result)
        try data.write(to: dir.appendingPathComponent("result.json"))
    }
}

@discardableResult
private func shell(_ exec: String, _ args: [String]) throws -> Int32 {
    let r = try runBoundedProcess([exec] + args)
    if r.status != 0 {
        throw NSError(domain: "shell", code: Int(r.status),
                      userInfo: [NSLocalizedDescriptionKey: "\(exec) \(args) exit=\(r.status) stderr=\(r.stderr)"])
    }
    return r.status
}

private func shellCapture(_ exec: String, _ args: [String]) throws -> String {
    try runBoundedProcess([exec] + args).stdout
}

private func sha256(_ s: String) -> String { EvolutionSupport.sha256Hex(s) }

// MARK: - Fail-closed gates

@Test func promote_refuses_without_candidate_result() async throws {
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed\n")
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let outcome = await promoter.promote(
        runId: "run-a", proposalId: "evo_1", diffText: diff,
        expectedHead: try fx.headSha(), expectedDiffSHA256: sha256(diff))
    #expect(outcome.ok == false)
    #expect(outcome.error?.contains("no_candidate_result") == true)
    // Repo untouched.
    #expect(try String(contentsOf: fx.repoRoot.appendingPathComponent("seed.txt"), encoding: .utf8) == "hello\n")
}

@Test func promote_refuses_non_green_candidate() async throws {
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed\n")
    let head = try fx.headSha()
    try fx.plantResult(runId: "run-b", proposalId: "evo_1", ok: false,
                       diffSHA256: sha256(diff), expectedHead: head)
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let outcome = await promoter.promote(
        runId: "run-b", proposalId: "evo_1", diffText: diff,
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(outcome.ok == false)
    #expect(outcome.error?.contains("candidate_not_green") == true)
}

@Test func promote_refuses_diff_sha_mismatch_against_evidence() async throws {
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed\n")
    let head = try fx.headSha()
    // Evidence is green but for a DIFFERENT diff sha.
    try fx.plantResult(runId: "run-c", proposalId: "evo_1", ok: true,
                       diffSHA256: sha256("some other diff"), expectedHead: head)
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let outcome = await promoter.promote(
        runId: "run-c", proposalId: "evo_1", diffText: diff,
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(outcome.ok == false)
    #expect(outcome.error?.contains("candidate_diff_sha_mismatch") == true)
}

@Test func promote_refuses_proposal_mismatch_and_bad_text_sha() async throws {
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed\n")
    let head = try fx.headSha()
    try fx.plantResult(runId: "run-d", proposalId: "evo_OTHER", ok: true,
                       diffSHA256: sha256(diff), expectedHead: head)
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let mismatch = await promoter.promote(
        runId: "run-d", proposalId: "evo_1", diffText: diff,
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(mismatch.ok == false)
    #expect(mismatch.error?.contains("candidate_proposal_mismatch") == true)

    // diffText not matching the claimed sha refuses BEFORE evidence checks.
    let badText = await promoter.promote(
        runId: "run-d", proposalId: "evo_OTHER", diffText: diff + "\n",
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(badText.ok == false)
    #expect(badText.error?.contains("diff_sha_mismatch") == true)
}

@Test func promote_refuses_when_expected_head_moved() async throws {
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed\n")
    let oldHead = try fx.headSha()
    try fx.plantResult(runId: "run-e", proposalId: "evo_1", ok: true,
                       diffSHA256: sha256(diff), expectedHead: oldHead)
    // Move HEAD with an unrelated commit.
    try "other\n".write(to: fx.repoRoot.appendingPathComponent("other.txt"),
                        atomically: true, encoding: .utf8)
    try shell("git", ["-C", fx.repoRoot.path, "add", "-A"])
    try shell("git", ["-C", fx.repoRoot.path, "commit", "-q", "-m", "moves head"])
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let outcome = await promoter.promote(
        runId: "run-e", proposalId: "evo_1", diffText: diff,
        expectedHead: oldHead, expectedDiffSHA256: sha256(diff))
    #expect(outcome.ok == false)
    // GitOps expectedHead CAS refuses (head_moved shape from SelfImprovementGitError).
    #expect(outcome.error?.lowercased().contains("head") == true)
}

@Test func promote_refuses_without_git_repo() async throws {
    let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("evopromote-nogit-\(UUID().uuidString)")
    let notARepo = dataRoot.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let promoter = EvolutionPromoter(repoRoot: notARepo, dataRoot: dataRoot)
    let outcome = await promoter.promote(
        runId: "run-f", proposalId: "evo_1", diffText: "x",
        expectedHead: "headsha123456", expectedDiffSHA256: sha256("x"))
    #expect(outcome.ok == false)
    #expect(outcome.error?.contains("self_improvement_unavailable") == true)
}

@Test func promote_refuses_foreign_run_evidence() async throws {
    // gpt-5.5 fix-round pin: a green result.json COPIED from another run
    // (path placement correct, content carries a different runId) must not
    // satisfy this run's promote.
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed\n")
    let head = try fx.headSha()
    try fx.plantResult(runId: "run-foreign", proposalId: "evo_1", ok: true,
                       diffSHA256: sha256(diff), expectedHead: head,
                       resultRunId: "run-SOMEONE-ELSE")
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let outcome = await promoter.promote(
        runId: "run-foreign", proposalId: "evo_1", diffText: diff,
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(outcome.ok == false)
    #expect(outcome.error?.contains("candidate_run_mismatch") == true)
    // Repo untouched.
    #expect(try String(contentsOf: fx.repoRoot.appendingPathComponent("seed.txt"), encoding: .utf8) == "hello\n")
}

// MARK: - Happy path + idempotency

@Test func promote_lands_commit_with_marker_and_repromote_is_idempotent() async throws {
    let fx = try PromoterFixture.make()
    defer { fx.cleanup() }
    let diff = try fx.diffChangingSeed(to: "changed by evolution\n")
    let head = try fx.headSha()
    try fx.plantResult(runId: "run-g", proposalId: "evo_42", ok: true,
                       diffSHA256: sha256(diff), expectedHead: head)
    let promoter = EvolutionPromoter(repoRoot: fx.repoRoot, dataRoot: fx.dataRoot)
    let first = await promoter.promote(
        runId: "run-g", proposalId: "evo_42", diffText: diff,
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(first.ok == true)
    #expect(first.alreadyPromoted == false)
    let commit = try #require(first.commitSha)

    // The diff actually landed and the commit carries the runId marker.
    let content = try String(contentsOf: fx.repoRoot.appendingPathComponent("seed.txt"), encoding: .utf8)
    #expect(content == "changed by evolution\n")
    let message = try shellCapture("git", ["-C", fx.repoRoot.path, "log", "-1", "--format=%B", commit])
    #expect(message.contains(EvolutionPromoter.commitMarker(runId: "run-g")))

    // Crash-window re-run: same runId returns the SAME commit, no duplicate.
    let again = await promoter.promote(
        runId: "run-g", proposalId: "evo_42", diffText: diff,
        expectedHead: head, expectedDiffSHA256: sha256(diff))
    #expect(again.ok == true)
    #expect(again.alreadyPromoted == true)
    #expect(again.commitSha == commit)
    let count = try shellCapture("git", ["-C", fx.repoRoot.path, "rev-list", "--count", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(count == "2") // seed + one promotion, never three
}
