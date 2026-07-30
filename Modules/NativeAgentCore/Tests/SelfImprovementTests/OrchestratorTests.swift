import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

private func makeTempRoots() -> (data: URL, repo: URL) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("si_orch_\(UUID().uuidString)")
    let data = base.appendingPathComponent("data")
    let repo = base.appendingPathComponent("repo")
    try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    return (data, repo)
}

private func shell(_ exec: String, _ args: [String]) throws {
    let r = try runBoundedProcess([exec] + args)
    if r.status != 0 {
        throw NSError(domain: "shell", code: Int(r.status))
    }
}

private func shellCapture(_ exec: String, _ args: [String]) throws -> String {
    try runBoundedProcess([exec] + args).stdout
}

private func makeGitRepo(at repo: URL) throws {
    try shell("git", ["-C", repo.path, "init", "-q", "-b", "main"])
    try shell("git", ["-C", repo.path, "config", "user.email", "test@local"])
    try shell("git", ["-C", repo.path, "config", "user.name", "Test User"])
    try shell("git", ["-C", repo.path, "config", "commit.gpgsign", "false"])
    try "hello\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
    try shell("git", ["-C", repo.path, "add", "-A"])
    try shell("git", ["-C", repo.path, "commit", "-q", "-m", "seed"])
}

private func makePatch(repo: URL) throws -> String {
    let target = repo.appendingPathComponent("seed.txt")
    try "hello\nworld\n".write(to: target, atomically: true, encoding: .utf8)
    let diff = try shellCapture("git", ["-C", repo.path, "diff"])
    try "hello\n".write(to: target, atomically: true, encoding: .utf8)
    return diff
}

@Suite("SelfImprovementOrchestrator")
struct OrchestratorTests {

    @Test("no_git: every boundary returns disabled stub, no throw")
    func noGitDegradation() async throws {
        let (data, repo) = makeTempRoots()
        // No .git in repo → unavailable
        let orch = SelfImprovementOrchestrator(
            dataRoot: data,
            repoRoot: repo,
            packagePath: nil
        )

        let (ok, reason) = await orch.selfImprovementAvailable()
        #expect(ok == false)
        #expect(reason == "no_git")

        let run = try await orch.startImprovement(objective: "noop")
        #expect(run.status == "disabled")
        #expect(run.phase == "disabled")

        let snap = try await orch.snapshot(runId: "x")
        #expect(snap.ok == false)
        #expect(snap.error == "no_git")

        let prom = try await orch.promote(runId: "x")
        #expect(prom.ok == false)
        #expect(prom.error == "no_git")

        let rev = try await orch.revert(runId: "x")
        #expect(rev.ok == false)
        #expect(rev.error == "no_git")

        let sweep = try await orch.sweep()
        #expect(sweep.ok == false)
        #expect(sweep.error == "no_git")

        let pending = try await orch.listPending()
        #expect(pending.isEmpty)
    }

    @Test("happy-path: startImprovement → listPending shows it → sweep keeps it")
    func happyPathStartListSweep() async throws {
        let (data, repo) = makeTempRoots()
        // Create a .git marker so availability returns true.
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let orch = SelfImprovementOrchestrator(
            dataRoot: data,
            repoRoot: repo,
            packagePath: nil
        )

        let (ok, _) = await orch.selfImprovementAvailable()
        #expect(ok)

        let run = try await orch.startImprovement(objective: "tighten the chat path")
        #expect(!run.id.isEmpty)
        #expect(run.phase == "pending")
        #expect(run.objective == "tighten the chat path")

        let pending = try await orch.listPending()
        #expect(pending.count == 1)
        #expect(pending.first?.id == run.id)

        let report = try await orch.sweep()
        #expect(report.ok)
        // Pending (non-terminal) entries must survive a sweep.
        #expect(report.removed == 0)
        #expect(report.kept == 1)

        let after = try await orch.listPending()
        #expect(after.count == 1)
    }

    @Test("persistence: pending_actions.json rehydrates on a fresh actor")
    func rehydrate() async throws {
        let (data, repo) = makeTempRoots()
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let first = SelfImprovementOrchestrator(
            dataRoot: data, repoRoot: repo, packagePath: nil
        )
        let run = try await first.startImprovement(objective: "persist me")
        #expect(!run.id.isEmpty)

        let path = data.appendingPathComponent("improvements/pending_actions.json")
        #expect(FileManager.default.fileExists(atPath: path.path))

        let second = SelfImprovementOrchestrator(
            dataRoot: data, repoRoot: repo, packagePath: nil
        )
        let rehydrated = try await second.listPending()
        #expect(rehydrated.count == 1)
        #expect(rehydrated.first?.id == run.id)
        #expect(rehydrated.first?.objective == "persist me")
    }

    @Test("promote fails closed when a pending action has no patch artifact")
    func promotePendingWithoutArtifactFailsClosed() async throws {
        let (data, repo) = makeTempRoots()
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let orch = SelfImprovementOrchestrator(
            dataRoot: data,
            repoRoot: repo,
            packagePath: nil
        )
        let run = try await orch.startImprovement(objective: "no fake promotion")
        let result = try await orch.promote(runId: run.id)
        #expect(result.ok == false)
        #expect(result.error == "no_promotion_artifact")
        let pending = try await orch.listPending()
        #expect(pending.first?.phase == "pending")
    }

    @Test("promote applies patch artifact, commits, and updates runs ledger")
    func promotePatchArtifactCommitsAndUpdatesLedger() async throws {
        let (data, repo) = makeTempRoots()
        try makeGitRepo(at: repo)
        let runId = "run-patch-1"
        let patch = try makePatch(repo: repo)
        let patchDir = data
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("patches", isDirectory: true)
        try FileManager.default.createDirectory(at: patchDir, withIntermediateDirectories: true)
        try patch.write(to: patchDir.appendingPathComponent("\(runId).patch"), atomically: true, encoding: .utf8)
        let runsPath = data
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("runs.json")
        let runs = """
        [{"id":"\(runId)","status":"succeeded","phase":"staged","objective":"add world"}]
        """
        try FileManager.default.createDirectory(at: runsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runs.write(to: runsPath, atomically: true, encoding: .utf8)

        let originalHead = try shellCapture("git", ["-C", repo.path, "rev-parse", "--short=12", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let orch = SelfImprovementOrchestrator(dataRoot: data, repoRoot: repo, packagePath: nil)
        let result = try await orch.promote(runId: runId)
        #expect(result.ok == true)
        #expect(result.commitSha != nil)
        #expect(result.commitSha != originalHead)
        let content = try String(contentsOf: repo.appendingPathComponent("seed.txt"), encoding: .utf8)
        #expect(content == "hello\nworld\n")

        let updatedData = try Data(contentsOf: runsPath)
        let updated = try JSONValue.parse(updatedData)
        guard case .array(let arr) = updated,
              case .object(let row)? = arr.first else {
            Issue.record("runs.json not updated"); return
        }
        #expect(row["status"] == .string("promoted"))
        #expect(row["phase"] == .string("promoted"))
        #expect(row["promotedCommitSha"] == .string(result.commitSha ?? ""))
    }
}
