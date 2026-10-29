import Foundation
import NativeAgentCore
import CryptoKit
import MacControl
import PersistenceCore
import TurnTrace
// Blueprint: | `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator` actor; `resolve`, `bind`; allocation reserves config root/agent/conversation before suspension and waiters reread the winning assignment; checkout reservations exclude reuse/allocation/binding from retirement through Git awaits, with freshness reread while held; unreadable or invalid retained pointers refuse continuity with the exact field and fileRepairInstruction for the person, never a coding-agent repair call |

/// The narrow isolation seam for asynchronous coding builders.
///
/// A new Codex, Claude, or OMP conversation gets one ordinary Git worktree. The
/// bridge stores only a conversation -> path pointer so later messages can
/// return to the same checkout. There is intentionally no Factory lifecycle,
/// manifest, receipt schema, or scheduler here. Idle checkout retirement shares
/// checkout ownership with allocation, reuse and conversation binding.
/// Omitted and ordinary non-Git directories retain their original cwd
/// semantics; Git evidence with an unsuccessful probe fails closed.
/// Two-line path/token pointers and Git worktrees are local builder state:
/// excluded from app backup/export/phone sync; PrivacyMap: bridge_worktrees.
actor BuilderWorktreeAllocator {
    static let shared = BuilderWorktreeAllocator()

    // Aliases of one checkout share its token. Keep ownership across Git
    // suspensions; actor isolation alone does not exclude retirement.
    private enum Reservation: Hashable {
        case checkout(String)
        case allocation(String)
    }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var reservations: [Reservation: [Waiter]] = [:]

    private func reserve(_ key: Reservation) async throws {
        try Task.checkCancellation()
        if reservations[key] == nil {
            reservations[key] = []
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                reservations[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, for: key) }
        }
        // Release ownership if cancellation raced the successful handoff.
        if Task.isCancelled {
            release(key)
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID, for key: Reservation) {
        guard var waiters = reservations[key],
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        reservations[key] = waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: Reservation) {
        if var waiters = reservations[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            reservations[key] = waiters
            next.continuation.resume()
        } else {
            reservations[key] = nil
        }
    }

    enum Agent: String, Sendable {
        case codex
        case claude
        case omp
    }

    struct Assignment: Sendable, Equatable {
        let workingDirectory: String
        fileprivate let token: String
        /// The assigned directory wins; the receipt records any differing request.
        var ignoredRequestedDirectory: String? = nil

        static func decode(_ raw: String, pointer: URL) throws -> Self {
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2 else {
                throw BuilderWorktreeAllocator.pointerFailure(pointer, field: "lines 1–2", detail: "Expected a working directory followed by its 16-character token.")
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

    /// All three bridges share the receipt wording for an ignored directory request.
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
    ) async throws -> AllocationResult {
        // Reserve the conversation before the first suspension, independently
        // of the requested repository. A waiter rereads the winning pointer.
        let identity = conversationId ?? "message:\(messageId)"
        let allocationKey = pointerURL(agent: agent, identity: identity, configRoot: configRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path
        try await reserve(.allocation(allocationKey))
        defer { release(.allocation(allocationKey)) }
        let baseDirectory = requestedDirectory ?? defaultDirectory

        if isFollowUp, let conversationId,
           let existing = try await existingAssignment(
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
                    return .assigned(noted)
                }
            }
            return .assigned(existing)
        }
        guard let baseDirectory else { return .unchanged(nil) }

        if let existing = try await existingAssignment(
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
        guard let suffix = NativeAgentWorkspaceRoot.relativePath(baseURL.path, under: repoRoot.path) else {
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

        try await reserve(.checkout(token))
        defer { release(.checkout(token)) }

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
    ) async -> AllocationResult {
        do {
            try await reserve(.checkout(assignment.token))
        } catch {
            return .failed(reason: "builder_worktree_stopped", detail: "Stopped while waiting to bind the builder checkout.")
        }
        defer { release(.checkout(assignment.token)) }
        guard FileManager.default.fileExists(atPath: assignment.workingDirectory) else {
            return .failed(
                reason: "builder_worktree_verification_failed",
                detail: "The assigned builder checkout no longer exists; the conversation was not bound."
            )
        }
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
    ) async throws -> Assignment? {
        let pointer = pointerURL(agent: agent, identity: identity, configRoot: configRoot)
        let raw: String
        do {
            raw = try String(contentsOf: pointer, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile where !pathEntryExists(pointer, fileManager: .default) {
            return nil
        } catch {
            throw Self.pointerFailure(pointer, field: "contents", detail: error.localizedDescription)
        }
        let assignment = try Assignment.decode(raw, pointer: pointer)
        let token = assignment.token
        try await reserve(.checkout(token))
        defer { release(.checkout(token)) }
        // Retirement may have finished while this reuse waited. Reread under
        // checkout ownership before checking Git or publishing a fresh touch.
        if !pathEntryExists(pointer, fileManager: .default) { return nil }
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
        let root = await git(["rev-parse", "--show-toplevel"], cwd: directory)
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory)
        guard root.status == 0, branch.status == 0 else {
            throw Self.pointerFailure(pointer, field: "line 1 (working directory)",
                                 detail: "Git could not verify \(directory.path): \(boundedDetail(root)) \(boundedDetail(branch))")
        }
        guard branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "nativeagent/\(agent.rawValue)-\(token)",
              URL(fileURLWithPath: root.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
              )).lastPathComponent.hasSuffix("-wt-\(agent.rawValue)-\(token)") else {
            throw Self.pointerFailure(pointer, field: "lines 1–2 (assignment)",
                                 detail: "Expected branch nativeagent/\(agent.rawValue)-\(token) in a checkout ending -wt-\(agent.rawValue)-\(token); found branch \(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) at \(root.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).")
        }
        touchPointer(agent: agent, identity: identity, configRoot: configRoot)
        return Assignment(workingDirectory: directory.path, token: token)
    }

    private static func pointerFailure(_ pointer: URL, field: String, detail: String) -> ToolFailureError {
        ToolFailureError("Builder assignment is unreadable or invalid; no builder started. \(detail) Repair the retained assignment or checkout before resending.",
                         effects: .none, owner: "\(pointer.path) > \(field)",
                         code: "builder_assignment_invalid", instruction: ToolFailureError.fileRepairInstruction(pointer,
                            shape: "Builder assignment field \(field) is invalid: \(detail). Establish the assignment only from retained Git and pointer evidence. Never guess repository, branch or token, discard work, switch branches, assign another checkout or resend the message."))
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
        SHA256.hash(data: Data(InstallPaths.current.name(value).utf8)).prefix(8).map {
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
    /// Retirement observations join the allocating turn's existing trace.
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
        let pointerFiles = entries.filter { $0.pathExtension == "path" }
        var removed = 0
        for pointer in pointerFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if removed >= Self.retirementRemovalsPerSweep { break }
            guard let raw = try? String(contentsOf: pointer, encoding: .utf8),
                  let assignment = try? Assignment.decode(raw, pointer: pointer) else { continue }
            let directory = URL(fileURLWithPath: assignment.workingDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
            let pointedDirectory = directory.path
            let token = assignment.token
            // A reuse already checking Git wins. Otherwise retirement owns
            // this checkout through every Git await and pointer deletion.
            guard reservations[.checkout(token)] == nil else { continue }
            reservations[.checkout(token)] = []
            defer { release(.checkout(token)) }
            guard let aliases = try? FileManager.default.contentsOfDirectory(
                at: pointerDirectory, includingPropertiesForKeys: nil
            ).filter({ $0.pathExtension == "path" }) else { continue }
            // Recompute freshness while reserved, including aliases published
            // since the sweep began. Fresh URLs avoid cached resource values.
            var newestTouch: Date?
            for alias in aliases {
                guard let aliasRaw = try? String(contentsOf: alias, encoding: .utf8),
                      let aliasAssignment = try? Assignment.decode(aliasRaw, pointer: alias),
                      URL(fileURLWithPath: aliasAssignment.workingDirectory)
                        .standardizedFileURL.resolvingSymlinksInPath().path == pointedDirectory,
                      let touched = (try? URL(fileURLWithPath: alias.path).resourceValues(
                        forKeys: [.contentModificationDateKey]
                      ))?.contentModificationDate else { continue }
                newestTouch = max(newestTouch ?? .distantPast, touched)
            }
            guard let touchedAt = newestTouch, touchedAt < cutoff else { continue }
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

            let remove = await git(
                ["worktree", "remove", worktreeRoot.path],
                cwd: repoRoot
            )
            if remove.status == 0 {
                // Drop EVERY pointer that named this checkout, not just the
                // one that led here, so no alias is left dangling.
                for alias in aliases {
                    if let aliasRaw = try? String(contentsOf: alias, encoding: .utf8),
                       let aliasAssignment = try? Assignment.decode(aliasRaw, pointer: alias),
                       URL(fileURLWithPath: aliasAssignment.workingDirectory)
                           .standardizedFileURL.resolvingSymlinksInPath().path == pointedDirectory {
                        try? FileManager.default.removeItem(at: alias)
                    }
                }
                removed += 1
            }
            TurnTraceBus.fireFromContext(kind: "builder.worktree_retirement", payload: .object([
                "agent": .string(agent.rawValue),
                "worktree": .string(ChatSecretRedactor.redactText(worktreeRoot.path)),
                "branch": .string(branch),
                "idleDays": .int(Int64(now.timeIntervalSince(touchedAt) / 86_400)),
                "uniqueCommits": .int(0),
                "status": .string(remove.status == 0 ? "retired" : "remove_refused"),
                "detail": .string(ChatSecretRedactor.redactText(remove.status == 0 ? "" : boundedDetail(remove))),
            ]))
        }
    }

    private func git(_ arguments: [String], cwd: URL) async -> GitResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        do {
            let result = try await ProcessExecution().run(
                executable: "/usr/bin/git", arguments: arguments,
                currentDirectory: cwd, environment: environment,
                standardInput: nil, timeoutSeconds: 30
            )
            return GitResult(
                status: result.timedOut ? -1 : result.exitCode,
                stdout: result.stdout,
                stderr: result.timedOut ? "Git timed out.\n" + result.stderr : result.stderr
            )
        } catch {
            return GitResult(status: -1, stdout: "", stderr: String(describing: error))
        }
    }
}
