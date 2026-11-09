import Foundation
import PersistenceCore
import os
// Blueprint: | `AgentJob.swift` | `AgentJob` record, `AgentJobStore` (agents/jobs.json), the `JobRunner` door contract, its refusing stub, `OwnLineRunner` |

/// A commission for another agent or the agent's own line, bounded by its envelope and settled with its deliverables and required check.
public struct AgentJob: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case working
        case needsYou = "needs_you"
        /// The check ran and passed.
        case done
        /// A deliverable came back with no check set.
        case delivered
        case failed
        case stopped

        public var isTerminal: Bool { ![.working, .needsYou].contains(self) }
    }

    /// The one folder the organ works in. A repo's folder becomes a worktree when the stem allocates one.
    public struct Place: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case folder, repo }
        public var kind: Kind
        public var path: String
    }

    /// What the organ may touch. Built by the stem from the commission and capped by the agent's Trust posture; the organ cannot widen it.
    public struct Envelope: Codable, Sendable, Equatable {
        public var writes: Bool
        public var network: Bool
        /// Writes land only here; absent means the job has no place and cannot write.
        public var folder: String?
    }

    /// The agent's prediction of what will be true when the job is done. Exactly one shape: a shell command (exit 0), a file that exists, or a grep that
    /// matches.
    public struct Done: Codable, Sendable, Equatable {
        public var command: String?
        public var file: String?
        public var grep: String?
        public var inFile: String?

        enum CodingKeys: String, CodingKey { case command, file, grep, inFile = "in" }
    }

    /// The stem's verdict on `done`. `unavailable` is no verdict: the check could not run, so the job is delivered, unchecked.
    public struct Check: Codable, Sendable, Equatable {
        public enum Verdict: String, Codable, Sendable { case passed, failed, unavailable }
        public var verdict: Verdict
        public var output: String
        /// Output read from the job's own folder carries the organ's words.
        public var fromJobFolder: Bool
        public var at: Date
    }

    /// One returned artifact: registered in Make as the agent's, or refused with the reason.
    public struct Deliverable: Codable, Sendable, Equatable {
        public var path: String
        public var ref: String?
        public var version: Int?
        public var refusal: String?
    }

    /// The organ's prose: its labelled report, kept as data. It never instructs the agent and never latches elevation.
    public struct Report: Codable, Sendable, Equatable {
        public var text: String
        public var truncated: Bool
        /// The model the organ said it used; it is the organ's, set in its own config by the person.
        public var model: String?
    }

    /// The context that commissioned the job, which its settle wakes.
    public struct Commission: Codable, Sendable, Equatable {
        public var session: String?
        public var surface: String
    }

    public var id: String
    public var lifeID: String?
    /// Contact id in agents/peers.json, whose job's `agent` is `peer:<contact>`; `self` for the agent's own line.
    public var contact: String
    public var name: String
    public var brief: String
/// The agent's own line's written self (a researcher, a critic): it stands in place of the agent's persona text. Nil is the agent itself.
    public var instructions: String?
    /// The peers steering the turn that started the agent's own line, and those the person elevated: the line carries their steering, so a peer's words never
    /// reach the agent's hands through a line of its own.
    public var peers: [String]?
    public var elevated: [String]?
    /// The file access of the turn that started the agent's own line: the line asks no wider. Nil: no turn narrowed it, so the agent's saved choice alone
    /// applies.
    public var fileAccess: String?
    public var place: Place?
    /// A repo job's own worktree and branch, cut before its door ran; the envelope's folder is its path.
    public var worktree: Worktree?
    public var envelope: Envelope
    public var done: Done?
    /// The Desk item this job carries, exactly as the agent bound it.
    public var desk: String?
    public var state: State
    /// The organ's own session handle (ACP session, Codex thread, Claude session, A2A task). Opaque to the stem.
    public var session: String?
    /// The organ's latest working line, its words.
    public var note: String?
    public var request: JobPermissionRequest?
    public var deliverables: [Deliverable]
    public var report: Report?
    public var check: Check?
    /// The stem's own sentence on how the job stands or ended.
    public var detail: String?
    public var commission: Commission
    /// Stopped by the agent through agent.cancel: the agent already knows, so its settle wakes nothing.
    public var stoppedByHer: Bool?
    /// A job of an earlier life of this data root, stopped until its door resumes it by session.
    public var restored: Bool?
    public var startedAt: Date
    public var updatedAt: Date
    public var endedAt: Date?

    /// The contact a line of the agent's own carries: the line is the agent.
    public static let own = "self"
    public var isOwn: Bool { contact == Self.own }
    public var agent: String { isOwn ? Self.own : "peer:" + contact }
    /// The record is kept per contact and kind of job.
    public var kind: String { place?.kind.rawValue ?? "none" }

    public static func isID(_ text: String) -> Bool {
        text.hasPrefix("job-") && UUID(uuidString: String(text.dropFirst(4))) != nil
    }
}

