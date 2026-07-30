import Testing
import Foundation
@testable import SelfImprovement

// MARK: - Test fixtures

private struct TempRepo {
    let root: URL

    static func make(seedFile: String = "seed.txt", seedContent: String = "hello\n") throws -> TempRepo {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try shell("git", ["-C", root.path, "init", "-q", "-b", "main"])
        try shell("git", ["-C", root.path, "config", "user.email", "test@local"])
        try shell("git", ["-C", root.path, "config", "user.name", "Test User"])
        try shell("git", ["-C", root.path, "config", "commit.gpgsign", "false"])
        try seedContent.write(
            to: root.appendingPathComponent(seedFile),
            atomically: true, encoding: .utf8
        )
        try shell("git", ["-C", root.path, "add", "-A"])
        try shell("git", ["-C", root.path, "commit", "-q", "-m", "seed"])
        return TempRepo(root: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func headSha() throws -> String {
        try shellCapture("git", ["-C", root.path, "rev-parse", "--short=12", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private func makeDiff(repo: TempRepo, fileName: String, newContent: String) throws -> String {
    // Apply, capture diff via `git diff` against HEAD, then revert.
    let target = repo.root.appendingPathComponent(fileName)
    let original = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    try newContent.write(to: target, atomically: true, encoding: .utf8)
    let diff = try shellCapture("git", ["-C", repo.root.path, "diff"])
    try original.write(to: target, atomically: true, encoding: .utf8)
    return diff
}

// MARK: - Tests

@Test func currentHead_returns_HEAD_sha() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    let head = try await ops.currentHead()
    let expected = try repo.headSha()
    #expect(head == expected)
    #expect(head.count == 12)
}

@Test func isWorkTreeClean_returns_true_on_clean_tree() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    #expect(try await ops.isWorkTreeClean() == true)
}

@Test func isWorkTreeClean_returns_false_when_file_modified() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    try "dirty\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    #expect(try await ops.isWorkTreeClean() == false)
}

@Test func applyDiffAndCommit_happy_path_creates_commit() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    let originalHead = try await ops.currentHead()
    let diff = try makeDiff(repo: repo, fileName: "seed.txt", newContent: "hello\nworld\n")
    let newHead = try await ops.applyDiffAndCommit(
        diffText: diff,
        message: "test: apply diff",
        expectedHead: originalHead
    )
    #expect(newHead != originalHead)
    let log = try shellCapture("git", ["-C", repo.root.path, "log", "-1", "--format=%s"])
    #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "test: apply diff")
}

@Test func applyDiffAndCommit_expectedHead_mismatch_throws() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    let diff = try makeDiff(repo: repo, fileName: "seed.txt", newContent: "hello\nworld\n")
    do {
        _ = try await ops.applyDiffAndCommit(
            diffText: diff,
            message: "should not land",
            expectedHead: "deadbeefcafe"
        )
        Issue.record("expected expectedHeadMismatch to throw")
    } catch let e as SelfImprovementGitError {
        if case .expectedHeadMismatch = e { } else {
            Issue.record("wrong error: \(e)")
        }
    }
}

@Test func applyDiffAndCommit_unclean_tree_throws_workTreeNotClean() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    // Dirty the tree.
    try "dirty\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    do {
        _ = try await ops.applyDiffAndCommit(
            diffText: "irrelevant",
            message: "x",
            expectedHead: nil
        )
        Issue.record("expected workTreeNotClean to throw")
    } catch let e as SelfImprovementGitError {
        if case .workTreeNotClean = e { } else {
            Issue.record("wrong error: \(e)")
        }
    }
}

@Test func applyDiffAndCommit_conflict_throws_mergeConflict() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    // Build a diff against "hello\n", then change the file on disk and commit
    // so the diff base no longer matches and a 3-way conflict is forced.
    let diff = try makeDiff(repo: repo, fileName: "seed.txt", newContent: "hello\nworld\n")
    try "completely-different\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    try shell("git", ["-C", repo.root.path, "commit", "-q", "-am", "divergent"])
    do {
        _ = try await ops.applyDiffAndCommit(
            diffText: diff,
            message: "should conflict",
            expectedHead: nil
        )
        Issue.record("expected mergeConflict or applyFailed")
    } catch let e as SelfImprovementGitError {
        switch e {
        case .mergeConflict, .applyFailed:
            break  // either is acceptable here — both signal patch did not land cleanly
        default:
            Issue.record("wrong error: \(e)")
        }
    }
}

