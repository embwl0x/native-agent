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
    }

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
                guard requestedPath == assignedPath else {
                    return .failed(
                        reason: "builder_worktree_follow_up_directory_conflict",
                        detail: "This conversation is assigned to \(assignedPath); its follow-up cannot switch to \(requestedPath)."
                    )
                }
            }
            return .assigned(existing)
        }
        guard let baseDirectory else { return .unchanged(nil) }

        let identity = conversationId ?? "message:\(messageId)"
        if let existing = await existingAssignment(
            agent: agent,
            identity: identity,
            configRoot: configRoot
        ) {
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
