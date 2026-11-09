import Foundation
import NativeAgentCore
import CryptoKit
import MacControl
import PersistenceCore
// Blueprint: | `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator`, `resolve`, `discard`: one worktree per job |

/// Each job owns one Git worktree on its own branch `nativeagent/job-<token>`; no contact or vendor names it. The pointer maps the job's identity to its
/// path, never another transcript or scheduler. Allocation, reuse and explicit discard share checkout ownership. A directory with no Git evidence is
/// left unchanged; failed Git probes refuse selection.
/// Two-line path/token pointers and worktrees are local builder state, excluded from backup/export/phone sync; PrivacyMap: bridge_worktrees.
package actor BuilderWorktreeAllocator {
    package static let shared = BuilderWorktreeAllocator()

    // Aliases of one checkout share its token. Keep ownership across Git suspensions; actor isolation alone does not exclude another operation.
    private enum Reservation: Hashable {
        case checkout(String)
        case allocation(String)
    }
    private struct Waiter {
        let id: UUID
        let done: ScopedWaiter
    }
    private var reservations: [Reservation: [Waiter]] = [:]

    private func reserve(_ key: Reservation) async throws {
        try Task.checkCancellation()
        if reservations[key] == nil {
            reservations[key] = []
            return
        }
        let id = UUID()
        let done = ScopedWaiter()
        reservations[key, default: []].append(Waiter(id: id, done: done))
        await done.park()
        if let index = reservations[key]?.firstIndex(where: { $0.id == id }) {
            reservations[key]?.remove(at: index)
            throw CancellationError()
        }
        // Release ownership if cancellation raced the successful handoff.
        if Task.isCancelled {
            release(key)
            throw CancellationError()
        }
    }

    private func release(_ key: Reservation) {
        if var waiters = reservations[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            reservations[key] = waiters
            next.done.resume()
        } else {
            reservations[key] = nil
        }
    }

    /// The one branch and checkout name every allocation uses.
    static func branch(_ token: String) -> String { "nativeagent/job-\(token)" }
    static func checkoutSuffix(_ token: String) -> String { "-wt-job-\(token)" }

    package struct Assignment: Sendable, Equatable {
        package let workingDirectory: String
        fileprivate let token: String
        package var branch: String { BuilderWorktreeAllocator.branch(token) }

        static func decode(_ raw: String, pointer: URL) throws -> Self {
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2 else {
                throw BuilderWorktreeAllocator.pointerFailure(pointer, field: "lines 1–2",
                    detail: "Expected a working directory followed by its 16-character token.")
            }
            let directory = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let token = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard directory.hasPrefix("/") else {
                throw BuilderWorktreeAllocator.pointerFailure(pointer, field: "line 1 (working directory)", detail: "Expected an absolute directory path.")
            }
            guard token.count == 16, token.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
                throw BuilderWorktreeAllocator.pointerFailure(pointer, field: "line 2 (token)", detail: "Expected 16 lowercase hexadecimal characters.")
            }
            return Self(workingDirectory: directory, token: token)
        }
    }

    package enum AllocationResult: Sendable, Equatable {
        case unchanged
        case assigned(Assignment)
        case failed(reason: String, detail: String)
    }

    package struct GitResult: Sendable {
        package let status: Int32
        package let stdout: String
        package let stderr: String
        package var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    package func resolve(identity: String, directory baseDirectory: String, configRoot: URL) async throws -> AllocationResult {
        // Reserve the identity before the first suspension, independently of the repository. A waiter rereads the winning pointer.
        let allocationKey = pointerURL(identity: identity, configRoot: configRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path
        try await reserve(.allocation(allocationKey))
        defer { release(.allocation(allocationKey)) }

        if let existing = try await existingAssignment(
            identity: identity,
            configRoot: configRoot
        ) {
            return .assigned(existing)
        }

        let baseURL = URL(fileURLWithPath: baseDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let topLevel = await Self.git(["rev-parse", "--show-toplevel"], cwd: baseURL)
        guard topLevel.status == 0 else {
            if try topLevel.status == -1 || mayBeGitCheckout(baseURL) {
                return .failed(
                    reason: "builder_worktree_git_probe_failed",
                    detail: Self.detail(topLevel)
                )
            }
            // A directory with no Git evidence gets no worktree.
            return .unchanged
        }
        let repoRoot = URL(fileURLWithPath: topLevel.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )).standardizedFileURL.resolvingSymlinksInPath()
        guard let suffix = NativeAgentWorkspaceRoot.relativePath(baseURL.path, under: repoRoot.path) else {
            return .failed(
                reason: "builder_worktree_source_invalid",
                detail: "Git reported a repository root that does not contain the requested builder directory."
            )
        }

        let commonDirectoryResult = await Self.git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: repoRoot
        )
        guard commonDirectoryResult.status == 0 else {
            return .failed(
                reason: "builder_worktree_git_failed",
                detail: Self.detail(commonDirectoryResult)
            )
        }
        let commonDirectory = commonDirectoryResult.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let token = stableToken("\(commonDirectory)\u{0}\(identity)")
        let branch = Self.branch(token)
        let worktreeRoot = repoRoot.deletingLastPathComponent().appendingPathComponent(
            repoRoot.lastPathComponent + Self.checkoutSuffix(token),
            isDirectory: true
        )

        try await reserve(.checkout(token))
        defer { release(.checkout(token)) }

        if !FileManager.default.fileExists(atPath: worktreeRoot.path) {
            let branchRead = await Self.git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repoRoot)
            guard branchRead.status == 0 || branchRead.status == 1 else {
                return .failed(reason: "builder_worktree_git_failed", detail: Self.detail(branchRead))
            }
            let branchExists = branchRead.status == 0
            let arguments = branchExists
                ? ["worktree", "add", worktreeRoot.path, branch]
                : ["worktree", "add", "-b", branch, worktreeRoot.path, "HEAD"]
            let add = await Self.git(arguments, cwd: repoRoot)
            guard add.status == 0 else {
                return .failed(
                    reason: "builder_worktree_create_failed",
                    detail: Self.detail(add)
                )
            }
        }

        let verification = await Self.git(["rev-parse", "--show-toplevel"], cwd: worktreeRoot)
        let branchVerification = await Self.git(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            cwd: worktreeRoot
        )
        let commonVerification = await Self.git(
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
                detail: Self.detail(verification)
            )
        }

        let isolatedDirectory = worktreeRoot.appendingPathComponent(suffix).standardizedFileURL
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

    package enum DiscardResult: Sendable, Equatable {
        /// `note` names a pointer that could not be removed; the checkout and branch are gone either way.
        case discarded(worktree: Bool, branch: Bool, note: String?)
        /// `worktreeRemoved` says whether the checkout was already gone when the branch step failed.
        case failed(reason: String, detail: String, worktreeRemoved: Bool)
    }

    /// Remove the worktree `identity` was given in `repo`, uncommitted work included, and delete its branch. Only the checkout and branch this identity's
    /// token names are touched; a folder at that path that does not verify as this repository's worktree stays.
    package func discard(identity: String, repo: String, configRoot: URL) async -> DiscardResult {
        func failed(_ reason: String, _ result: GitResult, removed: Bool = false) -> DiscardResult {
            .failed(reason: reason, detail: Self.detail(result), worktreeRemoved: removed)
        }
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        let topLevel = await Self.git(["rev-parse", "--show-toplevel"], cwd: URL(fileURLWithPath: resolved(repo), isDirectory: true))
        guard topLevel.status == 0 else { return failed("builder_worktree_git_failed", topLevel) }
        let repoRoot = URL(fileURLWithPath: resolved(topLevel.trimmed), isDirectory: true)
        let common = await Self.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repoRoot)
        guard common.status == 0 else { return failed("builder_worktree_git_failed", common) }
        // The same derivation as resolve: the token, branch and checkout path follow from the repository and the identity alone.
        let commonDirectory = common.trimmed
        let token = stableToken("\(commonDirectory)\u{0}\(identity)")
        let branch = Self.branch(token)
        let worktreeRoot = repoRoot.deletingLastPathComponent()
            .appendingPathComponent(repoRoot.lastPathComponent + Self.checkoutSuffix(token), isDirectory: true)
        do { try await reserve(.checkout(token)) } catch {
            return .failed(reason: "builder_worktree_stopped", detail: "Stopped while waiting for the checkout. Nothing was removed.", worktreeRemoved: false)
        }
        defer { release(.checkout(token)) }
        var removedWorktree = false
        let checkoutExists: Bool
        do { checkoutExists = try pathEntryExists(worktreeRoot, fileManager: .default) }
        catch { return .failed(reason: "builder_worktree_unreadable", detail: error.localizedDescription, worktreeRemoved: false) }
        if checkoutExists {
            let toplevel = await Self.git(["rev-parse", "--show-toplevel"], cwd: worktreeRoot)
            let ownCommon = await Self.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: worktreeRoot)
            guard toplevel.status == 0, ownCommon.status == 0, resolved(toplevel.trimmed) == worktreeRoot.path,
                  resolved(ownCommon.trimmed) == resolved(commonDirectory) else {
                return .failed(reason: "builder_worktree_verification_failed",
                               detail: "\(worktreeRoot.path) does not verify as this job's worktree of \(repoRoot.path). Nothing was removed.",
                               worktreeRemoved: false)
            }
            let remove = await Self.git(["worktree", "remove", "--force", worktreeRoot.path], cwd: repoRoot)
            guard remove.status == 0 else { return failed("builder_worktree_remove_failed", remove) }
            removedWorktree = true
        } else {
            // A checkout deleted by hand stays registered to its branch until Git forgets it; forget only this one.
            let listed = await Self.git(["worktree", "list", "--porcelain"], cwd: repoRoot)
            guard listed.status == 0 else { return failed("builder_worktree_git_failed", listed) }
            if listed.stdout.split(separator: "\n").contains(where: { $0.hasPrefix("worktree ") && resolved(String($0.dropFirst(9))) == worktreeRoot.path }) {
                let remove = await Self.git(["worktree", "remove", "--force", worktreeRoot.path], cwd: repoRoot)
                guard remove.status == 0 else { return failed("builder_worktree_remove_failed", remove) }
                removedWorktree = true
            }
        }
        let exists = await Self.git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repoRoot)
        var deletedBranch = false
        switch exists.status {
        case 0:
            let delete = await Self.git(["branch", "-D", branch], cwd: repoRoot)
            guard delete.status == 0 else { return failed("builder_branch_delete_failed", delete, removed: removedWorktree) }
            deletedBranch = true
        case 1: break
        default: return failed("builder_worktree_git_failed", exists, removed: removedWorktree)
        }
        // Every pointer that named this checkout goes with it, so no alias is left dangling.
        var leftover: [String] = []
        do {
            for alias in try FileManager.default.contentsOfDirectory(at: pointerDirectory(configRoot), includingPropertiesForKeys: nil)
            where alias.pathExtension == "path" {
                do {
                    let named = try Assignment.decode(String(contentsOf: alias, encoding: .utf8), pointer: alias)
                    guard named.token == token else { continue }
                    try FileManager.default.removeItem(at: alias)
                } catch { leftover.append("\(alias.path): \(error.localizedDescription)") }
            }
        } catch CocoaError.fileReadNoSuchFile {
        } catch { leftover.append("\(pointerDirectory(configRoot).path): \(error.localizedDescription)") }
        return .discarded(worktree: removedWorktree, branch: deletedBranch,
                          note: leftover.isEmpty ? nil : "Pointers left in place: " + leftover.joined(separator: "; "))
    }

    private func existingAssignment(
        identity: String,
        configRoot: URL
    ) async throws -> Assignment? {
        let pointer = pointerURL(identity: identity, configRoot: configRoot)
        let raw: String
        do {
            raw = try String(contentsOf: pointer, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            guard try pathEntryExists(pointer, fileManager: .default) else { return nil }
            throw Self.pointerFailure(pointer, field: "contents", detail: "The pointer exists but its contents cannot be read.")
        } catch {
            throw Self.pointerFailure(pointer, field: "contents", detail: error.localizedDescription)
        }
        let assignment = try Assignment.decode(raw, pointer: pointer)
        let token = assignment.token
        try await reserve(.checkout(token))
        defer { release(.checkout(token)) }
        // Discard may finish while reuse waits; reread under checkout ownership.
        if try !pathEntryExists(pointer, fileManager: .default) { return nil }
        guard try String(contentsOf: pointer, encoding: .utf8) == raw else {
            throw Self.pointerFailure(pointer, field: "contents", detail: "The assignment changed while waiting to reuse its checkout.")
        }
        let directory = URL(fileURLWithPath: assignment.workingDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Self.pointerFailure(pointer, field: "line 1 (working directory)", detail: "The assigned directory does not exist: \(directory.path)")
        }
        let root = await Self.git(["rev-parse", "--show-toplevel"], cwd: directory)
        let branch = await Self.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory)
        guard root.status == 0, branch.status == 0 else {
            throw Self.pointerFailure(pointer, field: "line 1 (working directory)",
                                 detail: "Git could not verify \(directory.path): \(Self.detail(root)) \(Self.detail(branch))")
        }
        guard branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == Self.branch(token),
              URL(fileURLWithPath: root.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
              )).lastPathComponent.hasSuffix(Self.checkoutSuffix(token)) else {
            throw Self.pointerFailure(pointer, field: "lines 1–2 (assignment)",
                                 detail: """
                                     Expected branch \(Self.branch(token)) in a checkout ending \(Self.checkoutSuffix(token)); \
                                     found branch \(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) at \
                                     \(root.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).
                                     """)
        }
        return Assignment(workingDirectory: directory.path, token: token)
    }

    private static func pointerFailure(_ pointer: URL, field: String, detail: String) -> ToolFailureError {
        ToolFailureError("""
            Builder assignment is unreadable or invalid; no builder started. \(detail) Repair the retained assignment or checkout before resending.
            """,
                         effects: .none, owner: "\(pointer.path) > \(field)",
                         code: "builder_assignment_invalid", instruction: ToolFailureError.fileRepairInstruction(pointer,
                            shape: """
                                Builder assignment field \(field) is invalid: \(detail). Establish the assignment only from retained Git and \
                                pointer evidence. Never guess repository, branch or token, discard work, switch branches, assign another checkout \
                                or resend the message.
                                """))
    }

    private func writePointer(
        _ assignment: Assignment,
        identity: String,
        configRoot: URL
    ) throws {
        let pointer = pointerURL(identity: identity, configRoot: configRoot)
        try FileManager.default.createDirectory(
            at: pointer.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((assignment.workingDirectory + "\n" + assignment.token + "\n").utf8)
            .write(to: pointer, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pointer.path
        )
    }

    private func pointerDirectory(_ configRoot: URL) -> URL {
        configRoot.appendingPathComponent("nativeagent-builder-worktrees", isDirectory: true)
    }

    private func pointerURL(identity: String, configRoot: URL) -> URL {
        pointerDirectory(configRoot).appendingPathComponent(stableToken(identity) + ".path")
    }

    private func mayBeGitCheckout(_ directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        var candidate = directory
        while true {
            if try pathEntryExists(
                candidate.appendingPathComponent(".git"),
                fileManager: fileManager
            ) {
                return true
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        // A selected bare repository has no `.git` child, but its canonical control entries still make it unsafe to treat as an ordinary folder.
        return try pathEntryExists(directory.appendingPathComponent("HEAD"), fileManager: fileManager)
            && pathEntryExists(directory.appendingPathComponent("objects"), fileManager: fileManager)
            && pathEntryExists(directory.appendingPathComponent("refs"), fileManager: fileManager)
    }

    private func pathEntryExists(_ url: URL, fileManager: FileManager) throws -> Bool {
        do { _ = try fileManager.attributesOfItem(atPath: url.path); return true }
        catch CocoaError.fileReadNoSuchFile { return false }
    }

    private func stableToken(_ value: String) -> String {
        SHA256.hash(data: Data(InstallPaths.current.name(value).utf8)).prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Git's own words for a result: stderr when it said anything there, else stdout, bounded.
    package nonisolated static func detail(_ result: GitResult) -> String {
        let raw = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((raw.isEmpty ? stdout : raw).suffix(2_000))
    }

    /// Git runs until process settlement or explicit cancellation; launch failures retain their cause.
    package nonisolated static func git(_ arguments: [String], cwd: URL) async -> GitResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        do {
            let result = try await ProcessExecution().run(
                executable: "/usr/bin/git", arguments: arguments,
                currentDirectory: cwd, environment: environment,
                standardInput: nil, timeoutSeconds: nil
            )
            return GitResult(
                status: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        } catch {
            return GitResult(status: -1, stdout: "", stderr: String(describing: error))
        }
    }
}
