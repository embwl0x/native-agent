import ApprovalInbox
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `JobDoor.swift` | `JobDoors.install`; what every job door shares: its outlet and beat, the envelope broker, what the organ made, its live runs |

/// The doors through which another whole agent takes a job, one per native protocol, each using the agent's own approved program or card. Installed at
/// launch, before a relaunch resumes any job. Every door bounds its organ by the job's envelope alone: the Mac's posture never widens it.
public enum JobDoors {
    public static func install(dataRoot: URL) {
        AgentJobDoors.install(CodexJobDoor(dataRoot: dataRoot))
        AgentJobDoors.install(ClaudeCodeJobDoor(dataRoot: dataRoot))
        AgentJobDoors.install(ACPJobDoor(dataRoot: dataRoot))
        AgentJobDoors.install(A2AJobDoor(dataRoot: dataRoot))
    }

    /// The job as the stem kept it: when it started (what the organ made is what changed since) and who commissioned it (where a card stands).
    struct Record: Sendable {
        let startedAt: Date
        let commission: AgentJob.Commission

        static func read(_ job: JobStart, dataRoot: URL) throws -> Record {
            do {
                let kept = try AgentJobStore(dataRoot: dataRoot).job(job.job)
                return Record(startedAt: kept.startedAt, commission: kept.commission)
            } catch { throw JobRefusal("Job \(job.job) could not be read before its door opened: \(error.localizedDescription). Nothing ran.") }
        }
    }

    /// A command-line organ works in the job's folder; a job with no place works in its contact's own folder, where it may not write.
    static func folder(_ job: JobStart, host: String, dataRoot: URL) throws -> URL {
        if let folder = job.folder { return folder }
        let own = job.contact.hostWorkspace.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentHostConnection.builderWorkspaceRoot(dataRoot: dataRoot).appendingPathComponent("agent-bridge-runs/" + host, isDirectory: true)
        do { try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw JobRefusal("\(job.contact.name)'s own folder \(own.path) could not be made: \(error.localizedDescription). Nothing ran.") }
        return own
    }

    /// What a door says to an organ whose run this app lost when it restarted; the organ continues its own session from there.
    static func resumed(_ brief: String) -> String {
        """
        The app that gave you this job restarted before you finished, so this run ended early. Pick the job up where you left off in this same \
        session and finish it. The job, as it was given:

        \(brief)
        """
    }

    /// The contact's own recipe: its host row, as the person may have edited it in agents/recipes.
    static func recipe(_ contact: AgentPeerContact) throws -> (host: String, row: AgentHostRow) {
        guard let host = AgentPeerStore.hostRowID(contact.endpoint), let recipe = AgentRecipeStore.recipe(host) else {
            throw JobRefusal("\(contact.name) has no host recipe in agents/recipes; read it with agent.recipe. Nothing ran.")
        }
        return (host, recipe.host)
    }

    /// Which native door a command-line host speaks, as its recipe declares it.
    static func flags(_ contact: AgentPeerContact) -> AgentHostCommandLine.PermissionFlags? {
        AgentPeerStore.hostRowID(contact.endpoint).flatMap(AgentRecipeStore.recipe)?.host.commandLine?.permissionFlags
    }

    /// The approved program bound to this contact at connection, or why there is none.
    static func approved(_ contact: AgentPeerContact) throws -> AgentACPExecutable {
        guard let approved = contact.approvedACPExecutable else {
            throw JobRefusal("\(contact.name) has no approved program bound to it. Reconnect it (agent.connect) to approve its program. Nothing ran.")
        }
        return approved
    }
}

/// A door's own failure after its organ may have started, in words the job keeps.
struct JobDoorFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One run's outlet: ordered events and exactly one terminal result on the stream and nerve spine.
final class JobDoorOut: Sendable {
    private let continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    let organ: String
    private let ended = OSAllocatedUnfairLock(initialState: false)

    init(_ continuation: AsyncThrowingStream<JobEvent, Error>.Continuation, contact: AgentPeerContact) {
        self.continuation = continuation
        organ = "agent:" + contact.name.lowercased()
    }

