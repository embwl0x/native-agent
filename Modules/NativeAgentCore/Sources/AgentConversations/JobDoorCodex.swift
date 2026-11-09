import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `JobDoorCodex.swift` | `CodexJobDoor`, `JobRPC`: a job through `codex app-server` over stdio, one thread in the job's folder |

/// JSON-RPC over the app-server's stdio: our requests wait for their answers; its notifications and requests arrive in order on `inbound`.
actor JobRPC {
    let process: AgentLineProcess
    nonisolated let inbound: AsyncThrowingStream<JSONValue, Error>
    private let incoming: AsyncThrowingStream<JSONValue, Error>.Continuation
    private var next: Int64 = 0
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed: (any Error)?

    init(_ process: AgentLineProcess) {
        self.process = process
        let pair = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .unbounded)
        inbound = pair.stream
        incoming = pair.continuation
    }

    /// Reads the program's output until it closes; every request still waiting then fails with why, and so does `inbound`.
    func pump() async {
        var ending: any Error = JobDoorFailure("its app-server closed its output")
        do {
            for try await message in process.lines {
                guard let fields = message.objectValue else { throw JobDoorFailure("its app-server wrote a message that is not an object") }
                if fields["method"]?.stringValue != nil { incoming.yield(message); continue }
                guard case .int(let id)? = fields["id"], let waiting = pending.removeValue(forKey: id) else { continue }
                if let error = fields["error"]?.objectValue {
                    let code: String = if case .int(let code)? = error["code"] { " (\(code))" } else { "" }
                    waiting.resume(throwing: JobDoorFailure((error["message"]?.stringValue ?? "an error with no message") + code))
                } else if let result = fields["result"] { waiting.resume(returning: result) }
                else { waiting.resume(throwing: JobDoorFailure("its app-server response \(id) has neither result nor error")) }
            }
        } catch { ending = error }
        closed = ending
        for waiting in pending.values { waiting.resume(throwing: ending) }
        pending.removeAll()
        incoming.finish(throwing: ending)
    }

    func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        if let closed { throw closed }
        guard next < Int64.max else { throw JobDoorFailure("its app-server request identifiers are exhausted") }
        next += 1
        let id = next
        let message = JSONValue.object(["id": .int(id), "method": .string(method), "params": .object(params)])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { await self.deliver(id, message) }
            }
        } onCancel: { Task { await self.abandon(id) } }
    }

    /// A request whose answer nobody waits for: a stop on the way out.
    func fire(_ method: String, _ params: [String: JSONValue]) async throws {
        guard next < Int64.max else { throw JobDoorFailure("its app-server request identifiers are exhausted") }
        next += 1
        try await process.send(.object(["id": .int(next), "method": .string(method), "params": .object(params)]))
    }

    func notify(_ method: String) async throws {
        try await process.send(.object(["method": .string(method), "params": .object([:])]))
    }

    func respond(_ id: JSONValue, _ answer: Result<JSONValue, JobDoorFailure>, code: Int64 = -32601) async throws {
        switch answer {
        case .success(let result): try await process.send(.object(["id": id, "result": result]))
        case .failure(let failure):
            try await process.send(.object(["id": id, "error": .object(["code": .int(code), "message": .string(failure.message)])]))
        }
    }

    private func deliver(_ id: Int64, _ message: JSONValue) async {
        do { try await process.send(message) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
    }

    private func abandon(_ id: Int64) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

/// Codex takes a job in its own app-server: a thread in the job's folder under `workspace-write` (or `read-only`) with the envelope's network, approvals
/// asked on request and sent to the agent's broker. The person's own Codex defaults (approval policy, sandbox, reviewer) never reach a job: every bound is
/// passed.
struct CodexJobDoor: JobRunner {
    let dataRoot: URL
    static let door = "codex-app-server"

    func serves(_ contact: AgentPeerContact) -> Bool {
        contact.transport == .mcpHost && contact.ability == nil && JobDoors.flags(contact) == .codex
    }

    func start(_ job: JobStart) async throws -> AsyncThrowingStream<JobEvent, Error> { try open(job, resuming: nil) }

    func resume(_ job: JobStart, session: String) async throws -> AsyncThrowingStream<JobEvent, Error> { try open(job, resuming: session) }

    func cancel(session: String) async throws { await JobDoorLive.shared.stop(Self.door + ":" + session) }

    private func open(_ job: JobStart, resuming: String?) throws -> AsyncThrowingStream<JobEvent, Error> {
        let name = job.contact.name
        let record = try JobDoors.Record.read(job, dataRoot: dataRoot)
        let approved = try JobDoors.approved(job.contact)
        let (host, row) = try JobDoors.recipe(job.contact)
        let environment: [String: String]
        do { environment = try row.installation.launchEnvironment() }
        catch { throw JobRefusal("\(name)'s installation could not be read: \(error.localizedDescription). Nothing ran.") }
        let folder = try JobDoors.folder(job, host: host, dataRoot: dataRoot)
        let process: AgentLineProcess
        do {
            process = try AgentLineProcess(executable: approved.path, arguments: ["app-server"], directory: folder, environment: environment,
                                           approved: approved)
        } catch AgentACPClient.Failure.executableChanged {
            throw JobRefusal("\(name)'s program changed or is missing since it was approved. Reconnect it (agent.connect) to approve it. Nothing ran.")
        } catch { throw JobRefusal("\(name)'s app-server could not start: \(error.localizedDescription). Nothing ran.") }
        let (stream, continuation) = AsyncThrowingStream<JobEvent, Error>.makeStream()
        let out = JobDoorOut(continuation, contact: job.contact)
        let run = JobDoorRun()
        run.drive {
            await drive(job, resuming: resuming, process: process, folder: folder, record: record, out: out, run: run)
        }
        continuation.onTermination = { _ in run.cancel() }
        return stream
    }

    private func drive(_ job: JobStart, resuming: String?, process: AgentLineProcess, folder: URL, record: JobDoors.Record, out: JobDoorOut,
                       run: JobDoorRun) async {
        let name = job.contact.name
        let rpc = JobRPC(process)
        Task { await rpc.pump() }
        var asks: [Task<Void, Never>] = []
        var changes: [String: [String]] = [:]
        var thread: String?, turn: String?, model: String?, report: String?
        var outcome: JobOutcome?
        do {
            _ = try await rpc.request("initialize", ["clientInfo": .object(["name": .string("nativeagent"), "title": .string("NativeAgent"),
                                                                             "version": .string("1")])])
            try await rpc.notify("initialized")
            var bounds: [String: JSONValue] = ["cwd": .string(folder.path), "sandbox": .string(job.envelope.writes ? "workspace-write" : "read-only"),
                                               "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user")]
            if let resuming { bounds["threadId"] = .string(resuming) }
            let opened = try await rpc.request(resuming == nil ? "thread/start" : "thread/resume", bounds)
            guard let id = opened.objectValue?["thread"]?.objectValue?["id"]?.stringValue, !id.isEmpty else {
                throw JobDoorFailure("its app-server opened no thread")
            }
            thread = id
            model = opened.objectValue?["model"]?.stringValue
            out.send(.started(session: id))
            await JobDoorLive.shared.hold(Self.door + ":" + id, run)
            let brief = resuming == nil ? job.brief : JobDoors.resumed(job.brief)
            let begun = try await rpc.request("turn/start", ["threadId": .string(id),
                "input": .array([.object(["type": .string("text"), "text": .string(brief)])]),
                "sandboxPolicy": Self.sandbox(job.envelope, folder: folder), "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user")])
            guard let turnID = begun.objectValue?["turn"]?.objectValue?["id"]?.stringValue else { throw JobDoorFailure("its app-server started no turn") }
            turn = turnID
            out.send(.working(note: "Working in \(folder.path)."))
            for try await message in rpc.inbound {
                let fields = message.objectValue ?? [:]
                let method = fields["method"]?.stringValue ?? ""
                let params = fields["params"]?.objectValue ?? [:]
                if let asked = fields["id"] {
                    let touched = params["itemId"]?.stringValue.flatMap { changes[$0] } ?? []
                    asks.append(Task {
                        await answer(method, id: asked, params: params, touched: touched, rpc: rpc, job: job, record: record, folder: folder, out: out)
                    })
                    continue
                }
                let item = params["item"]?.objectValue ?? [:]
                switch method {
                case "item/started", "item/completed":
                    if item["type"]?.stringValue == "fileChange", let itemID = item["id"]?.stringValue {
                        changes[itemID] = (item["changes"]?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
                    }
                    if method == "item/completed", item["type"]?.stringValue == "agentMessage", let text = item["text"]?.stringValue { report = text }
                    if method == "item/started", let note = Self.note(item) { out.send(.working(note: note)) }
                case "error" where params["willRetry"]?.boolValue == false:
                    let said = params["error"]?.objectValue?["message"]?.stringValue ?? "an error with no message"
                    out.send(.working(note: "\(name) reported: " + said))
                case "turn/completed":
                    let ended = params["turn"]?.objectValue ?? [:]
                    guard ended["id"]?.stringValue == turnID else { continue }
                    switch ended["status"]?.stringValue {
                    case "completed"?: outcome = .finished
                    case "interrupted"?: outcome = .stopped("\(name) interrupted its turn")
                    default:
                        let why = ended["error"]?.objectValue?["message"]?.stringValue ?? "its turn ended \(ended["status"]?.stringValue ?? "with no status")"
                        outcome = .failed(why)
                    }
                default: break
                }
                if outcome != nil { break }
            }
        } catch is CancellationError {
        } catch {
            outcome = .failed("\(name)'s app-server: \(error.localizedDescription)")
        }
        for ask in asks { ask.cancel() }
        guard !Task.isCancelled else {
            // Interrupt the turn before closing its program.
            if let thread, let turn {
                do { try await rpc.fire("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)]) }
                catch {
                    RepairOwed.owe(dataRoot, id: job.job + ":interrupt", kind: .message, operation: "agent.job:" + job.job + ":interrupt",
                        owner: name, words: "Job \(job.job)'s interrupt was not delivered: \(error.localizedDescription)",
                        lever: "Inspect its remote thread before resuming work.")
                }
            }
            let unconfirmed = await Task.detached { await process.stop() }.value
            if let unconfirmed {
                RepairOwed.owe(dataRoot, id: job.job + ":stop", kind: .message, operation: "agent.job:" + job.job + ":stop",
                    owner: name, words: "Job \(job.job)'s process termination is unconfirmed: \(unconfirmed)",
                    lever: "Inspect the retained process before starting more work through this contact.")
            }
            if let thread { await JobDoorLive.shared.release(Self.door + ":" + thread, run) }
            return out.stopped("its job was stopped")
        }
        let unconfirmed = await process.stop()
        if let thread { await JobDoorLive.shared.release(Self.door + ":" + thread, run) }
        if let unconfirmed { return out.fail(JobDoorFailure("Its program termination is unconfirmed: " + unconfirmed)) }
        var ending = outcome ?? .failed("its app-server ended before its turn did")
        if ending == .finished {
            do {
                let made = try await JobDoorArtifacts.deliverable(job, since: record.startedAt, report: report, model: model)
                out.send(.deliverable(made))
                if let failure = made.inventoryFailure { ending = .failed(failure) }
            } catch {
                out.send(.deliverable(JobDeliverable(artifacts: [], report: report, model: model)))
                ending = .failed("Its deliverable could not be inventoried: \(error.localizedDescription)")
            }
        }
        out.send(.ended(ending))
    }

    /// The envelope as Codex's own sandbox: writes only in the job's folder (not even its temp folders) and network only when the envelope has it.
    static func sandbox(_ envelope: AgentJob.Envelope, folder: URL) -> JSONValue {
        guard envelope.writes else { return .object(["type": .string("readOnly"), "networkAccess": .bool(envelope.network)]) }
        return .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(folder.path)]), "networkAccess": .bool(envelope.network),
                        "excludeSlashTmp": .bool(true), "excludeTmpdirEnvVar": .bool(true)])
    }

    static func note(_ item: [String: JSONValue]) -> String? {
        switch item["type"]?.stringValue {
        case "commandExecution"?: return "Running: " + String((item["command"]?.stringValue ?? "a command").prefix(160))
        case "fileChange"?:
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
            return "Changing " + (paths.isEmpty ? "files" : paths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
        case "webSearch"?: return "Searching the web: " + String((item["query"]?.stringValue ?? "").prefix(120))
        case "mcpToolCall"?: return "Using " + (item["server"]?.stringValue ?? "a tool server") + "." + (item["tool"]?.stringValue ?? "tool")
        default: return nil
        }
    }

    /// Every request the app-server sends is answered: approvals by the agent's broker against the envelope, questions and client tools plainly declined.
    private func answer(_ method: String, id: JSONValue, params: [String: JSONValue], touched: [String], rpc: JobRPC, job: JobStart,
                        record: JobDoors.Record, folder: URL, out: JobDoorOut) async {
        func decide(_ ask: JobAsk) async -> Bool {
            await JobDoorBroker.answer(ask, job: job, record: record, cwd: folder, out: out, dataRoot: dataRoot)
        }
        let request = JSONValue.object(params)
        let reply: Result<JSONValue, JobDoorFailure>
        var code: Int64 = -32601
        switch method {
        case "item/commandExecution/requestApproval":
            let ask: JobAsk
            if let host = params["networkApprovalContext"]?.objectValue?["host"]?.stringValue {
                ask = JobAsk(kind: .network, paths: [], title: "reach \(host)", request: request)
            } else {
                let command = String((params["command"]?.stringValue ?? "a command").prefix(200))
                ask = JobAsk(kind: .other, paths: [], title: "run \(command) outside its sandbox", request: request)
            }
            reply = .success(.object(["decision": .string(await decide(ask) ? "accept" : "decline")]))
        case "item/fileChange/requestApproval":
            let paths = touched + (params["grantRoot"]?.stringValue.map { [$0] } ?? [])
            let shown = paths.isEmpty ? "files it did not name" : paths.prefix(3).joined(separator: ", ")
            reply = .success(.object(["decision": .string(await decide(JobAsk(kind: .write, paths: paths, title: "change \(shown)",
                                                                                request: request)) ? "accept" : "decline")]))
        case "item/permissions/requestApproval":
            let wanted = params["permissions"]?.objectValue ?? [:]
            let files = wanted["fileSystem"]?.objectValue ?? [:]
            let writes = (files["write"]?.arrayValue ?? []).compactMap(\.stringValue)
            let network = wanted["network"]?.objectValue?["enabled"]?.boolValue == true
            let plain = (files["entries"]?.arrayValue ?? []).isEmpty && (files["read"]?.arrayValue ?? []).isEmpty
            let ask: JobAsk = switch (writes.isEmpty, network, plain) {
            case (true, true, true): JobAsk(kind: .network, paths: [], title: "use the network", request: request)
            case (false, false, true): JobAsk(kind: .write, paths: writes, title: "write in " + writes.prefix(3).joined(separator: ", "), request: request)
            default: JobAsk(kind: .other, paths: writes, title: "widen its sandbox", request: request)
            }
            let granted = await decide(ask)
            reply = .success(.object(["permissions": granted ? .object(wanted) : .object([:]), "scope": .string("turn")]))
        case "mcpServer/elicitation/request":
            reply = .success(.object(["action": .string("decline"), "content": .null, "_meta": .null]))
        case "item/tool/call":
            reply = .success(.object(["contentItems": .array([.object(["type": .string("inputText"),
                "text": .string("No client tools are offered during a job. Use your own tools, or say what blocked you in your final answer.")])]),
                "success": .bool(false)]))
        case "item/tool/requestUserInput":
            code = -32001
            reply = .failure(JobDoorFailure("Nobody answers questions during a job. Decide, and say in your final answer what you assumed."))
        default:
            reply = .failure(JobDoorFailure("This client does not offer \(method)."))
        }
        guard !Task.isCancelled else { return }
        do { try await rpc.respond(id, reply, code: code) }
        catch { out.fail(JobDoorFailure("Its request \(method) could not be answered: \(error.localizedDescription).")) }
    }
}
