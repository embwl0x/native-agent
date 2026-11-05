import AgentWorkspace
import Experiences
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `AgentJobStem.swift` | `AgentJobs`: commission, read, stop, the done-check, deliverable registration and the settle into the agent's own context |

/// What the stem attests when it registers an organ's artifact as the agent's.
public struct AgentJobProvenance: Sendable {
    public let contact: String
    public let job: String
    public let brief: String
    /// "made by ‹contact› for ‹job›"
    public var madeBy: String { "made by \(contact) for \(job)" }
}

/// Registers one file the stem checked as the job's own output; the registrar owns where the agent's made things live.
public typealias AgentJobRegistrar = @Sendable (_ file: URL, _ provenance: AgentJobProvenance) throws -> (ref: String, version: Int)

/// The stem of every job: the agent's commission, the organ's events, the check of `done`, and the settle. The deliverable returns as the result of the
/// agent's own call; it never wakes a turn in the contact's thread or on the agent-bridge surface.
public enum AgentJobs {
    static let briefLimit = 32_000
    static let reportLimit = 16_000
    static let checkSeconds: TimeInterval = 600

    // MARK: Commission

    /// `agent.job {agent, brief, where?, reach?, done?, desk?, instructions?}`: the contact is `agent`, as on every other agent action; `self` is the agent's
    /// own line. `ceiling` is the agent's Trust posture for driving another agent, read at the door; `limits` are the commissioning turn's peer steering and
    /// file access.
    public static func commission(_ input: [String: JSONValue], session: String?, surface: String, ceiling: DrivenAgentLaunchPermission,
                                  limits: (peers: [String], elevated: [String], fileAccess: String?), dataRoot: URL,
                                  register: @escaping AgentJobRegistrar) async -> JSONValue {
        let to = (input["agent"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = (input["brief"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return refused("invalid_args", "Pass agent: the contact who takes the job. Nothing was sent.", path: "agent") }
        guard !brief.isEmpty, brief.count <= briefLimit else {
            return refused("invalid_args", "Pass brief: the job in your words, at most \(briefLimit) characters. Nothing was sent.", path: "brief")
        }
        if to.lowercased() == AgentJob.own {
            return await line(input, brief: brief, session: session, surface: surface, limits: limits, dataRoot: dataRoot, register: register)
        }
        guard input["instructions"] == nil else {
            return refused("invalid_args", "instructions write who your own line is; another agent brings its own. Nothing was sent.", path: "instructions")
        }
        let peers: [AgentPeerContact]
        do { peers = try AgentPeerStore(dataRoot: dataRoot).list() }
        catch { return failed("Your contacts could not be read: \(error.localizedDescription). Nothing was sent.", effects: "none") }
        let named = contacts(to, in: peers)
        guard named.count == 1, let peer = named.first else {
            let who = named.isEmpty ? "No contact is called \(to)." : "More than one contact answers to \(to)."
            let all = peers.map { "\($0.name) (peer:\($0.id))" }.joined(separator: ", ")
            return refused(named.isEmpty ? "unknown_contact" : "ambiguous_contact", who + " Your contacts: " + all + ". Nothing was sent.", path: "agent")
        }
        let place: AgentJob.Place?
        switch self.place(input["where"], dataRoot: dataRoot) {
        case .success(let found): place = found
        case .failure(let refusal): return refused("invalid_where", refusal.message, path: "where")
        }
        var envelope: AgentJob.Envelope
        switch self.envelope(input["reach"], place: place, ceiling: ceiling) {
        case .success(let found): envelope = found
        case .failure(let refusal): return refused("outside_posture", refusal.message, path: "reach")
        }
        let done: AgentJob.Done?
        switch self.done(input["done"], place: place) {
        case .success(let found): done = found
        case .failure(let refusal): return refused("invalid_done", refusal.message, path: "done")
        }
        let desk = input["desk"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) }
        catch { return failed("This data root's life could not be read: \(error.localizedDescription). Nothing was sent.", effects: "none") }
        let id = "job-" + UUID().uuidString.lowercased()
        // A repo job works in its own worktree on its own branch; the organ's folder is that worktree, never the agent's checkout.
        var worktree: AgentJob.Worktree?
        if let place, place.kind == .repo {
            switch await cut(id, repo: place.path, dataRoot: dataRoot) {
            case .success(let made): worktree = made; envelope.folder = made.path
            case .failure(let refusal): return refused("no_worktree", refusal.message, path: "where")
            }
        }
        let now = Date()
        let job = AgentJob(id: id, lifeID: life, contact: peer.id, name: peer.name, brief: brief, place: place, worktree: worktree,
            envelope: envelope, done: done, desk: desk?.isEmpty == false ? desk : nil, state: .working, deliverables: [],
            commission: .init(session: session, surface: surface), startedAt: now, updatedAt: now)
        let store = AgentJobStore(dataRoot: dataRoot)
        // The commission is kept before the door runs, so an organ never works with no record of it.
        do { try store.insert(job) }
        catch {
            var words = "The job could not be kept: \(error.localizedDescription). Nothing was sent."
            if worktree != nil, let place {
                let left = await uncut(id, repo: place.path, dataRoot: dataRoot)
                words += " " + left
            }
            return failed(words, effects: "none")
        }
        let runner = AgentJobDoors.runner(for: peer)
        let events: AsyncThrowingStream<JobEvent, Error>
        do { events = try await runner.start(start(job, peer: peer)) }
        catch let refusal as JobRefusal {
            do { try store.withdraw(job.id) }
            catch { nativeLog("Job %@ refused by its door; its commission could not be withdrawn: %@", job.id, error.localizedDescription) }
            var words = refusal.message
            if worktree != nil, let place {
                let left = await uncut(id, repo: place.path, dataRoot: dataRoot)
                words += " " + left
            }
            return .object(["status": .string("refused"), "reason": .string("no_job_door"), "effects": .string("none"), "sent": .bool(false),
                "agent": .string(job.agent), "name": .string(peer.name), "detail": .string(words)])
        } catch {
            let words = "\(peer.name)'s job door failed while starting: \(error.localizedDescription). The organ may have started; nothing was resent."
            do { try store.update(job.id) { $0.state = .failed; $0.detail = words } }
            catch { owe(job.id, "record a failed start", error, store: store, dataRoot: dataRoot) }
            return failed(words, effects: "unknown", job: job.id)
        }
        await AgentJobFlights.shared.fly(job.id, runner: runner) {
            await consume(job.id, events, dataRoot: dataRoot, register: register)
        }
        var receipt = view(job, jobs: Result { try store.jobs() }, dataRoot: dataRoot)
        receipt["status"] = .string("accepted")
        receipt["sent"] = .bool(true)
        receipt["completed"] = .bool(false)
        receipt["detail"] = .string("""
            \(peer.name) took the job. What it makes comes back to you as yours, checked by done, and wakes you in this conversation when it ends.
            """)
        return .object(receipt)
    }

    /// The agent's own line: a turn in its own work conversation under the agent's own Trust, so where and reach (which bound another agent) do not apply. A
    /// done check of a file or grep still judges what the line made.
    static func line(_ input: [String: JSONValue], brief: String, session: String?, surface: String,
                     limits: (peers: [String], elevated: [String], fileAccess: String?), dataRoot: URL,
                     register: @escaping AgentJobRegistrar) async -> JSONValue {
        for key in ["where", "reach"] where input[key] != nil && input[key] != .null {
            return refused("invalid_args", "Your own line works with your own hands under your Trust; \(key) bounds another agent. Nothing was started.",
                path: key)
        }
        let instructions: String?
        switch input["instructions"] {
        case nil, .null?: instructions = nil
        case .string(let text)?:
            let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !written.isEmpty, written.count <= briefLimit else {
                return refused("invalid_args", "instructions are who this line is, in your words, at most \(briefLimit) characters. Nothing was started.",
                    path: "instructions")
            }
            instructions = written
        default:
            return refused("invalid_args", "instructions are text: who this line is. Nothing was started.", path: "instructions")
        }
        if input["done"]?.objectValue?["command"] != nil {
            return refused("invalid_done",
                "A command check runs in another agent's folder; check your own line with {file} or {grep, in}. Nothing was started.", path: "done")
        }
        let done: AgentJob.Done?
        switch self.done(input["done"], place: nil) {
        case .success(let found): done = found
        case .failure(let refusal): return refused("invalid_done", refusal.message, path: "done")
        }
        let runner: any OwnLineRunner
        do { runner = try AgentJobDoors.own() }
        catch { return refused("no_line", error.localizedDescription, path: "agent") }
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) }
        catch { return failed("This data root's life could not be read: \(error.localizedDescription). Nothing was started.", effects: "none") }
        let desk = input["desk"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let job = AgentJob(id: "job-" + UUID().uuidString.lowercased(), lifeID: life, contact: AgentJob.own, name: "your line", brief: brief,
            instructions: instructions, peers: limits.peers.isEmpty ? nil : limits.peers,
            elevated: limits.elevated.isEmpty ? nil : limits.elevated, fileAccess: limits.fileAccess,
            place: nil, worktree: nil, envelope: .init(writes: false, network: false, folder: nil), done: done,
            desk: desk?.isEmpty == false ? desk : nil, state: .working, deliverables: [], commission: .init(session: session, surface: surface),
            startedAt: now, updatedAt: now)
        let store = AgentJobStore(dataRoot: dataRoot)
        do { try store.insert(job) }
        catch { return failed("The line could not be kept: \(error.localizedDescription). Nothing was started.", effects: "none") }
        let events: AsyncThrowingStream<JobEvent, Error>
        do { events = try await runner.start(job) }
        catch {
            do { try store.withdraw(job.id) }
            catch { nativeLog("Line %@ did not start; its record could not be withdrawn: %@", job.id, error.localizedDescription) }
            return .object(["status": .string("refused"), "reason": .string("no_line"), "effects": .string("none"), "sent": .bool(false),
                "agent": .string(job.agent), "detail": .string(error.localizedDescription)])
        }
        await AgentJobFlights.shared.fly(job.id, runner: nil) {
            await consume(job.id, events, dataRoot: dataRoot, register: register)
        }
        var receipt = view(job, jobs: Result { try store.jobs() }, dataRoot: dataRoot)
        receipt["status"] = .string("accepted")
        receipt["sent"] = .bool(true)
        receipt["completed"] = .bool(false)
        receipt["detail"] = .string("""
            Your line took it in its own work conversation \(job.id)\(instructions == nil ? "" : ", as the one your instructions write"). Its answer \
            comes back to you as yours and wakes you in this conversation when it ends.
            """)
        return .object(receipt)
    }

    /// The agent's weekly look back: per contact (the agent's own lines as self), how the jobs that ended this week and last week ended. Empty when none ended.
    public static func weeklyOutcomes(dataRoot: URL, now: Date) throws -> String {
        let week: TimeInterval = 7 * 86_400
        var counts: [String: (this: [AgentJob.State: Int], last: [AgentJob.State: Int])] = [:]
        for job in try AgentJobStore(dataRoot: dataRoot).jobs() {
            guard let ended = job.endedAt, ended <= now, now.timeIntervalSince(ended) < 2 * week else { continue }
            let who = job.isOwn ? "your lines" : job.name
            var row = counts[who] ?? ([:], [:])
            if now.timeIntervalSince(ended) < week { row.this[job.state, default: 0] += 1 } else { row.last[job.state, default: 0] += 1 }
            counts[who] = row
        }
        guard !counts.isEmpty else { return "" }
        let states: [AgentJob.State] = [.done, .delivered, .failed, .stopped]
        return "## Jobs that ended (this week, last week in brackets)\n" + counts.keys.sorted().map { who in
            let row = counts[who]!
            return "- \(who): " + states.map { "\($0.rawValue) \(row.this[$0] ?? 0) (\(row.last[$0] ?? 0))" }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    /// Home's WORKING block and crews room read the agent's jobs through their store, newest first.
    public static func installGlance() {
        AgentScreen.jobGlances.withLock { $0 = { root in
            try AgentJobStore(dataRoot: root).jobs().sorted { $0.startedAt > $1.startedAt }.map { job in
                AgentScreen.JobGlance(id: job.id, agent: job.agent, name: job.name, own: job.isOwn, state: job.state.rawValue,
                    working: !job.state.isTerminal, brief: job.brief, desk: job.desk, at: job.startedAt)
            }
        } }
        NotificationCenter.default.post(name: HomeFace.jobsChanged, object: nil)
    }

    /// A contact by `peer:<id>`, id, name or handle.
    static func contacts(_ name: String, in peers: [AgentPeerContact]) -> [AgentPeerContact] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return peers.filter { "peer:" + $0.id == key || $0.id == key || $0.name.lowercased() == key
            || ($0.handles ?? []).contains { $0.lowercased() == key } }
    }

    /// Called once per launch, before any job of this app is live. A job a relaunch left working continues through its door by the organ's own
    /// session, or ends stopped and wakes the context that commissioned it, so no job waits on a flight that no longer exists. A job of an earlier
    /// life is already stopped (restored) and stays so: a restore brings back what the agent had, never what it was doing.
    public static func resume(dataRoot: URL, register: @escaping AgentJobRegistrar) async {
        let store = AgentJobStore(dataRoot: dataRoot)
        let jobs: [AgentJob], peers: [AgentPeerContact]
        do {
            jobs = try store.jobs()
            peers = try AgentPeerStore(dataRoot: dataRoot).list()
        } catch {
            return owe("jobs", "be read at launch", error, store: store, dataRoot: dataRoot)
        }
        for job in jobs where !job.state.isTerminal {
            var why = "the app closed before the job ended and it had no session to pick back up"
            if job.isOwn {
                // The agent's line continues in its own conversation.
                do {
                    let events = try await AgentJobDoors.own().resume(job)
                    keep(job.id, store: store, dataRoot: dataRoot) { $0.detail = "Continued in its own conversation after the app restarted." }
                    await AgentJobFlights.shared.fly(job.id, runner: nil) {
                        await consume(job.id, events, dataRoot: dataRoot, register: register)
                    }
                    continue
                } catch {
                    why = "the app closed before your line ended and it could not continue: " + error.localizedDescription
                }
            } else if let session = job.session {
                if let peer = peers.first(where: { $0.id == job.contact }) {
                    let runner = AgentJobDoors.runner(for: peer)
                    do {
                        let events = try await runner.resume(start(job, peer: peer), session: session)
                        keep(job.id, store: store, dataRoot: dataRoot) { $0.detail = "Resumed by its session after the app restarted." }
                        await AgentJobFlights.shared.fly(job.id, runner: runner) {
                            await consume(job.id, events, dataRoot: dataRoot, register: register)
                        }
                        continue
                    } catch let refusal as JobRefusal {
                        why = "the app closed before the job ended and its door could not resume the session: " + refusal.message
                    } catch {
                        why = "the app closed before the job ended and resuming its session failed: " + error.localizedDescription
                    }
                } else {
                    why = "the app closed before the job ended and its contact is no longer in your contacts"
                }
            }
            await settle(job.id, .stopped(why), store: store, dataRoot: dataRoot, register: register)
        }
    }

    static func start(_ job: AgentJob, peer: AgentPeerContact) -> JobStart {
        JobStart(job: job.id, contact: peer, brief: job.brief, folder: job.envelope.folder.map { URL(fileURLWithPath: $0, isDirectory: true) },
                 envelope: job.envelope)
    }

    /// A folder or a repo's folder, never inside the agent's own data root.
    static func place(_ value: JSONValue?, dataRoot: URL) -> Result<AgentJob.Place?, JobRefusal> {
        guard let value, value != .null else { return .success(nil) }
        guard let raw = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(JobRefusal("where must be a folder's path. Nothing was sent."))
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(JobRefusal("where must be an absolute path or start with ~. Nothing was sent.")) }
        let folder = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(JobRefusal("\(folder.path) is not a folder on this Mac. Nothing was sent."))
        }
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard folder.path != root, !folder.path.hasPrefix(root + "/"), !root.hasPrefix(folder.path + "/") else {
            return .failure(JobRefusal("\(folder.path) holds your own data; another agent never works there. Nothing was sent."))
        }
        let repo = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
        return .success(.init(kind: repo ? .repo : .folder, path: folder.path))
    }