    func send(_ event: JobEvent) {
        let ending: Bool = if case .ended = event { true } else { false }
        guard ended.withLock({ ended -> Bool in
            guard !ended else { return false }
            if ending { ended = true }
            return true
        }) else { return }
        switch event {
        case .working(let note): OrganPulse.record(organ, .worked, note: String(note.prefix(200)))
        case .ended(.finished): OrganPulse.record(organ, .worked, note: "finished its job")
        case .ended(.failed(let why)): OrganPulse.record(organ, .failed, note: String(why.prefix(300)))
        case .ended(.stopped(let why)): OrganPulse.record(organ, .stopped, note: String(why.prefix(300)))
        case .started, .needsYou, .deliverable: break
        }
        continuation.yield(event)
        if ending { continuation.finish() }
    }

    func fail(_ failure: JobDoorFailure) {
        guard ended.withLock({ ended -> Bool in
            guard !ended else { return false }
            ended = true
            return true
        }) else { return }
        OrganPulse.record(organ, .failed, note: String(failure.message.prefix(300)))
        continuation.finish(throwing: failure)
    }

    /// The agent's stop ends the stream before the run does, so its beat is recorded here and nothing more is sent.
    func stopped(_ why: String) {
        guard ended.withLock({ ended -> Bool in
            defer { ended = true }
            return !ended
        }) else { return }
        OrganPulse.record(organ, .stopped, note: why)
    }

}

/// One organ's run in this app: the task that drives it, which the agent's stop reaches by the organ's session.
final class JobDoorRun: Sendable {
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    func drive(_ body: @escaping @Sendable () async -> Void) {
        task.withLock { $0 = Task.detached(priority: .utility) { await body() } }
    }

    func cancel() { task.withLock { $0 }?.cancel() }

    /// Returns once the run has told its organ to stop and closed it.
    func stop() async {
        let running = task.withLock { $0 }
        running?.cancel()
        await running?.value
    }
}

/// The live runs of every door in this app, keyed by door and the organ's session.
actor JobDoorLive {
    static let shared = JobDoorLive()
    private var runs: [String: JobDoorRun] = [:]

    func hold(_ key: String, _ run: JobDoorRun) { runs[key] = run }

    func release(_ key: String, _ run: JobDoorRun) { if runs[key] === run { runs.removeValue(forKey: key) } }

    /// A session with no live run here already stopped: its stream ending is what ends a run.
    func stop(_ key: String) async { await runs[key]?.stop() }
}

/// What an organ asks to do, as its door reads its protocol: the one shape the broker answers.
struct JobAsk: Sendable {
    enum Kind: String, Sendable { case read, write, network, other }
    let kind: Kind
    /// The files a write touches, absolute or relative to the organ's folder; a write naming none is outside the envelope.
    let paths: [String]
    /// The organ's words for it, shown on the card.
    let title: String
    let request: JSONValue
}

/// The agent's one permission brain for organs: a request inside the job's envelope is answered at once; anything outside it becomes a card for the person,
/// whatever the contact's trust or the Mac's posture.
enum JobDoorBroker {
    static func within(_ ask: JobAsk, _ envelope: AgentJob.Envelope, cwd: URL) -> Bool {
        switch ask.kind {
        case .read: return true
        case .network: return envelope.network
        case .other: return false
        case .write:
            guard envelope.writes, let folder = envelope.folder, !ask.paths.isEmpty else { return false }
            return ask.paths.allSatisfy { inside($0, folder: folder, cwd: cwd) }
        }
    }

    /// Inside the folder after symlinks: a link inside the folder that leads out is outside. A repo's `.git` is not the job's to write: its hooks and
    /// config would run in the agent's hands later.
    static func inside(_ path: String, folder: String, cwd: URL) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : cwd.appendingPathComponent(expanded)).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        let resolved = tail.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
        guard resolved == folder || resolved.hasPrefix(folder + "/") else { return false }
        return resolved != folder + "/.git" && !resolved.hasPrefix(folder + "/.git/")
    }

    /// The organ waits while the person decides; the job reads needs_you until then. A card that cannot be filed declines the request and says why.
    static func answer(_ ask: JobAsk, job: JobStart, record: JobDoors.Record, cwd: URL, out: JobDoorOut, dataRoot: URL) async -> Bool {
        if within(ask, job.envelope, cwd: cwd) { return true }
        out.send(.needsYou(JobPermissionRequest(id: "ask-" + UUID().uuidString.lowercased(), title: String(ask.title.prefix(300)),
                                                subject: ask.paths.first)))
        let allowed: Bool
        do {
            allowed = try await AgentACPApproval.job(ask.request, asking: String(ask.title.prefix(300)), peer: job.contact, job: job.job,
                                                     commission: record.commission, inbox: SwiftNativeApprovalInbox(root: dataRoot))
        } catch {
            guard !Task.isCancelled else { return false }
            out.fail(JobDoorFailure("Its permission card could not be filed: \(error.localizedDescription)."))
            return false
        }
        out.send(.working(note: (allowed ? "You allowed, once: " : "You declined: ") + String(ask.title.prefix(200))))
        return allowed
    }
}

