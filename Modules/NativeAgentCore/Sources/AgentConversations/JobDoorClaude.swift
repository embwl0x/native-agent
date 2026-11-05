import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `JobDoorClaude.swift` | `ClaudeCodeJobDoor`: a job through `claude -p` stream-json, its permission prompts answered by the agent's broker over stdio |

/// Claude Code takes a job headless: `claude -p` reading and writing stream-json, its permission prompts sent to this host over stdio
/// (`--permission-prompts host --permission-prompt-tool stdio`) and answered by the agent's broker against the envelope. `--restricted` confines its file
/// tools to the job's folder, drops the tools that run code or fetch, and ignores the person's own Claude settings; `--strict-mcp-config` gives it no MCP
/// servers.
struct ClaudeCodeJobDoor: JobRunner {
    let dataRoot: URL
    static let door = "claude-stream-json"

    func serves(_ contact: AgentPeerContact) -> Bool {
        contact.transport == .mcpHost && contact.ability == nil && JobDoors.flags(contact) == .claude
    }

    func start(_ job: JobStart) async throws -> AsyncThrowingStream<JobEvent, Error> { try open(job, resuming: nil) }

    func resume(_ job: JobStart, session: String) async throws -> AsyncThrowingStream<JobEvent, Error> { try open(job, resuming: session) }

    func cancel(session: String) async throws { await JobDoorLive.shared.stop(Self.door + ":" + session) }