    /// Writes default to the job's one folder; network defaults off. The agent's posture is the ceiling: below Full Mac the organ has no network.
    static func envelope(_ value: JSONValue?, place: AgentJob.Place?, ceiling: DrivenAgentLaunchPermission) -> Result<AgentJob.Envelope, JobRefusal> {
        if case .denied(let reason) = ceiling { return .failure(JobRefusal("Driving another agent is not allowed now: \(reason). Nothing was sent.")) }
        let fields = value?.objectValue ?? [:]
        guard value == nil || value == .null || value?.objectValue != nil,
              fields.keys.allSatisfy({ ["writes", "network"].contains($0) }),
              fields.values.allSatisfy({ $0.boolValue != nil }) else {
            return .failure(JobRefusal("reach takes {writes: true|false, network: true|false}. Nothing was sent."))
        }
        let writes = fields["writes"]?.boolValue ?? (place != nil)
        let network = fields["network"]?.boolValue ?? false
        if writes, place == nil { return .failure(JobRefusal("writes:true needs where: the one folder it may write in. Nothing was sent.")) }
        if network, ceiling != .fullMac {
            return .failure(JobRefusal("network:true needs Full Mac; below it a job has no network. Nothing was sent."))
        }
        return .success(.init(writes: writes, network: network, folder: place?.path))
    }