/// Organ permission requests go to the agent's broker, which answers against the job's envelope; anything outside it becomes a card for the person.
public struct JobPermissionRequest: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var subject: String?
    public init(id: String, title: String, subject: String? = nil) { self.id = id; self.title = title; self.subject = subject }
}

/// One file of agents/jobs.json under its lock. The agent's outbound conversations stay in conversations.json; a job is a commission with its own lifecycle
/// and settle.
public struct AgentJobStore: Sendable {
    public let fileURL: URL
    static let retained = 256

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init(dataRoot: URL) { fileURL = dataRoot.appendingPathComponent("agents/jobs.json") }

    public func jobs() throws -> [AgentJob] { try locked { try load() } }

    public func job(_ id: String) throws -> AgentJob {
        guard let job = try jobs().first(where: { $0.id == id }) else {
            throw Failure(message: "No job is called \(id). agent.contacts lists who you can give work to.")
        }
        return job
    }

    func insert(_ job: AgentJob) throws {
        try locked {
            var rows = try load()
            guard !rows.contains(where: { $0.id == job.id }) else { throw Failure(message: "Job \(job.id) already exists; nothing was started.") }
            rows.append(job)
            // Finished jobs make the record; keep the newest and let the oldest finished ones go.
            while rows.count > Self.retained, let oldest = rows.indices.filter({ rows[$0].state.isTerminal })
                .min(by: { rows[$0].updatedAt < rows[$1].updatedAt }) { rows.remove(at: oldest) }
            guard rows.count <= Self.retained else {
                throw Failure(message: "\(Self.retained) jobs are still running; stop or finish one before giving another. Nothing was started.")
            }
            try save(rows)
        }
    }

    /// The job's own commission, removed only when its door refused before anything ran.
    func withdraw(_ id: String) throws {
        try locked {
            var rows = try load()
            rows.removeAll { $0.id == id && $0.state == .working && $0.session == nil }
            try save(rows)
        }
    }

    @discardableResult
    func update(_ id: String, _ change: (inout AgentJob) throws -> Void) throws -> AgentJob {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }) else { throw Failure(message: "Job \(id) is no longer in \(fileURL.path).") }
            let before = rows[i]
            try change(&rows[i])
            guard rows[i] != before else { return rows[i] }
            rows[i].updatedAt = Date()
            if rows[i].state.isTerminal, rows[i].endedAt == nil { rows[i].endedAt = rows[i].updatedAt }
            try save(rows)
            return rows[i]
        }
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(fileURL, work)
    }

    /// Work of an earlier life of this data root reads stopped (restored) until its door resumes it.
    private func load() throws -> [AgentJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 16 * 1024 * 1024 else { throw Failure(message: "\(fileURL.path) is too large to read safely; it was left as it is.") }
        var rows = try JSONDecoder().decode([AgentJob].self, from: data)
        guard Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ AgentJob.isID($0.id) }) else {
            throw Failure(message: "\(fileURL.path) has a damaged job identity; it was left as it is. Repair it before giving another job.")
        }
        let life = try DataRootLife.current(in: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        for i in rows.indices where !rows[i].state.isTerminal && DataRootLife.life(of: rows[i].lifeID) != life {
            rows[i].state = .stopped
            rows[i].restored = true
            rows[i].detail = "Stopped (restored): this job ran in an earlier life of this data root. Its door can resume it by its session."
        }
        return rows
    }

    private func save(_ rows: [AgentJob]) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(rows), to: fileURL)
    }
}

// MARK: - The door contract

/// Everything the organ may know and touch for one job. The stem never passes a model: the organ's model is set in that agent's own config.
public struct JobStart: Sendable {
    public let job: String
    public let contact: AgentPeerContact
    public let brief: String
    /// The folder the organ works in: the job's place, or for a repo the worktree allocated for it, never the agent's checkout. Nil when the job has no place.
    public let folder: URL?
    public let envelope: AgentJob.Envelope
}

