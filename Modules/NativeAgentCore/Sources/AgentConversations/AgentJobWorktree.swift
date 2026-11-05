import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentJobWorktree.swift` | A repo job's own worktree: the cut, its diff captured as the agent's deliverable, the agent's apply and discard |

extension AgentJob {
    /// A repo job's own checkout: a worktree on its own branch, cut from the agent's repository's HEAD. It is the organ's folder; the agent's checkout never
    /// is.
    public struct Worktree: Codable, Sendable, Equatable {
        public var path: String
        public var branch: String
        /// The commit it was cut from; the diff is against it.
        public var base: String
        /// Set when the finished work was captured: the branch tip, the files changed against base, and the patch the stem made of them.
        public var head: String?
        public var files: [String]?
        public var patch: String?
        public var patchBytes: Int?
        /// The agent's merge commit, once agent.apply merged the branch.
        public var applied: String?
        public var discarded: Bool?
    }
}

/// The agent's own git: one call of the `git` tool through the agent's tool chain, so its gates, Trust and cards judge it as they judge every git write of the
/// agent's.
public typealias AgentJobGit = @Sendable (_ args: [String], _ cwd: String) async throws -> JSONValue

extension AgentJobs {
    static func worktreeConfigRoot(_ dataRoot: URL) -> URL { InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot) }

    private static func git(_ args: [String], _ folder: String, timeout: TimeInterval = 30) async -> BuilderWorktreeAllocator.GitResult {
        await BuilderWorktreeAllocator.git(args, cwd: URL(fileURLWithPath: folder, isDirectory: true), timeout: timeout)
    }

    private static func said(_ result: BuilderWorktreeAllocator.GitResult) -> String { BuilderWorktreeAllocator.detail(result) }

    // MARK: The cut

    /// Cut the repo job's worktree before its door runs. A refusal leaves nothing of the job behind.
    static func cut(_ id: String, repo: String, dataRoot: URL) async -> Result<AgentJob.Worktree, JobRefusal> {
        let result: BuilderWorktreeAllocator.AllocationResult
        do {
            result = try await BuilderWorktreeAllocator.shared.resolve(identity: id, directory: repo, configRoot: worktreeConfigRoot(dataRoot))
        } catch { return .failure(JobRefusal("Its worktree could not be made: \(error.localizedDescription) Nothing was sent.")) }
        switch result {
        case .unchanged:
            return .failure(JobRefusal("\(repo) did not answer as a Git repository, so no worktree was made. Nothing was sent."))
        case .failed(let reason, let detail):
            return .failure(JobRefusal("Its worktree could not be made (\(reason)): \(detail) Nothing was sent."))
        case .assigned(let assignment):
            let base = await git(["rev-parse", "--verify", "HEAD^{commit}"], assignment.workingDirectory)
            guard base.status == 0, !base.trimmed.isEmpty else {
                let left = await uncut(id, repo: repo, dataRoot: dataRoot)
                return .failure(JobRefusal("Its worktree's base commit could not be read: \(said(base)). \(left) Nothing was sent."))
            }
            return .success(.init(path: assignment.workingDirectory, branch: assignment.branch, base: base.trimmed))
        }
    }

    /// Undo a cut no organ ever worked in. Its own sentence says what is left.
    static func uncut(_ id: String, repo: String, dataRoot: URL) async -> String {
        switch await BuilderWorktreeAllocator.shared.discard(identity: id, repo: repo, configRoot: worktreeConfigRoot(dataRoot)) {
        case .discarded(_, _, let note): return "Its worktree and branch were removed." + (note.map { " " + $0 } ?? "")
        case .failed(let reason, let detail, _): return "Its worktree and branch could not be removed (\(reason)): \(detail)"
        }
    }

    // MARK: The diff

    /// What the organ made in its worktree, as one patch against base: its own commits as it wrote them, plus what it left uncommitted, which the stem commits
    /// on the job branch. The last commit carries `Assisted-by: <contact>:<model it reported>` unless it already has an Assisted-by trailer. Only the job's
    /// worktree and branch are written; the patch registers in Make as the agent's.
    static func capture(_ job: AgentJob, _ worktree: AgentJob.Worktree, dataRoot: URL, register: AgentJobRegistrar) async
        -> (worktree: AgentJob.Worktree, deliverable: AgentJob.Deliverable?) {
        let folder = worktree.path
        func kept(_ why: String) -> (worktree: AgentJob.Worktree, deliverable: AgentJob.Deliverable?) {
            (worktree, .init(path: folder, refusal: "its diff was not captured: \(why) The worktree and branch \(worktree.branch) keep the work."))
        }
        let on = await git(["symbolic-ref", "--quiet", "--short", "HEAD"], folder)
        guard on.status == 0, on.trimmed == worktree.branch else {
            return kept(on.status == 0 ? "the worktree is on \(on.trimmed), not its job branch." : on.status == 1
                ? "the worktree's HEAD is detached from its job branch." : "its branch could not be read: \(said(on)).")
        }
        let model = job.report?.model?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") ?? ""
        let trailer = "Assisted-by: \(job.name):\(model.isEmpty ? "unknown" : model)"
        // The stem's own commit runs no hooks: it records what the organ left. The agent's merge runs the agent's hooks.
        let quiet = ["-c", "core.hooksPath=/dev/null"]
        let status = await git(["status", "--porcelain", "--untracked-files=all"], folder)
        guard status.status == 0 else { return kept("git status failed: \(said(status)).") }
        if !status.trimmed.isEmpty {
            let add = await git(["add", "-A"], folder, timeout: 120)
            guard add.status == 0 else { return kept("git add failed: \(said(add)).") }
            let subject = "\(job.name) for \(job.id): " + String(job.brief.split(whereSeparator: \.isNewline).first?.prefix(72) ?? "")
            let commit = await git(quiet + ["commit", "--quiet", "--no-verify", "-m", subject, "--trailer", trailer], folder, timeout: 120)
            guard commit.status == 0 else { return kept("committing what it left uncommitted failed: \(said(commit)).") }
        } else {
            let own = await git(["rev-list", "--count", worktree.base + "..HEAD"], folder)
            guard own.status == 0 else { return kept("its commits could not be counted: \(said(own)).") }
            if own.trimmed != "0" {
                let carried = await git(["log", "-1", "--format=%(trailers:key=Assisted-by,valueonly)"], folder)
                guard carried.status == 0 else { return kept("its last commit could not be read: \(said(carried)).") }
                if carried.trimmed.isEmpty {
                    let amend = await git(quiet + ["commit", "--quiet", "--no-verify", "--amend", "--no-edit", "--trailer", trailer], folder, timeout: 120)
                    guard amend.status == 0 else { return kept("adding \(trailer) to its last commit failed: \(said(amend)).") }
                }
            }
        }
        let head = await git(["rev-parse", "--verify", "HEAD^{commit}"], folder)
        guard head.status == 0 else { return kept("its branch tip could not be read: \(said(head)).") }
        let names = await git(["diff", "--name-only", "-z", "--no-renames", worktree.base, head.trimmed], folder, timeout: 120)
        guard names.status == 0 else { return kept("its changed files could not be listed: \(said(names)).") }
        var captured = worktree
        captured.head = head.trimmed
        captured.files = names.stdout.split(separator: "\0").map(String.init)
        guard captured.files?.isEmpty == false else { return (captured, nil) }
        let patch = dataRoot.appendingPathComponent("agents/jobs/\(job.id).patch")
        do {
            try FileManager.default.createDirectory(at: patch.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return (captured, .init(path: patch.path, refusal: "the patch could not be written: \(error.localizedDescription)")) }
        let diff = await git(["diff", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                              "--output=" + patch.path, worktree.base, head.trimmed], folder, timeout: 120)
        guard diff.status == 0 else { return (captured, .init(path: patch.path, refusal: "the patch could not be written: \(said(diff))")) }
        do {
            guard let bytes = try patch.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return (captured, .init(path: patch.path, refusal: "the patch has no readable size, so it was not registered"))
            }
            captured.patch = patch.path
            captured.patchBytes = bytes
            // The job keeps its patch where its record points; Make holds the agent's copy.
            let made = try register(patch, AgentJobProvenance(contact: job.name, job: job.id, brief: job.brief))
            return (captured, .init(path: patch.path, ref: made.ref, version: made.version))
        } catch { return (captured, .init(path: patch.path, refusal: error.localizedDescription)) }
    }

    /// The diff as the agent reads it: branch, base, the files and the patch's size and Make ref, and the agent's two hands on it.
    static func diffView(_ job: AgentJob) -> JSONValue? {
        guard let worktree = job.worktree else { return nil }
        var fields: [String: JSONValue] = ["worktree": .string(worktree.path), "branch": .string(worktree.branch), "base": .string(worktree.base)]
        if let place = job.place { fields["repo"] = .string(place.path) }
        if let head = worktree.head { fields["head"] = .string(head) }
        if let files = worktree.files {
            fields["file_count"] = .int(Int64(files.count))
            fields["files"] = .array(files.prefix(200).map(JSONValue.string))
            if files.count > 200 { fields["files_shown"] = .int(200) }
        } else if job.state.isTerminal {
            fields["captured"] = .string("nothing: a diff is captured only when the job finishes, and none was. The worktree keeps what it did.")
        }
        if let patch = worktree.patch {
            var row: [String: JSONValue] = ["bytes": worktree.patchBytes.map { JSONValue.int(Int64($0)) } ?? .null]
            if let made = job.deliverables.last(where: { $0.path == patch }) {
                if let ref = made.ref { row["make_ref"] = .string(ref) }
                if let version = made.version { row["version"] = .int(Int64(version)) }
                if let refusal = made.refusal { row["not_registered"] = .string(refusal); row["path"] = .string(patch) }
            }
            fields["patch"] = .object(row)
        }
        if let applied = worktree.applied { fields["applied"] = .string(applied) }
        if worktree.discarded == true { fields["discarded"] = .bool(true) }
        let args: JSONValue = .object(["job": .string(job.id)])
        if job.state.isTerminal, worktree.discarded != true {
            if worktree.applied == nil, worktree.files?.isEmpty == false {
                fields["apply_with"] = .object(["action": .string("agent.apply"), "args": args])
            }
            fields["discard_with"] = .object(["action": .string("agent.discard"), "args": args])
        }
        return .object(fields)
    }

    // MARK: The agent's hands

    /// `agent.apply {job}`: the agent's merge of the job branch into its repository's current branch, with its own git. The stem first checks with reads only
    /// that the job ended and was captured, the branch still points at the commit the agent read, the agent's checkout has no uncommitted tracked changes, and
    /// the merge has no conflict. A conflict is reported with its files and the agent's repository is left exactly as it was.
    public static func apply(_ id: String, dataRoot: URL, git hands: AgentJobGit) async -> JSONValue {
        let store = AgentJobStore(dataRoot: dataRoot)
        let job: AgentJob
        do { job = try store.job(id) } catch { return refusedHands("unknown_job", "\(error.localizedDescription) Nothing was merged.", job: id) }
        guard let worktree = job.worktree, let place = job.place else {
            return refusedHands("not_a_repo_job", "\(id) did not work in a repository, so it has no branch to merge. Nothing was merged.", job: id)
        }
        guard job.state.isTerminal else {
            return refusedHands("still_working", "\(job.name) is still on \(id); wait for it to end, or stop it with agent.cancel. Nothing was merged.",
                                job: id)
        }
        guard worktree.discarded != true else { return refusedHands("discarded", "You discarded \(id); its branch is gone. Nothing was merged.", job: id) }
        guard let head = worktree.head, let files = worktree.files else {
            return refusedHands("not_captured", """
                Nothing was captured from \(id): it ended \(job.state.rawValue). Its worktree \(worktree.path) and branch \(worktree.branch) keep what it did; \
                agent.discard drops them. Nothing was merged.
                """, job: id)
        }
        guard !files.isEmpty else { return refusedHands("nothing_to_apply", "\(job.name) changed nothing in \(id). Nothing was merged.", job: id) }
        let repo = place.path
        func unread(_ what: String, _ result: BuilderWorktreeAllocator.GitResult) -> JSONValue {
            failedHands("\(what) could not be read: \(said(result)). Nothing was merged.", effects: "none", job: id)
        }
        let tip = await git(["rev-parse", "--verify", "--quiet", "refs/heads/\(worktree.branch)^{commit}"], repo)
        guard tip.status == 0 else {
            return refusedHands("branch_gone", "\(worktree.branch) is no longer in \(repo). Nothing was merged.", job: id)
        }
        guard tip.trimmed == head else {
            return refusedHands("branch_moved", """
                \(worktree.branch) now points at \(tip.trimmed), not \(head), the commit that was captured and that you read. Nothing was merged.
                """, job: id)
        }
        let current = await git(["symbolic-ref", "--quiet", "--short", "HEAD"], repo)
        guard current.status == 0 else {
            if current.status == 1 {
                return refusedHands("detached_head", "\(repo) is on no branch (detached HEAD); check out the branch to merge into. Nothing was merged.",
                                    job: id)
            }
            return unread("\(repo)'s current branch", current)
        }
        let dirty = await git(["status", "--porcelain", "--untracked-files=no"], repo)
        guard dirty.status == 0 else { return unread("\(repo)'s status", dirty) }
        guard dirty.trimmed.isEmpty else {
            return refusedHands("uncommitted_changes", """
                \(repo) has uncommitted changes to tracked files; commit or stash them first, so a merge that stops can leave it exactly as it was. \
                Nothing was merged.
                """, job: id, extra: ["changes": .string(String(dirty.trimmed.prefix(4000)))])
        }
        let before = await git(["rev-parse", "--verify", "HEAD^{commit}"], repo)
        guard before.status == 0 else { return unread("\(repo)'s HEAD", before) }
        let already = await git(["merge-base", "--is-ancestor", head, "HEAD"], repo)
        switch already.status {
        case 0:
            recordApplied(id, before.trimmed, store: store, dataRoot: dataRoot)
            return .object(["status": .string("already_applied"), "effects": .string("none"), "job": .string(id), "commit": .string(before.trimmed),
                            "detail": .string("\(current.trimmed) already holds \(worktree.branch). Nothing was merged again.")])
        case 1: break
        default: return unread("Whether \(current.trimmed) holds \(worktree.branch)", already)
        }
        // A trial merge in Git's object store answers "would it conflict" without touching the agent's branch, index or files.
        let trial = await git(["merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", head], repo, timeout: 120)
        switch trial.status {
        case 0: break
        case 1:
            let conflicts = trial.stdout.split(separator: "\n").dropFirst().map(String.init).filter { !$0.isEmpty }
            return conflict(id, worktree.branch, into: current.trimmed, conflicts, untouched: true)
        default: return unread("A trial merge of \(worktree.branch)", trial)
        }
        let ran: JSONValue
        do { ran = try await hands(["merge", "--no-ff", "--no-edit", worktree.branch], repo) }
        catch { ran = .object(["status": .string("failed"), "detail": .string(error.localizedDescription)]) }
        // Git says what happened; the tool's envelope says how the agent's call went.
        let after = await git(["merge-base", "--is-ancestor", head, "HEAD"], repo)
        if after.status == 0 {
            let merged = await git(["rev-parse", "--verify", "HEAD^{commit}"], repo)
            let commit = merged.status == 0 ? merged.trimmed : nil
            if let commit { recordApplied(id, commit, store: store, dataRoot: dataRoot) }
            return .object(["status": .string("applied"), "effects": .string("occurred"), "job": .string(id), "commit": commit.map(JSONValue.string) ?? .null,
                "branch": .string(worktree.branch), "into": .string(current.trimmed), "files": .int(Int64(files.count)), "git": ran,
                "detail": .string("Merged \(worktree.branch) into \(current.trimmed) with your git: \(files.count) file\(files.count == 1 ? "" : "s").")])
        }
        let midway = await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], repo)
        guard midway.status == 0 else {
            return .object(["status": .string("not_applied"), "effects": .string("none"), "job": .string(id), "git": ran,
                "detail": .string("Your git did not merge \(worktree.branch); its own result is under git. \(repo) was not changed.")])
        }
        // The merge stopped partway: the agent's own git takes it back to exactly where it was.
        let stopped = await git(["diff", "--name-only", "--diff-filter=U"], repo)
        let conflicts = stopped.status == 0 ? stopped.trimmed.split(separator: "\n").map(String.init) : []
        let undone: JSONValue
        do { undone = try await hands(["merge", "--abort"], repo) }
        catch { undone = .object(["status": .string("failed"), "detail": .string(error.localizedDescription)]) }
        let back = await git(["rev-parse", "--verify", "HEAD^{commit}"], repo)
        let clean = await git(["status", "--porcelain", "--untracked-files=no"], repo)
        let still = await git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], repo)
        let restored = still.status == 1 && back.status == 0 && back.trimmed == before.trimmed && clean.status == 0 && clean.trimmed.isEmpty
        guard restored else {
            return failedHands("""
                Merging \(worktree.branch) stopped partway and \(repo) could not be taken back by `git merge --abort`; it is mid-merge now. Run \
                git merge --abort in \(repo) before anything else there.
                """, effects: "occurred", job: id, extra: ["git": ran, "abort": undone])
        }
        return conflict(id, worktree.branch, into: current.trimmed, conflicts, untouched: false)
    }

    private static func conflict(_ id: String, _ branch: String, into: String, _ files: [String], untouched: Bool) -> JSONValue {
        let left = untouched ? "Your repository was not touched." : "The merge was taken back; your repository is exactly as it was."
        return .object(["status": .string("conflict"), "effects": .string("none"), "job": .string(id), "branch": .string(branch), "into": .string(into),
            "conflicts": .array(files.map(JSONValue.string)), "detail": .string("""
                Merging \(branch) into \(into) conflicts in \(files.count) file\(files.count == 1 ? "" : "s"): \(files.prefix(20).joined(separator: ", ")). \
                \(left) Nothing was merged.
                """)])
    }

    /// `agent.discard {job}`: drop the job's worktree, uncommitted work included, and delete its branch. The agent's repository's own branches and files stay
    /// as they are; a registered patch stays in Make.
    public static func discard(_ id: String, dataRoot: URL) async -> JSONValue {
        let store = AgentJobStore(dataRoot: dataRoot)
        let job: AgentJob
        do { job = try store.job(id) } catch { return refusedHands("unknown_job", "\(error.localizedDescription) Nothing was removed.", job: id) }
        guard let worktree = job.worktree, let place = job.place else {
            return refusedHands("not_a_repo_job", "\(id) did not work in a repository, so it has no worktree or branch. Nothing was removed.", job: id)
        }
        guard job.state.isTerminal else {
            return refusedHands("still_working", "\(job.name) is still working in \(worktree.path); stop it with agent.cancel first. Nothing was removed.",
                                job: id)
        }
        guard worktree.discarded != true else {
            return .object(["status": .string("already_discarded"), "effects": .string("none"), "job": .string(id),
                            "detail": .string("\(id) was already discarded. Nothing was removed.")])
        }
        switch await BuilderWorktreeAllocator.shared.discard(identity: id, repo: place.path, configRoot: worktreeConfigRoot(dataRoot)) {
        case .failed(let reason, let detail, let removed):
            let gone = removed ? "Its worktree \(worktree.path) was removed; its branch \(worktree.branch) stays." : "Nothing was removed."
            return failedHands("\(id) could not be discarded (\(reason)): \(detail) \(gone)", effects: removed ? "occurred" : "none", job: id)
        case .discarded(let removedWorktree, let deletedBranch, let note):
            do { try store.update(id) { $0.worktree?.discarded = true } }
            catch { owe(id, "record its discard", error, store: store, dataRoot: dataRoot) }
            let kept = job.deliverables.first { $0.path == worktree.patch }?.ref.map { " Its patch stays in Make as \($0)." } ?? ""
            let words = [removedWorktree ? "Removed its worktree \(worktree.path)." : "Its worktree was already gone.",
                         deletedBranch ? "Deleted its branch \(worktree.branch)." : "Its branch was already gone."].joined(separator: " ")
            return .object(["status": .string("discarded"), "effects": .string(removedWorktree || deletedBranch ? "occurred" : "none"), "job": .string(id),
                            "detail": .string(words + kept + (note.map { " " + $0 } ?? ""))])
        }
    }

    /// The agent's merge is a fact of the job's record; bookkeeping that fails is owed, never a reason to merge again.
    private static func recordApplied(_ id: String, _ commit: String, store: AgentJobStore, dataRoot: URL) {
        do { try store.update(id) { $0.worktree?.applied = commit } }
        catch { owe(id, "record its merge", error, store: store, dataRoot: dataRoot) }
    }

    private static func refusedHands(_ reason: String, _ detail: String, job: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["status": .string("refused"), "reason": .string(reason), "effects": .string("none"), "job": .string(job),
                               "argument_path": .string("job"), "detail": .string(detail)]) { _, own in own })
    }

    private static func failedHands(_ detail: String, effects: String, job: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["status": .string("failed"), "effects": .string(effects), "job": .string(job), "detail": .string(detail)]) { _, own in own })
    }
}