    static func done(_ value: JSONValue?, place: AgentJob.Place?) -> Result<AgentJob.Done?, JobRefusal> {
        guard let value, value != .null else { return .success(nil) }
        let shapes = "done takes one of {command:\"<shell, run in where>\"}, {file:\"<path>\"} or {grep:\"<regex>\", in:\"<path>\"}. Nothing was sent."
        guard let fields = value.objectValue, fields.keys.allSatisfy({ ["command", "file", "grep", "in"].contains($0) }),
              fields.values.allSatisfy({ !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .failure(JobRefusal(shapes))
        }
        let done = AgentJob.Done(command: fields["command"]?.stringValue, file: fields["file"]?.stringValue,
                                 grep: fields["grep"]?.stringValue, inFile: fields["in"]?.stringValue)
        let forms = [done.command != nil, done.file != nil, done.grep != nil].filter { $0 }.count
        guard forms == 1, (done.grep == nil) == (done.inFile == nil) else { return .failure(JobRefusal(shapes)) }
        if done.command != nil, place == nil { return .failure(JobRefusal("A command check runs in where; pass where. Nothing was sent.")) }
        for path in [done.file, done.inFile].compactMap({ $0 }) where !path.hasPrefix("/") && !path.hasPrefix("~") && place == nil {
            return .failure(JobRefusal("\(path) is relative; pass where, or an absolute path. Nothing was sent."))
        }
        if let pattern = done.grep {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { return .failure(JobRefusal("grep is not a regular expression: \(error.localizedDescription). Nothing was sent.")) }
        }
        return .success(done)
    }

    // MARK: Read and stop

    /// `agent.read` and `agent.cancel` name a job by its id in `job`, as agent.apply and agent.discard do.
    package static func answer(tool: String, id: String, agent: String?, dataRoot: URL) async throws -> JSONValue {
        let store = AgentJobStore(dataRoot: dataRoot)
        let jobs = try store.jobs()
        guard let job = jobs.first(where: { $0.id == id }) else {
            throw ToolFailureError("No job is called \(id). Nothing was \(tool == "agent_cancel" ? "stopped" : "read").", effects: .none)
        }
        if let agent {
            let peers = try job.isOwn ? [] : AgentPeerStore(dataRoot: dataRoot).list()
            let own = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == AgentJob.own
            let named = own ? [AgentJob.own] : contacts(agent, in: peers).map(\.id)
            guard named == [job.contact] else {
                throw ToolFailureError("\(id) was given to \(job.name) (\(job.agent)), not \(agent). Nothing was "
                    + (tool == "agent_cancel" ? "stopped." : "read."), effects: .none)
            }
        }
        guard tool == "agent_cancel" else {
            var fields = view(job, jobs: .success(jobs), dataRoot: dataRoot)
            fields["status"] = .string("read")
            return .object(fields)
        }
        return .object(try await stop(job, store: store, dataRoot: dataRoot))
    }

    static func stop(_ job: AgentJob, store: AgentJobStore, dataRoot: URL) async throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["job": .string(job.id), "agent": .string(job.agent), "name": .string(job.name)]
        guard !job.state.isTerminal else {
            fields["status"] = .string("already_" + job.state.rawValue); fields["stopped"] = .bool(false); fields["effects"] = .string("none")
            fields["detail"] = .string("This job already ended: \(job.state.rawValue). Nothing was stopped.")
            return fields
        }
        // Mark it the agent's first, so the organ's late events settle nothing and wake nothing.
        let stopped = try store.update(job.id) {
            guard !$0.state.isTerminal else { return }
            $0.state = .stopped; $0.stoppedByHer = true; $0.request = nil; $0.detail = "You stopped it."
        }
        guard stopped.stoppedByHer == true else { return try await stop(stopped, store: store, dataRoot: dataRoot) }
        let flight = await AgentJobFlights.shared.take(job.id)
        flight?.task.cancel()
        var said = flight == nil ? "No run of it is live in this app, so nothing else needed stopping."
            : job.isOwn ? "Your line's turn was stopped." : "Its run here was stopped."
        if let runner = flight?.runner, let session = stopped.session {
            do { try await runner.cancel(session: session); said += " \(job.name) was told to stop its session." }
            catch { said += " \(job.name)'s own stop failed: \(error.localizedDescription); its session may still finish on its side." }
        }
        fields["status"] = .string("stopped"); fields["stopped"] = .bool(true); fields["effects"] = .string("occurred")
        fields["state"] = .string(AgentJob.State.stopped.rawValue)
        fields["detail"] = .string("Stopped. " + said + " Nothing was resent.")
        return fields
    }