    /// The envelope as Claude Code's own flags. Without network it has no web search either; with it, web search stays (fetching stays off under
    /// `--restricted`).
    static func arguments(_ envelope: AgentJob.Envelope, resuming: String?) -> [String] {
        ["-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--restricted", "--strict-mcp-config",
         "--permission-mode", "manual", "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]
            + (resuming.map { ["--resume", $0] } ?? [])
            + (envelope.network ? [] : ["--disallowedTools", "WebSearch"])
    }

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
            process = try AgentLineProcess(executable: approved.path, arguments: Self.arguments(job.envelope, resuming: resuming), directory: folder,
                                           environment: environment, approved: approved)
        } catch AgentACPClient.Failure.executableChanged {
            throw JobRefusal("\(name)'s program changed or is missing since it was approved. Reconnect it (agent.connect) to approve it. Nothing ran.")
        } catch { throw JobRefusal("\(name) could not start: \(error.localizedDescription). Nothing ran.") }
        let (stream, continuation) = AsyncThrowingStream<JobEvent, Error>.makeStream()
        let out = JobDoorOut(continuation, contact: job.contact)
        let run = JobDoorRun()
        run.drive { await drive(job, resuming: resuming, process: process, folder: folder, record: record, out: out, run: run) }
        continuation.onTermination = { _ in run.cancel() }
        return stream
    }

    private func drive(_ job: JobStart, resuming: String?, process: AgentLineProcess, folder: URL, record: JobDoors.Record, out: JobDoorOut,
                       run: JobDoorRun) async {
        let name = job.contact.name
        var asks: [String: Task<Void, Never>] = [:]
        var session: String?, model: String?, said: String?
        var outcome: JobOutcome?, report: String?
        do {
            try await process.send(.object(["type": .string("control_request"), "request_id": .string("init-" + UUID().uuidString.lowercased()),
                                            "request": .object(["subtype": .string("initialize")])]))
            let brief = resuming == nil ? job.brief : JobDoors.resumed(job.brief)
            try await process.send(.object(["type": .string("user"), "session_id": .string("default"), "parent_tool_use_id": .null,
                "message": .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string(brief)])])])]))
            for try await message in process.lines {
                let fields = message.objectValue ?? [:]
                switch fields["type"]?.stringValue {
                case "system"? where fields["subtype"]?.stringValue == "init":
                    model = fields["model"]?.stringValue ?? model
                    if session == nil, let id = fields["session_id"]?.stringValue, !id.isEmpty {
                        session = id
                        out.send(.started(session: id))
                        await JobDoorLive.shared.hold(Self.door + ":" + id, run)
                        out.send(.working(note: "Working in \(folder.path)."))
                    }
                case "assistant"?:
                    for block in fields["message"]?.objectValue?["content"]?.arrayValue ?? [] {
                        let part = block.objectValue ?? [:]
                        if part["type"]?.stringValue == "text", let text = part["text"]?.stringValue { said = text }
                        if part["type"]?.stringValue == "tool_use", let tool = part["name"]?.stringValue {
                            out.send(.working(note: Self.note(tool, part["input"]?.objectValue ?? [:])))
                        }
                    }
                case "control_request"?:
                    guard let id = fields["request_id"]?.stringValue else { continue }
                    let request = fields["request"]?.objectValue ?? [:]
                    asks[id] = Task {
                        await answer(id: id, request: request, process: process, job: job, record: record, folder: folder, out: out)
                    }
                case "control_cancel_request"?:
                    if let id = fields["request_id"]?.stringValue { asks.removeValue(forKey: id)?.cancel() }
                case "result"?:
                    if let id = fields["session_id"]?.stringValue, session == nil {
                        session = id
                        out.send(.started(session: id))
                    }
                    let text = fields["result"]?.stringValue
                    if fields["is_error"]?.boolValue == true || fields["subtype"]?.stringValue != "success" {
                        let errors = (fields["errors"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "; ")
                        outcome = .failed(text ?? (errors.isEmpty ? "it ended \(fields["subtype"]?.stringValue ?? "with an error")" : errors))
                    } else {
                        report = text ?? said
                        outcome = .finished
                    }
                default: break
                }
                if outcome != nil { break }
            }
        } catch is CancellationError {
        } catch {
            outcome = .failed("\(name)'s stream: \(error.localizedDescription)")
        }
        for ask in asks.values { ask.cancel() }
        guard !Task.isCancelled else {
            // The agent's stop: the organ is interrupted on its own terms, then its program ends; its session stays resumable on its side.
            do {
                try await process.send(.object(["type": .string("control_request"), "request_id": .string("stop-" + UUID().uuidString.lowercased()),
                                                "request": .object(["subtype": .string("interrupt")])]))
            } catch { nativeLog("Claude Code job door: the interrupt was not delivered: %@", error.localizedDescription) }
            _ = await Task.detached { await process.stop(grace: .seconds(2)) }.value
            if let session { await JobDoorLive.shared.release(Self.door + ":" + session, run) }
            return out.stopped("its job was stopped")
        }
        let unconfirmed = await process.stop(grace: .seconds(2))
        if let session { await JobDoorLive.shared.release(Self.door + ":" + session, run) }
        if let unconfirmed { out.send(.working(note: "Its program did not confirm it stopped: " + unconfirmed)) }
        let ending = outcome ?? .failed("\(name) exited before it reported a result")
        if ending == .finished {
            let made = await JobDoorArtifacts.deliverable(job, since: record.startedAt, report: report, model: model, out: out)
            out.send(.deliverable(made))
        }
        out.send(.ended(ending))
    }

    static func note(_ tool: String, _ input: [String: JSONValue]) -> String {
        let target = ["file_path", "notebook_path", "path", "pattern", "query", "url"].lazy.compactMap { input[$0]?.stringValue }.first
        return tool + (target.map { ": " + String($0.prefix(160)) } ?? "")
    }

    /// A tool the CLI asks about, as the broker reads it. Unknown tools are the person's to decide.
    static func ask(_ tool: String, _ input: [String: JSONValue], request: JSONValue) -> JobAsk {
        let target = ["file_path", "notebook_path"].lazy.compactMap { input[$0]?.stringValue }.first
        switch tool {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return JobAsk(kind: .write, paths: target.map { [$0] } ?? [], title: "\(tool) \(target ?? "a file it did not name")", request: request)
        case "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoWrite", "Task", "Agent":
            return JobAsk(kind: .read, paths: [], title: note(tool, input), request: request)
        case "WebSearch", "WebFetch":
            return JobAsk(kind: .network, paths: [], title: note(tool, input), request: request)
        default:
            if input.count == 1, let host = input["host"]?.stringValue {
                return JobAsk(kind: .network, paths: [], title: "reach \(host)", request: request)
            }
            return JobAsk(kind: .other, paths: [], title: note(tool, input), request: request)
        }
    }

    /// Every control request is answered: `can_use_tool` by the agent's broker against the envelope; anything else this host does not serve.
    private func answer(id: String, request: [String: JSONValue], process: AgentLineProcess, job: JobStart, record: JobDoors.Record, folder: URL,
                        out: JobDoorOut) async {
        let response: JSONValue
        if request["subtype"]?.stringValue == "can_use_tool", let tool = request["tool_name"]?.stringValue {
            let input = request["input"]?.objectValue ?? [:]
            let decision: JSONValue
            if request["requires_user_interaction"]?.boolValue == true {
                decision = .object(["behavior": .string("deny"),
                    "message": .string("Nobody answers questions during a job. Decide, and say in your final answer what you assumed.")])
            } else if await JobDoorBroker.answer(Self.ask(tool, input, request: .object(request)), job: job, record: record, cwd: folder, out: out,
                                                dataRoot: dataRoot) {
                decision = .object(["behavior": .string("allow"), "updatedInput": .object(input)])
            } else {
                decision = .object(["behavior": .string("deny"), "message": .string("Not allowed: outside this job's reach.")])
            }
            response = .object(["subtype": .string("success"), "request_id": .string(id), "response": decision])
        } else {
            response = .object(["subtype": .string("error"), "request_id": .string(id),
                                "error": .string("This host does not serve \(request["subtype"]?.stringValue ?? "that request") during a job.")])
        }
        guard !Task.isCancelled else { return }
        do { try await process.send(.object(["type": .string("control_response"), "response": response])) }
        catch { out.send(.working(note: "Its permission request could not be answered: \(error.localizedDescription).")) }
    }
}
