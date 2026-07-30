import Foundation

public enum SelfImprovementGitError: Error, LocalizedError, Equatable {
    case gitNotFound
    case workTreeNotClean(detail: String)
    case expectedHeadMismatch(expected: String, actual: String)
    case expectedCommitShaMismatch(expected: String, actual: String)
    case applyFailed(stderr: String)
    case commitFailed(stderr: String)
    case revertFailed(stderr: String)
    case mergeConflict(files: [String])
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound: return "git executable not found on PATH"
        case .workTreeNotClean(let d): return "work tree not clean: \(d)"
        case .expectedHeadMismatch(let e, let a): return "expected HEAD \(e), actual \(a)"
        case .expectedCommitShaMismatch(let e, let a): return "expected commit \(e), actual \(a)"
        case .applyFailed(let s): return "git apply failed: \(s)"
        case .commitFailed(let s): return "git commit failed: \(s)"
        case .revertFailed(let s): return "git revert failed: \(s)"
        case .mergeConflict(let f): return "merge conflict in: \(f.joined(separator: ", "))"
        case .underlying(let s): return s
        }
    }
}

public actor SelfImprovementGitOps {
    private let repoRoot: URL
    private let env: [String: String]?
    private let defaultTimeout: TimeInterval

    public init(repoRoot: URL, environment: [String: String]? = nil, defaultTimeout: TimeInterval = 30.0) {
        self.repoRoot = repoRoot
        self.env = environment
        self.defaultTimeout = defaultTimeout
    }

    // MARK: - Public API

    public func currentHead() async throws -> String {
        let result = try await runGit(["rev-parse", "--short=12", "HEAD"])
        guard result.exit == 0 else {
            throw SelfImprovementGitError.underlying("git rev-parse HEAD failed: \(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isWorkTreeClean() async throws -> Bool {
        let result = try await runGit(["status", "--porcelain"])
        guard result.exit == 0 else {
            throw SelfImprovementGitError.underlying("git status failed: \(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func applyDiffAndCommit(
        diffText: String,
        message: String,
        expectedHead: String?,
        // U5 fix-round (2026-06-11): async so a validate body that runs a
        // long build gate can hop off-actor and be awaited here without
        // pinning the GitOps actor (sync closures convert implicitly).
        validateAppliedDiff: (@Sendable () async throws -> Void)? = nil
    ) async throws -> String {
        let status = try await runGit(["status", "--porcelain"])
        guard status.exit == 0 else {
            throw SelfImprovementGitError.underlying("git status failed: \(status.stderr)")
        }
        let dirty = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dirty.isEmpty {
            throw SelfImprovementGitError.workTreeNotClean(detail: dirty)
        }

        if let expected = expectedHead, !expected.isEmpty {
            let actual = try await currentHead()
            // Allow either short or long matching (compare common prefix length).
            let n = min(expected.count, actual.count)
            if String(expected.prefix(n)) != String(actual.prefix(n)) {
                throw SelfImprovementGitError.expectedHeadMismatch(expected: expected, actual: actual)
            }
        }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let patchURL = tmpDir.appendingPathComponent("selfimprove-\(UUID().uuidString).patch")
        try diffText.write(to: patchURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: patchURL) }

        let apply = try await runGit(["apply", "--3way", patchURL.path])
        if apply.exit != 0 {
            let combined = apply.stderr + "\n" + apply.stdout
            if isConflictOutput(combined) {
                let files = parseConflictFiles(combined)
                throw SelfImprovementGitError.mergeConflict(files: files)
            }
            throw SelfImprovementGitError.applyFailed(stderr: apply.stderr)
        }

        if let validateAppliedDiff {
            do {
                try await validateAppliedDiff()
            } catch {
                _ = try? await runGit(["apply", "-R", "--3way", patchURL.path])
                throw SelfImprovementGitError.underlying("validation failed: \(error.localizedDescription)")
            }
        }

        let add = try await runGit(["add", "-A"])
        if add.exit != 0 {
            throw SelfImprovementGitError.commitFailed(stderr: add.stderr)
        }

        let commit = try await runGit([
            "-c", "user.name=NativeAgent",
            "-c", "user.email=nativeagent@local",
            "commit", "-m", message,
        ])
        if commit.exit != 0 {
            throw SelfImprovementGitError.commitFailed(stderr: commit.stderr)
        }

        return try await currentHead()
    }

    public func revertCommit(
        commitSha: String,
        expectedCommitSha: String?
    ) async throws -> String {
        // Same clean-worktree preflight as promotion (applyDiffAndCommit):
        // `git revert` mutates the LIVE repo — in a dirty sibling-worker tree
        // it can fail midway or land a revert commit while unrelated dirt
        // remains. Fail closed before touching anything.
        let status = try await runGit(["status", "--porcelain"])
        guard status.exit == 0 else {
            throw SelfImprovementGitError.underlying("git status failed: \(status.stderr)")
        }
        let dirty = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dirty.isEmpty {
            throw SelfImprovementGitError.workTreeNotClean(detail: dirty)
        }

        if let expected = expectedCommitSha, !expected.isEmpty {
            let n = min(expected.count, commitSha.count)
            if String(expected.prefix(n)) != String(commitSha.prefix(n)) {
                throw SelfImprovementGitError.expectedCommitShaMismatch(expected: expected, actual: commitSha)
            }
        }

        let exists = try await runGit(["cat-file", "-e", "\(commitSha)^{commit}"])
        if exists.exit != 0 {
            throw SelfImprovementGitError.revertFailed(stderr: "commit \(commitSha) not found in repo")
        }

        let contains = try await runGit(["merge-base", "--is-ancestor", commitSha, "HEAD"])
        if contains.exit != 0 {
            throw SelfImprovementGitError.revertFailed(stderr: "commit \(commitSha) is not an ancestor of HEAD")
        }

        let revert = try await runGit([
            "-c", "user.name=NativeAgent",
            "-c", "user.email=nativeagent@local",
            "revert", "--no-edit", commitSha,
        ])
        if revert.exit != 0 {
            let combined = revert.stderr + "\n" + revert.stdout
            // Abort revert so repo is clean.
            _ = try? await runGit(["revert", "--abort"])
            if isConflictOutput(combined) {
                let files = parseConflictFiles(combined)
                throw SelfImprovementGitError.mergeConflict(files: files)
            }
            throw SelfImprovementGitError.revertFailed(stderr: revert.stderr)
        }

        return try await currentHead()
    }

    public func stashSnapshot(message: String) async throws -> String {
        let result = try await runGit([
            "-c", "user.name=NativeAgent",
            "-c", "user.email=nativeagent@local",
            "stash", "push", "-u", "-m", message,
        ])
        if result.exit != 0 {
            throw SelfImprovementGitError.underlying("git stash push failed: \(result.stderr)")
        }
        // Resolve the most recent stash ref.
        let list = try await runGit(["stash", "list", "-n", "1", "--format=%gd"])
        let ref = list.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.isEmpty ? "stash@{0}" : ref
    }

    public func stashPop(ref: String) async throws {
        let result = try await runGit(["stash", "pop", ref])
        if result.exit != 0 {
            let combined = result.stderr + "\n" + result.stdout
            if isConflictOutput(combined) {
                throw SelfImprovementGitError.mergeConflict(files: parseConflictFiles(combined))
            }
            throw SelfImprovementGitError.underlying("git stash pop failed: \(result.stderr)")
        }
    }

    public func resetHard(toSha: String) async throws {
        let result = try await runGit(["reset", "--hard", toSha])
        if result.exit != 0 {
            throw SelfImprovementGitError.underlying("git reset --hard failed: \(result.stderr)")
        }
    }

    // MARK: - Internals

    private struct GitResult {
        let stdout: String
        let stderr: String
        let exit: Int32
    }

    /// U5 fix-round (2026-06-11, gpt-5.5 review): the sync pipe reads +
    /// `waitUntilExit` used to run ON the GitOps actor's thread, pinning it
    /// for up to `defaultTimeout` per call (and up to 900s when the
    /// orchestrator's build gate ran inside `validateAppliedDiff`). The
    /// blocking body now runs on a GCD global queue; the actor awaits a
    /// continuation without blocking a thread. Timeout semantics identical
    /// (same DispatchWorkItem terminate).
    private nonisolated func runGit(_ args: [String]) async throws -> GitResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try self.runGitBlocking(args) })
            }
        }
    }

    private nonisolated func runGitBlocking(_ args: [String]) throws -> GitResult {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = ["git", "-C", repoRoot.path] + args

        if let env = env {
            proc.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw SelfImprovementGitError.underlying("failed to spawn git: \(error)")
        }

        // Background timeout: terminate if it runs too long.
        let timeoutItem = DispatchWorkItem { [weak proc] in
            if let p = proc, p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + defaultTimeout, execute: timeoutItem)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timeoutItem.cancel()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let exit = proc.terminationStatus

        // gitNotFound detection: env shell prints to stderr / returns 127 when
        // `git` is not on PATH.
        if exit == 127 || stderr.lowercased().contains("git: not found")
            || stderr.lowercased().contains("git: no such") {
            throw SelfImprovementGitError.gitNotFound
        }

        return GitResult(stdout: stdout, stderr: stderr, exit: exit)
    }

    private nonisolated func isConflictOutput(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("conflict") || lower.contains("merge conflict")
            || lower.contains("patch failed") || lower.contains("with conflicts")
    }

    private nonisolated func parseConflictFiles(_ s: String) -> [String] {
        var files: [String] = []
        for line in s.split(separator: "\n") {
            let l = String(line)
            // git apply: "U path/to/file" or "error: patch failed: path:line"
            if l.hasPrefix("U ") {
                files.append(String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if let r = l.range(of: "patch failed: ") {
                let rest = l[r.upperBound...]
                let path = rest.split(separator: ":").first.map(String.init) ?? String(rest)
                files.append(path.trimmingCharacters(in: .whitespaces))
            } else if let r = l.range(of: "CONFLICT") {
                // "CONFLICT (content): Merge conflict in <path>"
                if let mr = l.range(of: "Merge conflict in ") {
                    files.append(String(l[mr.upperBound...]).trimmingCharacters(in: .whitespaces))
                } else {
                    files.append(String(l[r.lowerBound...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return files
    }
}