    /// The person's and the agent's reading of a job. The organ's words are labelled as its report: data, never instructions.
    static func view(_ job: AgentJob, jobs: Result<[AgentJob], Error>, dataRoot: URL) -> [String: JSONValue] {
        // The agent's own line's words are the agent's.
        let untrusted = !job.isOwn && !PeerTrust.ownerTrusts(job.agent, dataRoot: dataRoot)
        func words(_ text: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            let said: [String: JSONValue] = ["by": .string(job.agent), "text": .string(text), "untrusted_remote_data": .bool(untrusted)]
            return .object(said.merging(extra) { _, new in new })
        }
        var fields: [String: JSONValue] = ["job": .string(job.id), "agent": .string(job.agent), "name": .string(job.name),
            "state": .string(job.state.rawValue), "brief": .string(job.brief), "kind": .string(job.kind),
            "started_at": .string(NativeTimestampFormat.fractionalZulu(job.startedAt))]
        if job.isOwn {
            fields["reach"] = .string("your own hands under your Trust")
            fields["conversation"] = .string(job.id)
            if let instructions = job.instructions { fields["instructions"] = .string(instructions) }
        } else {
            fields["envelope"] = .object(["writes": .bool(job.envelope.writes), "network": .bool(job.envelope.network),
                "folder": job.envelope.folder.map(JSONValue.string) ?? .null])
        }
        if let place = job.place { fields["where"] = .object(["kind": .string(place.kind.rawValue), "path": .string(place.path)]) }
        if let done = job.done {
            var shape: [String: JSONValue] = [:]
            for (key, value) in [("command", done.command), ("file", done.file), ("grep", done.grep), ("in", done.inFile)] {
                if let value { shape[key] = .string(value) }
            }
            fields["done"] = .object(shape)
        }
        if let desk = job.desk { fields["desk"] = .string(desk) }
        if let diff = diffView(job) { fields["diff"] = diff }
        if let session = job.session { fields["session"] = .string(session) }
        if let note = job.note { fields["working_note"] = words(note) }
        if let request = job.request {
            fields["needs"] = .object(["id": .string(request.id), "title": .string(request.title), "subject": request.subject.map(JSONValue.string) ?? .null])
        }
        if !job.deliverables.isEmpty {
            fields["deliverables"] = .array(job.deliverables.map { item in
                var row: [String: JSONValue] = ["path": .string(item.path)]
                if let ref = item.ref {
                    row["make_ref"] = .string(ref)
                    row["made_by"] = .string(AgentJobProvenance(contact: job.name, job: job.id, brief: job.brief).madeBy)
                }
                if let version = item.version { row["version"] = .int(Int64(version)) }
                if let refusal = item.refusal { row["not_registered"] = .string(refusal) }
                return .object(row)
            })
        }
        if let report = job.report {
            fields["report"] = words(report.text, ["truncated": .bool(report.truncated), "model": report.model.map(JSONValue.string) ?? .null])
        }
        if let check = job.check {
            var row: [String: JSONValue] = ["verdict": .string(check.verdict.rawValue), "output": .string(check.output),
                "at": .string(NativeTimestampFormat.fractionalZulu(check.at))]
            if check.fromJobFolder { row["untrusted_remote_data"] = .bool(untrusted) }
            fields["check"] = .object(row)
        }
        if let ended = job.endedAt { fields["ended_at"] = .string(NativeTimestampFormat.fractionalZulu(ended)) }
        if let detail = job.detail { fields["detail"] = .string(detail) }
        switch jobs {
        case .success(let jobs):
            let record = self.record(contact: job.contact, kind: job.kind, in: jobs)
            fields["record"] = .object(["contact": .string(job.agent), "kind": .string(job.kind), "hits": .int(Int64(record.hits)),
                "tries": .int(Int64(record.tries))])
        case .failure(let error):
            fields["record"] = .object(["contact": .string(job.agent), "kind": .string(job.kind),
                "unavailable": .string("The jobs could not be reread: \(error.localizedDescription)")])
        }
        fields["read_with"] = .object(["action": .string("agent.read"), "args": .object(["agent": .string(job.agent), "job": .string(job.id)])])
        if !job.state.isTerminal {
            fields["stop_with"] = .object(["action": .string("agent.cancel"), "args": .object(["agent": .string(job.agent), "job": .string(job.id)])])
        }
        return fields
    }

