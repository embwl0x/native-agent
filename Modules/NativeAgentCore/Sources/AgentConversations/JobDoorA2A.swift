import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `JobDoorA2A.swift` | `A2AJobDoor`: a job as an A2A task, followed until it ends; its returned artifacts are written into the job's folder |

/// A remote agent takes a job as an A2A task. The brief is sent once; the task is then read until it ends, with no deadline. What it returns as
/// artifacts is kept: written into the job's folder (when the job may write there) and reported as the deliverable, never stripped. Its words are its report.
struct A2AJobDoor: JobRunner {
    let dataRoot: URL
    static let door = "a2a"

    struct Link: Sendable {
        let interface: AgentA2AWire.Interface
        let token: String?
    }

    func serves(_ contact: AgentPeerContact) -> Bool { contact.transport == .a2a && contact.ability == nil }

    func start(_ job: JobStart) async throws -> AsyncThrowingStream<JobEvent, Error> {
        let link = try await Self.link(job.contact)
        let request: AgentA2AWire.Request
        do {
            request = try AgentA2AWire.messageRequest(text: job.brief, messageID: UUID().uuidString.lowercased(), interface: link.interface,
                                                      requestID: UUID().uuidString.lowercased(), streaming: false)
        } catch { throw JobRefusal("\(job.contact.name)'s message could not be built: \(error.localizedDescription). Nothing was sent.") }
        // From here the brief may have reached it: a failure is the stem's to record, never a refusal.
        let first = try await Self.exchange(request, link: link, contact: job.contact, task: nil)
        return follow(job, from: first, link: link)
    }

    func resume(_ job: JobStart, session: String) async throws -> AsyncThrowingStream<JobEvent, Error> {
        let link = try await Self.link(job.contact)
        let request: AgentA2AWire.Request
        do { request = try AgentA2AWire.taskRequest(taskID: session, interface: link.interface) }
        catch { throw JobRefusal("Task \(session) could not be asked for: \(error.localizedDescription). Nothing was sent.") }
        let first = try await Self.exchange(request, link: link, contact: job.contact, task: session)
        return follow(job, from: first, link: link)
    }

    func cancel(session: String) async throws { await JobDoorLive.shared.stop(Self.door + ":" + session) }

    /// The contact's checked card and key, or why nothing could be sent.
    static func link(_ peer: AgentPeerContact) async throws -> Link {
        let token: String?
        do { token = peer.credentialKey == nil ? nil : try AgentPeerCredentials.read(peerID: peer.id) }
        catch { throw JobRefusal("\(peer.name)'s key could not be read: \(error.localizedDescription). Nothing was sent.") }
        if peer.credentialKey != nil, token == nil {
            throw JobRefusal("\(peer.name)'s key is not in Keychain. Connect it again with the key it gives you. Nothing was sent.")
        }
        let checked = await AgentPeerDiscovery.a2aCheck(conversation: AgentConversationContext(), peer, bearerToken: token, sending: true)
        guard let interface = checked.interface else {
            throw JobRefusal(checked.receipt["detail"]?.stringValue ?? "\(peer.name)'s agent card could not be checked. Nothing was sent.")
        }
        return Link(interface: interface, token: token)
    }

    static func exchange(_ request: AgentA2AWire.Request, link: Link, contact: AgentPeerContact, task: String?) async throws -> AgentA2AWire.Result {
        let response = try await AgentPeerHTTP.send(conversation: AgentConversationContext(), request, bearerToken: link.token)
        guard (200..<300).contains(response.statusCode), let payload = response.json else {
            throw JobDoorFailure("\(contact.name) answered HTTP \(response.statusCode) with no readable task")
        }
        return try AgentA2AWire.normalizeResponse(payload, interface: link.interface, expectedRequestID: request.requestID, expectedTaskID: task)
    }