@Test func revertCommit_happy_path_creates_revert_commit() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    // Create a commit to revert.
    try "hello\nworld\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    try shell("git", ["-C", repo.root.path, "commit", "-q", "-am", "add world"])
    let targetSha = try shellCapture("git", ["-C", repo.root.path, "rev-parse", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let head = try await ops.currentHead()
    let newHead = try await ops.revertCommit(commitSha: targetSha, expectedCommitSha: targetSha)
    #expect(newHead != head)
    let log = try shellCapture("git", ["-C", repo.root.path, "log", "-1", "--format=%s"])
    #expect(log.contains("Revert"))
}

@Test func revertCommit_unclean_tree_throws_workTreeNotClean() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    // Create a commit to revert…
    try "hello\nworld\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    try shell("git", ["-C", repo.root.path, "commit", "-q", "-am", "add world"])
    let targetSha = try shellCapture("git", ["-C", repo.root.path, "rev-parse", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // …then dirty the tree with unrelated sibling-worker dirt (untracked
    // counts as dirty — same standard as the promotion preflight).
    try "uncommitted sibling work\n".write(
        to: repo.root.appendingPathComponent("other.txt"),
        atomically: true, encoding: .utf8
    )
    do {
        _ = try await ops.revertCommit(commitSha: targetSha, expectedCommitSha: targetSha)
        Issue.record("expected workTreeNotClean to throw")
    } catch let e as SelfImprovementGitError {
        if case .workTreeNotClean = e { } else {
            Issue.record("wrong error: \(e)")
        }
    }
    // No revert commit landed; the dirt is untouched.
    let log = try shellCapture("git", ["-C", repo.root.path, "log", "-1", "--format=%s"])
    #expect(!log.contains("Revert"))
    let dirt = try String(
        contentsOf: repo.root.appendingPathComponent("other.txt"), encoding: .utf8)
    #expect(dirt == "uncommitted sibling work\n")
}

@Test func revertCommit_expectedSha_mismatch_throws() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    let head = try shellCapture("git", ["-C", repo.root.path, "rev-parse", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    do {
        _ = try await ops.revertCommit(commitSha: head, expectedCommitSha: "deadbeef0000")
        Issue.record("expected expectedCommitShaMismatch to throw")
    } catch let e as SelfImprovementGitError {
        if case .expectedCommitShaMismatch = e { } else {
            Issue.record("wrong error: \(e)")
        }
    }
}

@Test func stashSnapshot_then_pop_round_trips() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    try "dirty\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    let ref = try await ops.stashSnapshot(message: "round-trip-test")
    #expect(try await ops.isWorkTreeClean() == true)
    try await ops.stashPop(ref: ref)
    let content = try String(
        contentsOf: repo.root.appendingPathComponent("seed.txt"),
        encoding: .utf8
    )
    #expect(content == "dirty\n")
}

@Test func resetHard_to_sha_destroys_uncommitted() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    let ops = SelfImprovementGitOps(repoRoot: repo.root)
    let origHead = try shellCapture("git", ["-C", repo.root.path, "rev-parse", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try "dirty\n".write(
        to: repo.root.appendingPathComponent("seed.txt"),
        atomically: true, encoding: .utf8
    )
    #expect(try await ops.isWorkTreeClean() == false)
    try await ops.resetHard(toSha: origHead)
    #expect(try await ops.isWorkTreeClean() == true)
    let content = try String(
        contentsOf: repo.root.appendingPathComponent("seed.txt"),
        encoding: .utf8
    )
    #expect(content == "hello\n")
}

@Test func gitNotFound_when_PATH_lacks_git() async throws {
    let repo = try TempRepo.make()
    defer { repo.cleanup() }
    // Force PATH to a dir with no git on it.
    let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("emptybin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: emptyDir) }
    let ops = SelfImprovementGitOps(
        repoRoot: repo.root,
        environment: ["PATH": emptyDir.path]
    )
    do {
        _ = try await ops.currentHead()
        Issue.record("expected gitNotFound to throw")
    } catch let e as SelfImprovementGitError {
        if case .gitNotFound = e { } else {
            Issue.record("wrong error: \(e)")
        }
    }
}