    /// Hits over tries, from finished jobs: a try is a check that judged; one that could not run is no try.
    static func record(contact: String, kind: String, in jobs: [AgentJob]) -> (hits: Int, tries: Int) {
        let judged = jobs.filter { $0.contact == contact && $0.kind == kind && $0.state.isTerminal }
            .compactMap(\.check?.verdict).filter { $0 != .unavailable }
        return (judged.filter { $0 == .passed }.count, judged.count)
    }

    // MARK: The flight

    static func consume(_ id: String, _ events: AsyncThrowingStream<JobEvent, Error>, dataRoot: URL, register: @escaping AgentJobRegistrar) async {
        let store = AgentJobStore(dataRoot: dataRoot)
        var outcome: JobOutcome?
        do {
            for try await event in events {
                switch event {
                case .started(let session): keep(id, store: store, dataRoot: dataRoot) { $0.session = session }
                case .working(let note):
                    keep(id, store: store, dataRoot: dataRoot) { $0.state = .working; $0.request = nil; $0.note = String(note.prefix(500)) }
                case .needsYou(let request): keep(id, store: store, dataRoot: dataRoot) { $0.state = .needsYou; $0.request = request }
                case .deliverable(let deliverable): await receive(id, deliverable, store: store, dataRoot: dataRoot, register: register)
                case .ended(let ended): outcome = ended
                }
                if outcome != nil { break }
            }
        } catch is CancellationError {
        } catch { outcome = .failed("\(error.localizedDescription). Its organ's outcome is unknown; nothing was resent.") }
        // The agent's stop already owns the record.
        guard !Task.isCancelled else { return }
        await settle(id, outcome ?? .stopped("The job door closed without saying how the job ended."), store: store, dataRoot: dataRoot,
                     register: register)
    }