/// What the organ made: the files it changed in the job's folder since the job started.
enum JobDoorArtifacts {
    static let limit = 256
    static let walkLimit = 200_000

    struct Found: Sendable {
        let files: [URL]
        /// Why the list may be short, in the door's words; nil when it is whole.
        let gap: String?
    }

    /// In a repo, what git counts as changed or new and was written since the start (ignored files are not work); elsewhere every regular file written
    /// since. Newest first, at most `limit`.
    static func changed(in folder: URL, since: Date) async throws -> Found {
        let candidates: [URL]
        var gaps: [String] = []
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            let ran = try await ProcessExecution().run(executable: "/usr/bin/git",
                arguments: ["-C", folder.path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"],
                currentDirectory: folder, environment: nil, standardInput: nil, timeoutSeconds: nil, outputByteLimit: 8 * 1_048_576)
            guard ran.exitCode == 0, !ran.timedOut, !ran.stdoutTruncated else {
                throw JobDoorFailure("git status in \(folder.path) did not answer (exit \(ran.exitCode)): \(ran.stderr.prefix(300))")
            }
            candidates = ran.stdout.split(separator: "\0").compactMap { entry in
                guard entry.count > 3 else { gaps.append("git status returned an incomplete entry"); return nil }
                // A deleted path is work, but only a file that remains (including either side of a delete conflict) is inventoried.
                let url = folder.appendingPathComponent(String(entry.dropFirst(3)))
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } else {
            let walked = try walk(folder)
            candidates = walked.found
            gaps += walked.gaps
        }
        var dated: [(URL, Date)] = []
        for url in candidates {
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]) }
            catch { gaps.append("\(url.path): \(error.localizedDescription)"); continue }
            guard let regular = values.isRegularFile else { gaps.append("\(url.path): file kind is unavailable"); continue }
            guard regular else { continue }
            guard let modified = values.contentModificationDate else {
                gaps.append("\(url.path): modification date is unavailable")
                continue
            }
            guard modified >= since else { continue }
            dated.append((url, modified))
        }
        dated.sort { $0.1 > $1.1 }
        if dated.count > limit { gaps.append("\(dated.count) files changed; the \(limit) newest came back") }
        return Found(files: dated.prefix(limit).map(\.0), gap: gaps.isEmpty ? nil : gaps.joined(separator: "; "))
    }

    /// Every entry under a folder that is not a repo, past nothing but `.git`. Synchronous: the directory enumerator is not for async contexts.
    static func walk(_ folder: URL) throws -> (found: [URL], gaps: [String]) {
        let unreadable = OSAllocatedUnfairLock<[String]>(initialState: [])
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [], errorHandler: { url, error in
                unreadable.withLock { $0.append("\(url.path): \(error.localizedDescription)") }
                return true
            }) else {
            throw JobDoorFailure("\(folder.path) could not be read")
        }
        var seen = 0, found: [URL] = [], gaps: [String] = []
        for case let url as URL in walk {
            seen += 1
            if seen > walkLimit { gaps.append("only the first \(walkLimit) entries of the folder were looked at"); break }
            if url.lastPathComponent == ".git" { walk.skipDescendants(); continue }
            found.append(url)
        }
        gaps += unreadable.withLock { $0 }
        return (found, gaps)
    }

    /// Named inventory failures travel beside successfully read files; they prevent successful settlement.
    static func deliverable(_ job: JobStart, since: Date, report: String?, model: String?) async throws -> JobDeliverable {
        guard let folder = job.folder else { return JobDeliverable(artifacts: [], report: report, model: model) }
        let found = try await changed(in: folder, since: since)
        let failure = found.gap.map { "Artifact inventory in \(folder.path) is incomplete: \($0)." }
        return JobDeliverable(artifacts: found.files, report: report, model: model, inventoryFailure: failure)
    }
}
