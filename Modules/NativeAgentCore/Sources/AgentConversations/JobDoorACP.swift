import Foundation
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `JobDoorACP.swift` | `ACPJobDoor`: a job as one ACP session in the job's folder, `session/request_permission` answered against the envelope |

/// An agent that speaks ACP natively takes a job as one session in the job's folder, in its recipe's own ask mode. Each `session/request_permission` is
/// answered by the agent's broker against the envelope; nothing is allowed because the contact is trusted or the Mac is in Full Mac. The session carries no
/// nativeagent-link server: the job's result comes back through the job, not as a message to the agent. The prompt has no deadline.
struct ACPJobDoor: JobRunner {
    let dataRoot: URL
    static let door = "acp"

    func serves(_ contact: AgentPeerContact) -> Bool { contact.transport == .acp && contact.ability == nil }

    func start(_ job: JobStart) async throws -> AsyncThrowingStream<JobEvent, Error> { try open(job, resuming: nil) }

    func resume(_ job: JobStart, session: String) async throws -> AsyncThrowingStream<JobEvent, Error> { try open(job, resuming: session) }

    func cancel(session: String) async throws { await JobDoorLive.shared.stop(Self.door + ":" + session) }

    private func open(_ job: JobStart, resuming: String?) throws -> AsyncThrowingStream<JobEvent, Error> {
        let name = job.contact.name
        let record = try JobDoors.Record.read(job, dataRoot: dataRoot)
        let (_, row) = try JobDoors.recipe(job.contact)
        guard let line = row.acp else { throw JobRefusal("\(name)'s recipe has no host.acp; read it with agent.recipe. Nothing ran.") }
        guard let approved = job.contact.approvedACPExecutable, approved.isCurrent else {
            throw JobRefusal("\(name)'s approved program is missing, changed, or was never bound. Reconnect it (agent.connect) to approve it. Nothing ran.")
        }
        if let blocker = line.startupBlocker(installedVersion: approved.version) { throw JobRefusal(blocker) }
        let environment: [String: String]
        do { environment = try row.installation.launchEnvironment() }
        catch { throw JobRefusal("\(name)'s installation could not be read: \(error.localizedDescription). Nothing ran.") }
        guard let folder = job.folder ?? job.contact.acpWorkingDirectory.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw JobRefusal("\(name) has no approved starting folder and the job has none. Reconnect it, or pass where. Nothing ran.")
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw JobRefusal("\(folder.path) could not be made: \(error.localizedDescription). Nothing ran.") }
        let (stream, continuation) = AsyncThrowingStream<JobEvent, Error>.makeStream()
        let out = JobDoorOut(continuation, contact: job.contact)
        let run = JobDoorRun()
        run.drive {
            await drive(job, resuming: resuming, line: line, approved: approved, environment: environment, folder: folder, record: record, out: out,
                        run: run)
        }
        continuation.onTermination = { _ in run.cancel() }
        return stream
    }

    private func drive(_ job: JobStart, resuming: String?, line: AgentHostACP, approved: AgentACPExecutable, environment: [String: String],
                       folder: URL, record: JobDoors.Record, out: JobDoorOut, run: JobDoorRun) async {
        let name = job.contact.name
        let client = AgentACPClient(dataRoot: dataRoot)
        let opened = OpenedSession()
        let outcome: JobOutcome
        var deliverable: JobDeliverable?
        do {
            let reply = try await client.turn(executable: approved.path, arguments: line.arguments, directory: folder, environment: environment,
                message: resuming == nil ? job.brief : JobDoors.resumed(job.brief), peerCredential: "", mcpServers: [], line: line,
                conversationID: resuming, approvedExecutable: approved, timeout: nil,
                permission: { request in
                    await JobDoorBroker.answer(Self.ask(request), job: job, record: record, cwd: folder, out: out, dataRoot: dataRoot)
                },
                update: { event in if let note = Self.note(event) { out.send(.working(note: note)) } },
                sessionOpened: { session in
                    guard opened.first(session) else { return }
                    out.send(.started(session: session))
                    await JobDoorLive.shared.hold(Self.door + ":" + session, run)
                    out.send(.working(note: "Working in \(folder.path)."))
                })
            switch reply.stopReason {
            case "cancelled": outcome = .stopped("\(name) cancelled its turn")
            case "refusal": outcome = .failed("\(name) refused the job")
            case "end_turn":
                deliverable = JobDeliverable(artifacts: [], report: reply.text.isEmpty ? nil : reply.text, model: reply.model)
                let made = try await JobDoorArtifacts.deliverable(job, since: record.startedAt, report: reply.text.isEmpty ? nil : reply.text,
                                                                  model: reply.model)
                deliverable = made
                outcome = made.inventoryFailure.map(JobOutcome.failed) ?? .finished
            default: outcome = .failed("\(name)'s turn ended without completion: \(reply.stopReason)")
            }
        } catch {
            outcome = .failed("\(name)'s session: " + ((error as? AgentACPClient.Failure)?.localizedDescription ?? error.localizedDescription))
        }
        // A cancelled turn already sent session/cancel and closed its program; a finished one closes here. Either way the session stays the agent's.
        await client.close()
        if let session = opened.session { await JobDoorLive.shared.release(Self.door + ":" + session, run) }
        guard !Task.isCancelled else { return out.stopped("its job was stopped") }
        if let deliverable { out.send(.deliverable(deliverable)) }
        out.send(.ended(outcome))
    }

    /// ACP's own tool kinds, as the broker reads them. An edit names its files in `locations` or its diff; one that names none is the person's to decide.
    static func ask(_ request: JSONValue) -> JobAsk {
        let call = request.objectValue?["toolCall"]?.objectValue ?? [:]
        let title = call["title"]?.stringValue ?? call["kind"]?.stringValue ?? "a tool call"
        // An edit names its files in `locations`, or in its diff content (ACP's `diff` carries the path it changes).
        let located = (call["locations"]?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
        let diffed = (call["content"]?.arrayValue ?? []).compactMap { item -> String? in
            guard let item = item.objectValue, item["type"]?.stringValue == "diff" else { return nil }
            return item["path"]?.stringValue
        }
        let paths = located + diffed.filter { !located.contains($0) }
        let kind: JobAsk.Kind = switch call["kind"]?.stringValue {
        case "read"?, "search"?, "think"?: .read
        case "edit"?: .write
        case "fetch"?: .network
        default: .other
        }
        return JobAsk(kind: kind, paths: paths, title: title, request: request)
    }

    static func note(_ event: JSONValue) -> String? {
        let update = event.objectValue ?? [:]
        switch update["sessionUpdate"]?.stringValue {
        case "tool_call"?: return update["title"]?.stringValue
        case "plan"?:
            let steps = (update["entries"]?.arrayValue ?? []).compactMap(\.objectValue)
            let current = steps.first { $0["status"]?.stringValue == "in_progress" } ?? steps.first { $0["status"]?.stringValue == "pending" }
            return current?["content"]?.stringValue.map { "Plan: " + $0 }
        default: return nil
        }
    }

    /// The session the client opened, told once.
    final class OpenedSession: Sendable {
        private let value = OSAllocatedUnfairLock<String?>(initialState: nil)
        var session: String? { value.withLock { $0 } }
        func first(_ session: String) -> Bool {
            value.withLock { current in
                guard current == nil else { return false }
                current = session
                return true
            }
        }
    }
}