    /// One event's bookkeeping failing does not end the organ's work: it is owed to the store's owner and the flight goes on.
    static func keep(_ id: String, store: AgentJobStore, dataRoot: URL, _ change: (inout AgentJob) -> Void) {
        do { try store.update(id) { guard !$0.state.isTerminal else { return }; change(&$0) } }
        catch { owe(id, "keep an event", error, store: store, dataRoot: dataRoot) }
    }

    /// Artifacts inside the job's folder register as the agent's with the stem's provenance; the organ's prose is kept as its report; then `done` is checked.
    static func receive(_ id: String, _ deliverable: JobDeliverable, store: AgentJobStore, dataRoot: URL, register: AgentJobRegistrar) async {
        let job: AgentJob
        do { job = try store.job(id) } catch { return owe(id, "read before a deliverable", error, store: store, dataRoot: dataRoot) }
        guard !job.state.isTerminal else { return }
        let folder = job.envelope.folder
        let provenance = AgentJobProvenance(contact: job.name, job: job.id, brief: job.brief)
        let rows = deliverable.artifacts.map { artifact -> AgentJob.Deliverable in
            let file = artifact.standardizedFileURL.resolvingSymlinksInPath()
            guard let folder, file.path.hasPrefix(folder + "/") else {
                return .init(path: file.path, refusal: "outside the job's folder; only what it made in its folder is yours")
            }
            do {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    return .init(path: file.path, refusal: "not a regular file")
                }
                let made = try register(file, provenance)
                return .init(path: file.path, ref: made.ref, version: made.version)
            } catch { return .init(path: file.path, refusal: error.localizedDescription) }
        }
        let check = await self.check(job)
        keep(id, store: store, dataRoot: dataRoot) {
            $0.deliverables += rows
            if let text = deliverable.report {
                $0.report = .init(text: String(text.prefix(reportLimit)), truncated: text.count > reportLimit, model: deliverable.model)
            }
            if let check { $0.check = check }
        }
    }

    static func settle(_ id: String, _ outcome: JobOutcome, store: AgentJobStore, dataRoot: URL, register: AgentJobRegistrar) async {
        var job: AgentJob
        do { job = try store.job(id) } catch { return owe(id, "read at its end", error, store: store, dataRoot: dataRoot) }
        guard !job.state.isTerminal else { return }
        // A finished repo job's diff is captured first, so the check judges the branch as it will be read and applied.
        var captured: (worktree: AgentJob.Worktree, deliverable: AgentJob.Deliverable?)?
        if outcome == .finished, let worktree = job.worktree {
            let diff = await capture(job, worktree, dataRoot: dataRoot, register: register)
            captured = diff
            job.worktree = diff.worktree
        }
        // A job that finished with nothing handed over is still checked: `done` predicts the world, not the artifacts. A repo job's world is its worktree at
        // its end.
        var late: AgentJob.Check?
        if outcome == .finished, captured != nil || (job.check == nil && job.deliverables.isEmpty) { late = await check(job) }
        let ended: AgentJob
        do {
            ended = try store.update(id) {
                guard !$0.state.isTerminal else { return }
                if let captured {
                    $0.worktree = captured.worktree
                    if let row = captured.deliverable { $0.deliverables.append(row) }
                }
                if let late { $0.check = late }
                $0.request = nil
                switch outcome {
                case .finished:
                    switch $0.check?.verdict {
                    case .passed?: $0.state = .done; $0.detail = "Done: your check passed."
                    case .failed?: $0.state = .failed; $0.detail = "Your check did not pass; its output is under check."
                    case .unavailable?: $0.state = .delivered; $0.detail = "Delivered, unchecked: your check could not run; why is under check."
                    case nil: $0.state = .delivered; $0.detail = "Delivered, unchecked: no check was set."
                    }
                case .failed(let why): $0.state = .failed; $0.detail = "Its door reported a failure: " + why
                case .stopped(let why): $0.state = .stopped; $0.detail = "Stopped: " + why
                }
            }
        } catch { return owe(id, "record its end", error, store: store, dataRoot: dataRoot) }
        guard ended.state.isTerminal, ended.stoppedByHer != true else { return }
        wake(ended, dataRoot: dataRoot, store: store)
    }

    /// The agent's own context wakes: the conversation that commissioned it, on the agent's own surface. The line is the stem's own words, never the organ's
    /// or its door's, so the wake quotes no agent and latches no steering; the agent's own line's answer is the agent's and rides along.
    static func wake(_ job: AgentJob, dataRoot: URL, store: AgentJobStore) {
        let made = job.deliverables.compactMap { item in item.ref.flatMap { ref in item.version.map { "Make \(ref) v\($0)" } } }
        let ended = switch job.state {
        case .done: "done: your check passed."
        case .failed: job.check?.verdict == .failed ? "failed: your check did not pass." : "failed: its door reported a failure."
        case .delivered: job.check == nil ? "delivered, unchecked: no check was set." : "delivered, unchecked: your check could not run."
        case .stopped: "stopped before it ended."
        case .working, .needsYou: job.state.rawValue
        }
        var line = job.isOwn ? "Your line ended the work you gave it (\(job.id), \"\(String(job.brief.prefix(80)))\"): " + ended
            : "\(job.name) ended the job you gave it (\(job.id), \"\(String(job.brief.prefix(80)))\"): " + ended
        // The agent's line's answer is the agent's own words, so it rides the news itself.
        if job.isOwn, let report = job.report?.text, !report.isEmpty {
            line += " It said: \"" + String(report.prefix(600)) + (report.count > 600 ? "…" : "") + "\""
        }
        if !made.isEmpty { line += " Yours now, \(made.count) made by \(job.name): " + made.joined(separator: ", ") + "." }
        let refused = job.deliverables.filter { $0.refusal != nil }.count
        if refused > 0 { line += " \(refused) returned file\(refused == 1 ? " was" : "s were") not registered." }
        if let worktree = job.worktree, let files = worktree.files, !files.isEmpty {
            line += " Its diff (\(files.count) file\(files.count == 1 ? "" : "s") on \(worktree.branch)) waits for you: read it, then agent.apply or "
                + "agent.discard with args {job:\"\(job.id)\"}."
        }
        if let desk = job.desk { line += " It carries your Desk item \(desk)." }
        line += " Read it: app {action:\"agent.read\", args:{agent:\"\(job.agent)\", job:\"\(job.id)\"}}."
        guard ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(id: "job:" + job.id + ":" + job.state.rawValue,
            line: line, thread: job.id, session: job.commission.session)]) else {
            return owe(job.id, "wake its commissioning context", AgentJobStore.Failure(message: "the arrival ledger did not keep it"),
                store: store, dataRoot: dataRoot)
        }
    }

    static func owe(_ id: String, _ stage: String, _ error: Error, store: AgentJobStore, dataRoot: URL) {
        let next = ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(store.fileURL.path)])])
        RepairOwed.owe(dataRoot, id: id + ":" + stage, kind: .message, operation: "agent.job:" + id + ":" + stage, owner: store.fileURL.path,
            words: "Job \(id) could not \(stage): \(error.localizedDescription).",
            lever: "Repair \(store.fileURL.path), then read the job; the organ's work is never resent to repair bookkeeping.", nextCall: next)
    }

    // MARK: The done-check

    /// Run `done` against the job's folder under the job's envelope. Nil when no check is set.
    static func check(_ job: AgentJob) async -> AgentJob.Check? {
        guard let done = job.done else { return nil }
        func verdict(_ verdict: AgentJob.Check.Verdict, _ output: String, folder: Bool = false) -> AgentJob.Check {
            .init(verdict: verdict, output: String(output.suffix(4000)), fromJobFolder: folder, at: Date())
        }
        func resolve(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                return URL(fileURLWithPath: job.envelope.folder ?? "/", isDirectory: true).appendingPathComponent(expanded)
            }
            // A path in the agent's checkout names the same file in the job's worktree: the job's own copy of the agent's repository.
            let named = URL(fileURLWithPath: expanded).standardizedFileURL.path
            if let worktree = job.worktree, let place = job.place,
               let inside = NativeAgentWorkspaceRoot.relativePath(named, under: place.path) {
                return URL(fileURLWithPath: worktree.path, isDirectory: true).appendingPathComponent(inside)
            }
            return URL(fileURLWithPath: expanded)
        }
        if let file = done.file {
            let url = resolve(file)
            return FileManager.default.fileExists(atPath: url.path) ? verdict(.passed, "\(url.path) exists.")
                : verdict(.failed, "\(url.path) does not exist.")
        }
        if let pattern = done.grep, let inFile = done.inFile {
            let url = resolve(inFile)
            guard FileManager.default.fileExists(atPath: url.path) else { return verdict(.failed, "\(url.path) does not exist.") }
            let text: String
            do {
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    return verdict(.unavailable, "\(url.path) has no readable size; the grep did not read it.")
                }
                guard size <= 8 * 1024 * 1024 else { return verdict(.unavailable, "\(url.path) is over 8 MiB; the grep did not read it.") }
                text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            } catch { return verdict(.unavailable, "\(url.path) could not be read: \(error.localizedDescription)") }
            do {
                let found = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
                    .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                return found ? verdict(.passed, "\(pattern) matches in \(url.path).") : verdict(.failed, "\(pattern) matches nothing in \(url.path).")
            } catch { return verdict(.unavailable, "grep is not a regular expression: \(error.localizedDescription)") }
        }
        guard let command = done.command, let folder = job.envelope.folder else { return verdict(.unavailable, "The check has no folder to run in.") }
        let environment: [String: String]
        switch AgentHostCommandLines.loginEnvironment {
        case .success(let found): environment = found
        case .failure(let failure): return verdict(.unavailable, failure.message)
        }
        do {
            let ran = try await ProcessExecution().run(executable: "/usr/bin/sandbox-exec",
                arguments: ["-p", sandbox(job.envelope), "/bin/sh", "-c", command], currentDirectory: URL(fileURLWithPath: folder, isDirectory: true),
                environment: environment, standardInput: nil, timeoutSeconds: checkSeconds, outputByteLimit: 256 * 1024)
            let output = [ran.stdout, ran.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            if ran.timedOut { return verdict(.unavailable, "The check did not finish within \(Int(checkSeconds / 60)) minutes. " + output, folder: true) }
            return verdict(ran.exitCode == 0 ? .passed : .failed, "exit \(ran.exitCode)" + (output.isEmpty ? "" : "\n" + output), folder: true)
        } catch { return verdict(.unavailable, "The check could not run: \(error.localizedDescription)") }
    }

    /// The check runs with the organ's envelope: writes only in its folder when it may write, no network unless it has network.
    static func sandbox(_ envelope: AgentJob.Envelope) -> String {
        func literal(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var profile = ["(version 1)", "(allow default)", "(deny file-write*)",
                       "(allow file-write* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/tty\"))"]
        if envelope.writes, let folder = envelope.folder { profile.append("(allow file-write* (subpath \(literal(folder))))") }
        if !envelope.network { profile.append("(deny network*)") }
        return profile.joined(separator: "\n")
    }

    // MARK: Refusals

    static func refused(_ reason: String, _ detail: String, path: String) -> JSONValue {
        .object(["status": .string("refused"), "reason": .string(reason), "effects": .string("none"), "sent": .bool(false),
                 "argument_path": .string(path), "detail": .string(detail)])
    }

    static func failed(_ detail: String, effects: String, job: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["status": .string("failed"), "effects": .string(effects), "detail": .string(detail)]
        if let job { fields["job"] = .string(job) }
        return .object(fields)
    }
}

/// The live runs of this app: the stop reaches the consuming task and the door that serves it. The agent's own line has no door: ending its stream stops its
/// turn.
actor AgentJobFlights {
    static let shared = AgentJobFlights()
    private var flights: [String: (runner: (any JobRunner)?, task: Task<Void, Never>)] = [:]

    func fly(_ id: String, runner: (any JobRunner)?, _ body: @escaping @Sendable () async -> Void) {
        flights[id] = (runner, Task.detached(priority: .utility) {
            await body()
            await AgentJobFlights.shared.land(id)
        })
    }

    func take(_ id: String) -> (runner: (any JobRunner)?, task: Task<Void, Never>)? { flights.removeValue(forKey: id) }

    private func land(_ id: String) { flights.removeValue(forKey: id) }
}
