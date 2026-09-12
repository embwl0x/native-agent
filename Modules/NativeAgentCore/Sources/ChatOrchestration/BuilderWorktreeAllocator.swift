import Foundation
import CryptoKit

/// The narrow isolation seam for asynchronous coding builders.
///
/// A new Codex, Claude, or OMP conversation gets one ordinary Git worktree. The
/// bridge stores only a conversation -> path pointer so later messages can
/// return to the same checkout. There is intentionally no Factory lifecycle,
/// manifest, receipt schema, scheduler, or cleanup policy here.
/// Omitted and ordinary non-Git directories retain their original cwd
/// semantics; Git evidence with an unsuccessful probe fails closed.
actor BuilderWorktreeAllocator {
    static let shared = BuilderWorktreeAllocator()

    enum Agent: String, Sendable {
        case codex
        case claude
        case omp
    }

    struct Assignment: Sendable, Equatable {
        let workingDirectory: String
        fileprivate let token: String
        /// A follow-up that named a different directory than the one this
        /// conversation was assigned. The assignment wins; this records what
        /// was asked so the receipt can say so (2026-09-11: Agent's follow-ups
        /// to Claude were refused for naming the main checkout).
        var ignoredRequestedDirectory: String? = nil
    }

    /// The one wording behind the receipt clause all three bridge schemas
    /// promise ("ignored and noted on the receipt"). Shared so Claude, Codex,
    /// and OMP cannot drift — only Claude published it before
    /// (astra-comb-3 lane3 #4 / lane1 #4).
    static let ignoredDirectoryNote =
        "This conversation keeps its assigned worktree; the working_directory you passed was ignored. Omit working_directory on follow-ups."

    enum AllocationResult: Sendable, Equatable {
        case unchanged(String?)
        case assigned(Assignment)
        case failed(reason: String, detail: String)
    }

    private struct GitResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    func resolve(
        agent: Agent,
        conversationId: String?,
        messageId: String,
        isFollowUp: Bool,
        requestedDirectory: String?,
        defaultDirectory: String?,
        configRoot: URL
    ) async -> AllocationResult {
        let baseDirectory = requestedDirectory ?? defaultDirectory

        if isFollowUp, let conversationId,
           let existing = await existingAssignment(
               agent: agent,
               identity: conversationId,
               configRoot: configRoot
           ) {
            if let requestedDirectory {
                let requestedPath = URL(fileURLWithPath: requestedDirectory)
                    .standardizedFileURL
                    .resolvingSymlinksInPath().path
                let assignedPath = URL(fileURLWithPath: existing.workingDirectory)
                    .standardizedFileURL
                    .resolvingSymlinksInPath().path
                // A follow-up cannot move; it also should not FAIL for naming
                // the directory it thinks it is in. Reuse the assignment and
                // say what was ignored.
                if requestedPath != assignedPath {
                    var noted = existing
                    noted.ignoredRequestedDirectory = requestedPath
                    touchPointer(agent: agent, identity: conversationId, configRoot: configRoot)
                    return .assigned(noted)
                }
            }
            // The pointer's mtime is this conversation's last-touch evidence,
            // which retirement reads. Reuse never rewrote the file, so an
            // actively used checkout looked as idle as an abandoned one.
            touchPointer(agent: agent, identity: conversationId, configRoot: configRoot)
            return .assigned(existing)
        }
        guard let baseDirectory else { return .unchanged(nil) }

        let identity = conversationId ?? "message:\(messageId)"
        if let existing = await existingAssignment(
            agent: agent,
            identity: identity,
            configRoot: configRoot
        ) {
            touchPointer(agent: agent, identity: identity, configRoot: configRoot)
            return .assigned(existing)
        }

        let baseURL = URL(fileURLWithPath: baseDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let topLevel = await git(["rev-parse", "--show-toplevel"], cwd: baseURL)
        guard topLevel.status == 0 else {
            if topLevel.status == -1 || mayBeGitCheckout(baseURL) {
                return .failed(
                    reason: "builder_worktree_git_probe_failed",
                    detail: boundedDetail(topLevel)
                )
            }
            // A directory with no Git evidence retains ordinary dispatch.
            return .unchanged(baseDirectory)
        }
        let repoRoot = URL(fileURLWithPath: topLevel.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )).standardizedFileURL.resolvingSymlinksInPath()
        guard baseURL.path == repoRoot.path || baseURL.path.hasPrefix(repoRoot.path + "/") else {
            return .failed(
                reason: "builder_worktree_source_invalid",
                detail: "Git reported a repository root that does not contain the requested builder directory."
            )
        }

        let commonDirectoryResult = await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: repoRoot
        )
        guard commonDirectoryResult.status == 0 else {
            return .failed(
                reason: "builder_worktree_git_failed",
                detail: boundedDetail(commonDirectoryResult)
            )
        }
        let commonDirectory = commonDirectoryResult.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let token = stableToken("\(commonDirectory)\u{0}\(agent.rawValue)\u{0}\(identity)")
        let branch = "nativeagent/\(agent.rawValue)-\(token)"
        let worktreeRoot = repoRoot.deletingLastPathComponent().appendingPathComponent(
            "\(repoRoot.lastPathComponent)-wt-\(agent.rawValue)-\(token)",
            isDirectory: true
        )

        if !FileManager.default.fileExists(atPath: worktreeRoot.path) {
            let branchExists = await git(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                cwd: repoRoot
            ).status == 0
            let arguments = branchExists
                ? ["worktree", "add", worktreeRoot.path, branch]
                : ["worktree", "add", "-b", branch, worktreeRoot.path, "HEAD"]
            let add = await git(arguments, cwd: repoRoot)
            guard add.status == 0 else {
                return .failed(
                    reason: "builder_worktree_create_failed",
                    detail: boundedDetail(add)
                )
            }
        }

        let verification = await git(["rev-parse", "--show-toplevel"], cwd: worktreeRoot)
        let branchVerification = await git(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            cwd: worktreeRoot
        )
        let commonVerification = await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: worktreeRoot
        )
        guard verification.status == 0,
              branchVerification.status == 0,
              commonVerification.status == 0,
              branchVerification.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == branch,
              URL(fileURLWithPath: commonVerification.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
              )).standardizedFileURL.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: commonDirectory)
                    .standardizedFileURL.resolvingSymlinksInPath().path,
              URL(fileURLWithPath: verification.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
              )).standardizedFileURL.resolvingSymlinksInPath().path == worktreeRoot.path else {
            return .failed(
                reason: "builder_worktree_verification_failed",
                detail: boundedDetail(verification)
            )
        }

        let suffix = String(baseURL.path.dropFirst(repoRoot.path.count))
        let isolatedDirectory = URL(fileURLWithPath: worktreeRoot.path + suffix)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: isolatedDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return .failed(
                reason: "builder_worktree_subdirectory_missing",
                detail: "The requested builder subdirectory is not present at the committed HEAD used by the isolated worktree."
            )
        }

        let assignment = Assignment(
            workingDirectory: isolatedDirectory.path,
            token: token
        )
        do {
            try writePointer(
                assignment,
                agent: agent,
                identity: identity,
                configRoot: configRoot
            )
        } catch {
            return .failed(
                reason: "builder_worktree_pointer_write_failed",
                detail: String(describing: error)
            )
        }
        // Retirement runs exactly where new disk is taken, so allocation pays
        // for its own cleanup and no message path gets a cost it did not cause.
        await retireIdleWorktrees(
            agent: agent,
            repoRoot: repoRoot,
            commonDirectory: commonDirectory,
            configRoot: configRoot,
            keeping: [worktreeRoot.path, isolatedDirectory.path]
        )
        return .assigned(assignment)
    }

    func bind(
        _ assignment: Assignment,
        agent: Agent,
        conversationId: String,
        configRoot: URL
    ) -> AllocationResult {
        do {
            try writePointer(
                assignment,
                agent: agent,
                identity: conversationId,
                configRoot: configRoot
            )
            return .assigned(assignment)
        } catch {
            return .failed(
                reason: "builder_worktree_pointer_write_failed",
                detail: String(describing: error)
            )
        }
    }

    private func existingAssignment(
        agent: Agent,
        identity: String,
        configRoot: URL
    ) async -> Assignment? {
        let pointer = pointerURL(agent: agent, identity: identity, configRoot: configRoot)
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        let workingDirectory = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let token = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty,
              token.count == 16,
              token.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else { return nil }
        let directory = URL(fileURLWithPath: workingDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let root = await git(["rev-parse", "--show-toplevel"], cwd: directory)
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory)
        guard root.status == 0,
              branch.status == 0,
              branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "nativeagent/\(agent.rawValue)-\(token)",
              URL(fileURLWithPath: root.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
              )).lastPathComponent.hasSuffix("-wt-\(agent.rawValue)-\(token)") else {
            return nil
        }
        return Assignment(workingDirectory: directory.path, token: token)
    }

    private func writePointer(
        _ assignment: Assignment,
        agent: Agent,
        identity: String,
        configRoot: URL
    ) throws {
        let pointer = pointerURL(agent: agent, identity: identity, configRoot: configRoot)
        try FileManager.default.createDirectory(
            at: pointer.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((assignment.workingDirectory + "\n" + assignment.token + "\n").utf8)
            .write(to: pointer, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pointer.path
        )
    }

    private func pointerURL(agent: Agent, identity: String, configRoot: URL) -> URL {
        configRoot
            .appendingPathComponent("nativeagent-builder-worktrees", isDirectory: true)
            .appendingPathComponent(agent.rawValue, isDirectory: true)
            .appendingPathComponent(stableToken(identity) + ".path")
    }

    private func mayBeGitCheckout(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        var candidate = directory
        while true {
            if pathEntryExists(
                candidate.appendingPathComponent(".git"),
                fileManager: fileManager
            ) {
                return true
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        // A selected bare repository has no `.git` child, but its canonical
        // control entries still make it unsafe to treat as an ordinary folder.
        return pathEntryExists(directory.appendingPathComponent("HEAD"), fileManager: fileManager)
            && pathEntryExists(directory.appendingPathComponent("objects"), fileManager: fileManager)
            && pathEntryExists(directory.appendingPathComponent("refs"), fileManager: fileManager)
    }

    private func pathEntryExists(_ url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func stableToken(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func boundedDetail(_ result: GitResult) -> String {
        let raw = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((raw.isEmpty ? fallback : raw).suffix(2_000))
    }

    // MARK: retirement

    /// A builder checkout is retired only after its conversation has been
    /// untouched this long. The pointer file's mtime is that clock: written on
    /// assignment, refreshed on every reuse above.
    static let retirementIdleSeconds: TimeInterval = 7 * 24 * 60 * 60
    /// One sweep does a bounded amount of work, so a single allocation can
    /// never turn into a long git session.
    static let retirementRemovalsPerSweep = 3

    private func touchPointer(agent: Agent, identity: String, configRoot: URL) {
        let pointer = pointerURL(agent: agent, identity: identity, configRoot: configRoot)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: pointer.path
        )
    }

    /// Remove idle builder checkouts of THIS agent in THIS repository whose
    /// branch holds nothing that is not already somewhere else.
    ///
    /// Every test is fail-closed: anything unreadable, unrecognized, dirty, or
    /// holding a commit unique to its branch is kept. Branches are never
    /// deleted — the reclaimable cost is the checkout, and a branch that still
    /// exists means a retired worktree can be recreated at its own tip.
    /// Each outcome, including a refusal, is appended to `retirements.jsonl`
    /// beside the pointers.
    private func retireIdleWorktrees(
        agent: Agent,
        repoRoot: URL,
        commonDirectory: String,
        configRoot: URL,
        keeping keptPaths: Set<String>
    ) async {
        let pointerDirectory = configRoot
            .appendingPathComponent("nativeagent-builder-worktrees", isDirectory: true)
            .appendingPathComponent(agent.rawValue, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pointerDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.retirementIdleSeconds)
        let expectedCommon = URL(fileURLWithPath: commonDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        // A worktree can be named by more than one pointer (the bootstrap
        // `message:<id>` alias and the later `codex:<thread>` binding). Its
        // idleness is the NEWEST touch across all of them, never one pointer's
        // (GPT-5.6 review: a stale alias must not retire a live checkout).
        var newestTouch: [String: Date] = [:]
        let pointerFiles = entries.filter { $0.pathExtension == "path" }
        for pointer in pointerFiles {
            guard let touched = (try? pointer.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate,
                  let raw = try? String(contentsOf: pointer, encoding: .utf8),
                  let first = raw.split(separator: "\n", omittingEmptySubsequences: false).first
            else { continue }
            let directory = URL(fileURLWithPath: String(first).trimmingCharacters(in: .whitespacesAndNewlines))
                .standardizedFileURL.resolvingSymlinksInPath().path
            newestTouch[directory] = max(newestTouch[directory] ?? .distantPast, touched)
        }
        var removed = 0
        for pointer in pointerFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if removed >= Self.retirementRemovalsPerSweep { break }
            guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { continue }
            guard let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first else { continue }
            let pointedDirectory = URL(fileURLWithPath: String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines))
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard let touchedAt = newestTouch[pointedDirectory], touchedAt < cutoff else { continue }
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2 else { continue }
            let recordedDirectory = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let token = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recordedDirectory.isEmpty, token.count == 16 else { continue }
            let directory = URL(fileURLWithPath: recordedDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
            if keptPaths.contains(directory.path) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { continue }

            let branch = "nativeagent/\(agent.rawValue)-\(token)"
            let toplevel = await git(["rev-parse", "--show-toplevel"], cwd: directory)
            let common = await git(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                cwd: directory
            )
            let head = await git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory)
            guard toplevel.status == 0, common.status == 0, head.status == 0 else { continue }
            let worktreeRoot = URL(fileURLWithPath: toplevel.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
            )).standardizedFileURL.resolvingSymlinksInPath()
            guard URL(fileURLWithPath: common.stdout.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  )).standardizedFileURL.resolvingSymlinksInPath().path == expectedCommon,
                  head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == branch,
                  worktreeRoot.lastPathComponent.hasSuffix("-wt-\(agent.rawValue)-\(token)"),
                  !keptPaths.contains(worktreeRoot.path) else { continue }

            // Uncommitted or untracked work is work. Keep it.
            let dirty = await git(["status", "--porcelain"], cwd: worktreeRoot)
            guard dirty.status == 0,
                  dirty.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            // Commits reachable from this branch and from NO other ref. Zero
            // means everything here also lives somewhere else (merged, or
            // pushed, or simply never committed), so the checkout is the only
            // thing being reclaimed.
            let unique = await git([
                "rev-list", "--count", "refs/heads/\(branch)",
                "--not", "--exclude=refs/heads/\(branch)", "--all",
            ], cwd: worktreeRoot)
            guard unique.status == 0,
                  unique.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
            else { continue }

            let idleDays = Int(now.timeIntervalSince(touchedAt) / 86_400)
            let remove = await git(
                ["worktree", "remove", worktreeRoot.path],
                cwd: repoRoot
            )
            if remove.status == 0 {
                // Drop EVERY pointer that named this checkout, not just the
                // one that led here, so no alias is left dangling.
                for alias in pointerFiles {
                    if let aliasRaw = try? String(contentsOf: alias, encoding: .utf8),
                       let aliasFirst = aliasRaw.split(separator: "\n", omittingEmptySubsequences: false).first,
                       URL(fileURLWithPath: String(aliasFirst).trimmingCharacters(in: .whitespacesAndNewlines))
                           .standardizedFileURL.resolvingSymlinksInPath().path == pointedDirectory {
                        try? FileManager.default.removeItem(at: alias)
                    }
                }
                removed += 1
            }
            appendRetirementReceipt([
                "at": Self.iso8601(now),
                "agent": agent.rawValue,
                "worktree": worktreeRoot.path,
                "branch": branch,
                "lastTouchedAt": Self.iso8601(touchedAt),
                "idleDays": idleDays,
                "uniqueCommits": 0,
                "status": remove.status == 0 ? "retired" : "remove_refused",
                "detail": remove.status == 0 ? "" : boundedDetail(remove),
            ], configRoot: configRoot)
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func appendRetirementReceipt(_ row: [String: Any], configRoot: URL) {
        let ledger = configRoot
            .appendingPathComponent("nativeagent-builder-worktrees", isDirectory: true)
            .appendingPathComponent("retirements.jsonl")
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: ledger) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            return
        }
        try? line.write(to: ledger, options: .atomic)
    }

    private func git(_ arguments: [String], cwd: URL) async -> GitResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: GitResult(
                    status: process.terminationStatus,
                    stdout: String(data: out, encoding: .utf8) ?? "",
                    stderr: String(data: err, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: GitResult(
                    status: -1,
                    stdout: "",
                    stderr: String(describing: error)
                ))
            }
        }
    }
}