    private func follow(_ job: JobStart, from first: AgentA2AWire.Result, link: Link) -> AsyncThrowingStream<JobEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<JobEvent, Error>.makeStream()
        let out = JobDoorOut(continuation, contact: job.contact)
        let run = JobDoorRun()
        run.drive { await drive(job, from: first, link: link, out: out, run: run) }
        continuation.onTermination = { _ in run.cancel() }
        return stream
    }

    private func drive(_ job: JobStart, from first: AgentA2AWire.Result, link: Link, out: JobDoorOut, run: JobDoorRun) async {
        let name = job.contact.name
        var result = first
        let task = first.kind == "task" ? first.taskID : nil
        if let task {
            out.send(.started(session: task))
            await JobDoorLive.shared.hold(Self.door + ":" + task, run)
        }
        var said = "", unreadable = ""
        var pause: Duration = .seconds(5)
        while let task, !result.terminal {
            if result.state != said {
                said = result.state
                if result.needsInput || result.needsAuthentication {
                    let asks = result.needsInput ? "more input" : "access"
                    out.send(.needsYou(JobPermissionRequest(id: task, title: "\(name) asks for \(asks): " + String(result.text.prefix(240)),
                                                            subject: "Answer with agent.message, task_id \(task)")))
                }
            }
            if !(result.needsInput || result.needsAuthentication) { out.send(.working(note: "Its task is \(result.state).")) }
            do { try await Task.sleep(for: pause) } catch { break }
            pause = min(pause * 2, .seconds(60))
            do {
                result = try await Self.exchange(try AgentA2AWire.taskRequest(taskID: task, interface: link.interface), link: link, contact: job.contact,
                                                 task: task)
                unreadable = ""
            } catch {
                guard !Task.isCancelled else { break }
                if error.localizedDescription != unreadable {
                    unreadable = error.localizedDescription
                    out.send(.working(note: "Its task could not be read (\(unreadable)); reading it again."))
                }
            }
        }
        guard !Task.isCancelled else {
            // The agent's stop reaches the remote task through its own cancel.
            if let task {
                // The stop itself must not be cancelled with the run it ends.
                let sent = await Task.detached {
                    try await Self.exchange(try AgentA2AWire.cancelRequest(taskID: task, interface: link.interface), link: link,
                                            contact: job.contact, task: task)
                }.result
                if case .failure(let error) = sent {
                    nativeLog("A2A job door: the cancel of task %@ was not confirmed: %@", task, error.localizedDescription)
                }
                await JobDoorLive.shared.release(Self.door + ":" + task, run)
            }
            return out.stopped("its job was stopped")
        }
        if let task { await JobDoorLive.shared.release(Self.door + ":" + task, run) }
        switch result.state {
        case "completed", "reply":
            let kept = Self.keep(result, interface: link.interface, job: job)
            if let gap = kept.gap { out.send(.working(note: gap)) }
            out.send(.deliverable(JobDeliverable(artifacts: kept.files, report: result.text.isEmpty ? nil : result.text, model: nil)))
            out.send(.ended(.finished))
        case "canceled": out.send(.ended(.stopped("\(name) cancelled its task")))
        default: out.send(.ended(.failed("\(name)'s task ended \(result.state)" + (result.text.isEmpty ? "" : ": " + String(result.text.prefix(500))))))
        }
    }

    /// Writes what the task returned into the job's folder: each file part as its own file, an artifact's text as one Markdown file, its data as JSON.
    /// Nothing is overwritten. A job that may not write keeps the words in its report and names what was not written.
    static func keep(_ result: AgentA2AWire.Result, interface: AgentA2AWire.Interface, job: JobStart) -> (files: [URL], gap: String?) {
        var pieces: [(name: String, data: Data)] = [], skipped: [String] = []
        func canonical(_ value: JSONValue) -> [String: JSONValue]? {
            do { return try AgentA2AWire.canonicalPart(value, version: interface.version).objectValue }
            catch { skipped.append("an unreadable part (\(error.localizedDescription))"); return nil }
        }
        for value in result.parts {
            guard let part = canonical(value), let raw = part["raw"]?.stringValue else { continue }
            guard let bytes = Data(base64Encoded: raw) else { skipped.append("a file part that is not base64"); continue }
            pieces.append((part["filename"]?.stringValue ?? "returned-file", bytes))
        }
        for (index, value) in result.artifacts.enumerated() {
            let artifact = value.objectValue ?? [:]
            let title = artifact["name"]?.stringValue ?? artifact["artifactId"]?.stringValue ?? "artifact-\(index + 1)"
            var text: [String] = [], data: [JSONValue] = []
            for value in artifact["parts"]?.arrayValue ?? [] {
                guard let part = canonical(value) else { continue }
                if let words = part["text"]?.stringValue { text.append(words) }
                else if let raw = part["raw"]?.stringValue {
                    guard let bytes = Data(base64Encoded: raw) else { skipped.append("a file part of \(title) that is not base64"); continue }
                    pieces.append((part["filename"]?.stringValue ?? title, bytes))
                } else if let value = part["data"] { data.append(value) }
                else if let url = part["url"]?.stringValue { skipped.append("\(title) at \(url), which was not fetched") }
            }
            if !text.isEmpty { pieces.append((title + ".md", Data(text.joined(separator: "\n\n").utf8))) }
            if !data.isEmpty {
                do { pieces.append((title + ".json", try (data.count == 1 ? data[0] : .array(data)).serializedData(pretty: true))) }
                catch { skipped.append("the data of \(title) (\(error.localizedDescription))") }
            }
        }
        guard !pieces.isEmpty else { return ([], skipped.isEmpty ? nil : "Not kept: " + skipped.joined(separator: "; ") + ".") }
        guard job.envelope.writes, let folder = job.folder else {
            let names = pieces.map(\.name).joined(separator: ", ")
            return ([], "Returned \(pieces.count) file\(pieces.count == 1 ? "" : "s") (\(names)) that this job may not write; the words are in its report.")
        }
        var files: [URL] = []
        for piece in pieces {
            let url = unique(safe(piece.name), in: folder)
            do { try piece.data.write(to: url, options: [.withoutOverwriting]); files.append(url) }
            catch { skipped.append("\(piece.name) (\(error.localizedDescription))") }
        }
        return (files, skipped.isEmpty ? nil : "Not kept: " + skipped.joined(separator: "; ") + ".")
    }

    /// A returned name as one plain file name: no folders, no leading dots, nothing a path could read as a step.
    static func safe(_ name: String) -> String {
        let plain = name.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last.map(String.init) ?? ""
        let kept = String(plain.filter { !$0.isNewline && $0.asciiValue.map { $0 >= 32 } ?? true }.drop { $0 == "." || $0 == " " }.prefix(120))
        return kept.isEmpty ? "returned-file" : kept
    }

    static func unique(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var count = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(base + " \(count)" + (ext.isEmpty ? "" : "." + ext))
            count += 1
        }
        return url
    }
}
