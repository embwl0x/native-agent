import Testing
import Foundation
@testable import SelfImprovement

// MARK: - Fixtures (TempRepo shape mirrors GitOpsTests)

private struct RevertFixture {
    let repo: URL
    let dataRoot: URL

    static func make() throws -> RevertFixture {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchrevert-repo-\(UUID().uuidString)")
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchrevert-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try run(repo, ["git", "init", "-q", "-b", "main"])
        try run(repo, ["git", "config", "user.email", "test@local"])
        try run(repo, ["git", "config", "user.name", "Test User"])
        try run(repo, ["git", "config", "commit.gpgsign", "false"])
        try "hello\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try run(repo, ["git", "add", "-A"])
        try run(repo, ["git", "commit", "-q", "-m", "seed"])
        return RevertFixture(repo: repo, dataRoot: dataRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: dataRoot)
    }

    func orchestrator() -> SelfImprovementOrchestrator {
        // packagePath nil → promote's compile gate is skipped (the candidate
        // builder owns build verification in the U2b design).
        SelfImprovementOrchestrator(dataRoot: dataRoot, repoRoot: repo, packagePath: nil)
    }

    /// Drive a real promote so the run record carries promotedCommitSha.
    func promoteSampleChange(_ orch: SelfImprovementOrchestrator) async throws -> String {
        let run = try await orch.startImprovement(objective: "test change")
        // Build a diff: modify, capture, restore.
        let target = repo.appendingPathComponent("seed.txt")
        try "hello\nworld\n".write(to: target, atomically: true, encoding: .utf8)
        let diff = try capture(repo, ["git", "diff"])
        try "hello\n".write(to: target, atomically: true, encoding: .utf8)
        // Default patch location: <dataRoot>/improvements/patches/<runId>.patch
        let patchDir = dataRoot
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("patches", isDirectory: true)
        try FileManager.default.createDirectory(at: patchDir, withIntermediateDirectories: true)
        try diff.write(to: patchDir.appendingPathComponent("\(run.id).patch"), atomically: true, encoding: .utf8)
        let result = try await orch.promote(runId: run.id)
        guard result.ok else { throw NSError(domain: "promote", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error ?? "?"]) }
        return run.id
    }

    func headSubject() throws -> String {
        try capture(repo, ["git", "log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func run(_ cwd: URL, _ args: [String]) throws -> Int32 {
    let r = try runBoundedProcess(args, cwd: cwd)
    if r.status != 0 { throw NSError(domain: "proc", code: Int(r.status)) }
    return r.status
}

private func capture(_ cwd: URL, _ args: [String]) throws -> String {
    try runBoundedProcess(args, cwd: cwd).stdout
}

// MARK: - Tests

@Test func revert_happy_path_lands_revert_commit_and_marks_record() async throws {
    let fx = try RevertFixture.make()
    defer { fx.cleanup() }
    let orch = fx.orchestrator()
    let runId = try await fx.promoteSampleChange(orch)

    let result = try await orch.revert(runId: runId)
    #expect(result.ok == true, "error: \(result.error ?? "-")")
    #expect(try fx.headSubject().contains("Revert"))
    // seed.txt back to original content.
    let content = try String(contentsOf: fx.repo.appendingPathComponent("seed.txt"), encoding: .utf8)
    #expect(content == "hello\n")
    // Record marked reverted with the revert commit sha.
    let runs = try await orch.listPending()
    let run = runs.first { $0.id == runId }
    #expect(run?.status == "reverted")
    #expect(run?.revertCommitSha?.isEmpty == false)
}

@Test func revert_without_promoted_commit_refused_record_untouched() async throws {
    let fx = try RevertFixture.make()
    defer { fx.cleanup() }
    let orch = fx.orchestrator()
    let run = try await orch.startImprovement(objective: "never promoted")
    let result = try await orch.revert(runId: run.id)
    #expect(result.ok == false)
    #expect(result.error == "no_promoted_commit")
    let after = try await orch.listPending().first { $0.id == run.id }
    #expect(after?.status == "pending")
}

@Test func revert_dirty_tree_refused_record_untouched() async throws {
    let fx = try RevertFixture.make()
    defer { fx.cleanup() }
    let orch = fx.orchestrator()
    let runId = try await fx.promoteSampleChange(orch)
    // Sibling-worker dirt: an unrelated uncommitted file in the live tree.
    try "uncommitted sibling work\n".write(
        to: fx.repo.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)

    let result = try await orch.revert(runId: runId)
    #expect(result.ok == false)
    #expect(result.error?.hasPrefix("work_tree_not_clean") == true, "error: \(result.error ?? "-")")
    // Record untouched — still promoted; no revert commit; dirt intact.
    let after = try await orch.listPending().first { $0.id == runId }
    #expect(after?.status == "promoted")
    #expect(try !fx.headSubject().contains("Revert"))
    let dirt = try String(
        contentsOf: fx.repo.appendingPathComponent("sibling.txt"), encoding: .utf8)
    #expect(dirt == "uncommitted sibling work\n")
}

@Test func revert_expectedCommitSha_cas_mismatch_refused() async throws {
    let fx = try RevertFixture.make()
    defer { fx.cleanup() }
    let orch = fx.orchestrator()
    let runId = try await fx.promoteSampleChange(orch)
    let result = try await orch.revert(runId: runId, expectedCommitSha: "deadbeef0000")
    #expect(result.ok == false)
    #expect(result.error?.isEmpty == false)
    // Record untouched — still promoted.
    let after = try await orch.listPending().first { $0.id == runId }
    #expect(after?.status == "promoted")
    #expect(try !fx.headSubject().contains("Revert"))
}

@Test func revert_conflict_aborts_clean_record_untouched() async throws {
    let fx = try RevertFixture.make()
    defer { fx.cleanup() }
    let orch = fx.orchestrator()
    let runId = try await fx.promoteSampleChange(orch)
    // Stack a conflicting commit on the same lines.
    try "completely different\n".write(
        to: fx.repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
    try run(fx.repo, ["git", "commit", "-q", "-am", "conflicting follow-up"])

    let result = try await orch.revert(runId: runId)
    #expect(result.ok == false)
    // Repo left clean (revert --abort path).
    let status = try capture(fx.repo, ["git", "status", "--porcelain"])
    #expect(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    // Record untouched.
    let after = try await orch.listPending().first { $0.id == runId }
    #expect(after?.status == "promoted")
}

@Test func revert_non_ancestor_commit_refused() async throws {
    let fx = try RevertFixture.make()
    defer { fx.cleanup() }
    let orch = fx.orchestrator()
    // Commit on a side branch — exists, but not an ancestor of main.
    try run(fx.repo, ["git", "checkout", "-q", "-b", "side"])
    try "side change\n".write(
        to: fx.repo.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
    try run(fx.repo, ["git", "add", "-A"])
    try run(fx.repo, ["git", "commit", "-q", "-m", "side commit"])
    let sideSha = try capture(fx.repo, ["git", "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try run(fx.repo, ["git", "checkout", "-q", "main"])

    // Hand-craft a pending run claiming the side commit was promoted.
    let pendingPath = fx.dataRoot
        .appendingPathComponent("improvements", isDirectory: true)
        .appendingPathComponent("pending_actions.json")
    try FileManager.default.createDirectory(
        at: pendingPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    let createdAt = ISO8601DateFormatter().string(from: Date())
    try """
    [{"id": "imp_nonancestor", "status": "promoted", "phase": "promoted",
      "createdAt": "\(createdAt)", "promotedCommitSha": "\(sideSha)"}]
    """.write(to: pendingPath, atomically: true, encoding: .utf8)

    let result = try await orch.revert(runId: "imp_nonancestor")
    #expect(result.ok == false)
    #expect(result.error?.contains("ancestor") == true)
    #expect(try !fx.headSubject().contains("Revert"))
}

@Test func revert_no_git_returns_disabled_stub() async throws {
    let noRepo = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("orchrevert-nogit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: noRepo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: noRepo) }
    let orch = SelfImprovementOrchestrator(dataRoot: noRepo, repoRoot: noRepo, packagePath: nil)
    let result = try await orch.revert(runId: "whatever")
    #expect(result.ok == false)
    #expect(result.error == "no_git")
}