/// What one door reports, normalized from its own protocol (ACP updates, Codex app-server items, Claude stream-json, A2A task states).
public enum JobEvent: Sendable {
    /// The organ's session exists; the handle resumes or cancels it later.
    case started(session: String)
    case working(note: String)
    /// The organ asks for something; the door has routed it to the agent's broker, which answers within the envelope or files a card.
    case needsYou(JobPermissionRequest)
    case deliverable(JobDeliverable)
    /// Exactly one, last.
    case ended(JobOutcome)
}

public struct JobDeliverable: Sendable {
    /// Files the organ made, inside the job's folder.
    public let artifacts: [URL]
    public let report: String?
    public let model: String?
    public let inventoryFailure: String?
    public init(artifacts: [URL], report: String? = nil, model: String? = nil, inventoryFailure: String? = nil) {
        self.artifacts = artifacts; self.report = report; self.model = model; self.inventoryFailure = inventoryFailure
    }
}

public enum JobOutcome: Sendable, Equatable {
    /// The organ says it finished; the stem's check decides whether it is done.
    case finished
    case failed(String)
    case stopped(String)
}

/// The door refused before anything ran: no organ started, nothing was sent.
public struct JobRefusal: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One transport's way to give a whole agent a job. A door launches the organ in `folder` bounded by `envelope` (writes only in that folder when
/// `writes`, no network unless `network`), routes the organ's permission requests to the agent's broker, and reports through the stream. Cancelling the task
/// that consumes the stream ends the stream; a door stops its organ when its stream terminates.
public protocol JobRunner: Sendable {
    func serves(_ contact: AgentPeerContact) -> Bool
    /// Throws `JobRefusal` when nothing ran; any other error means the organ may have started.
    func start(_ job: JobStart) async throws -> AsyncThrowingStream<JobEvent, Error>
    /// Continue the organ's own session after a relaunch, from the handle its `.started` reported.
    func resume(_ job: JobStart, session: String) async throws -> AsyncThrowingStream<JobEvent, Error>
    /// Stop the organ's session on its own terms (ACP session/cancel, Codex turn/interrupt, A2A cancel, the run's process).
    func cancel(session: String) async throws
}

/// The door every contact has until a transport installs its own: it refuses plainly, so agent.job is honest before any door exists.
public struct RefusingJobRunner: JobRunner {
    public init() {}
    public func serves(_ contact: AgentPeerContact) -> Bool { true }
    public func start(_ job: JobStart) async throws -> AsyncThrowingStream<JobEvent, Error> { throw refusal(job.contact) }
    public func resume(_ job: JobStart, session: String) async throws -> AsyncThrowingStream<JobEvent, Error> { throw refusal(job.contact) }
    public func cancel(session: String) async throws {}
    private func refusal(_ contact: AgentPeerContact) -> JobRefusal {
        JobRefusal("No job door for \(contact.name) yet. Nothing was sent; agent.message still reaches it.")
    }
}

/// The agent's own line: a turn in its own work conversation, whose id is the job's, with the agent's written self when one was given. Its stream reports the
/// line as a door reports an organ; ending the stream stops the turn.
public protocol OwnLineRunner: Sendable {
    /// Throws `JobRefusal` when no turn started.
    func start(_ job: AgentJob) async throws -> AsyncThrowingStream<JobEvent, Error>
    /// Continue the line in its own conversation after a relaunch.
    func resume(_ job: AgentJob) async throws -> AsyncThrowingStream<JobEvent, Error>
}

/// Transports install their doors at launch; the first that serves a contact takes its jobs. The engine installs the agent's own line's runner.
public enum AgentJobDoors {
    private static let installed = OSAllocatedUnfairLock<[any JobRunner]>(initialState: [])
    private static let line = OSAllocatedUnfairLock<(any OwnLineRunner)?>(initialState: nil)

    public static func install(_ runner: any JobRunner) { installed.withLock { $0.append(runner) } }

    public static func install(own runner: any OwnLineRunner) { line.withLock { $0 = runner } }

    static func runner(for contact: AgentPeerContact) -> any JobRunner {
        installed.withLock { doors in doors.first { $0.serves(contact) } } ?? RefusingJobRunner()
    }

    static func own() throws -> any OwnLineRunner {
        guard let runner = line.withLock({ $0 }) else { throw JobRefusal("Your own lines are not open in this app yet. Nothing was started.") }
        return runner
    }
}
