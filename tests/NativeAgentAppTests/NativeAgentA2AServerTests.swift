import Foundation
import Network
import Testing
import ChatOrchestration
import PersistenceCore
import ApprovalInbox
@testable import NativeAgentApp

/// Actual HTTP + SSE on an ephemeral loopback port. Only the turn producer is
/// replaced; parsing, task ownership, replay claims, cancellation and framing
/// are production code. Every persistent write stays under a temporary HOME.
private final class A2ALoopServer: BridgeHTTPServer, @unchecked Sendable {
    let root: URL
    let tasks: AgentContactTasks
    let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(runner: @escaping AgentContactTasks.Runner) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-home-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tasks = AgentContactTasks(dataRoot: root, runner: runner)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: .global())
            BridgeCore.readRequest(connection, buffered: Data(), maxBodyBytes: 4 * 1024 * 1024, server: self)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/a2a")!
    }

    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: root)
    }

    func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        Task {
            let response = await AgentContactA2AEndpoint(tasks: tasks).handle(body, principal: .anonymous)
            switch response {
            case .json(let object):
                let data = try! JSONSerialization.data(withJSONObject: object)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(data)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            case .stream(let id, let events, let version): AgentContactSSE.write(conn, id: id, events: events, version: version)
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct NativeAgentA2AServerTests {
    @Test func textOnlyNegotiationSurvivesStreamingAndPolling() async throws {
        let server = try A2ALoopServer { _, emit in
            await emit(.text("draft"))
            return .init(state: .completed, parts: [.text("reply"), .data(.object(["answer": .int(42)]), metadata: .object([:])),
                .file(name: "image.png", mediaType: "image/png", bytes: Data([1]), metadata: .object([:])),
                .file(name: "result.txt", mediaType: "text/plain", bytes: Data("written".utf8), metadata: .object([:]))])
        }
        defer { server.stop() }
        let url = try await server.start(), client = session()
        defer { client.invalidateAndCancel() }
        var params = message()
        params["configuration"] = ["acceptedOutputModes": ["text/plain"]]
        let (bytes, _) = try await client.bytes(for: request(url, body("message/stream", params)))
        var taskID: String?
        for try await line in bytes.lines {
            guard let event = try frame(line) else { continue }
            taskID = taskID ?? (event["taskId"] as? String) ?? (event["id"] as? String)
            if let artifact = event["artifact"] as? [String: Any], let parts = artifact["parts"] as? [[String: Any]] {
                #expect(parts.allSatisfy { $0["kind"] as? String == "text" })
            }
        }
        let fetched = try await rpc(url, body("tasks/get", ["id": try #require(taskID)]), session: client)
        let task = try #require(fetched["result"] as? [String: Any])
        let artifacts = try #require(task["artifacts"] as? [[String: Any]])
        let parts = try #require(artifacts.first?["parts"] as? [[String: Any]])
        #expect(parts.compactMap { $0["kind"] as? String } == ["text", "text"])
        #expect(parts.compactMap { $0["text"] as? String } == ["reply", "written"])
    }

    @Test func permissionCardsOwnTaskProgress() async throws {
        for decision in [ApprovalDecision.approved, .denied, .canceled] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-approval-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let inbox = SwiftNativeApprovalInbox(root: root)
            let card = try await inbox.create(.object([
                "title": .string("Write fixture"), "action": .string("chat.tool"),
                "risk": .string("medium"), "reason": .string("fixture"), "payload": .object([:])
            ]))
            let tasks = AgentContactTasks(dataRoot: root) { _, emit in
                await emit(.approval(card.id))
                await emit(.waiting)
                return .init(state: .inputRequired, parts: [.text("Waiting")])
            }
            guard case .send(var send) = NativeAgentA2AWire.parse(try body("message/send", message())) else {
                Issue.record("parse failed"); return
            }
            let task = try await tasks.send(send, principal: .anonymous, digest: "first")
            let waiting = try await tasks.settled(task.id, owner: AgentBridgePrincipal.anonymous.id)
            #expect(waiting.state == .inputRequired)
            send = .init(rpcID: "next", context: send.context, request: UUID().uuidString,
                         text: "continue", clientMessageID: UUID().uuidString, continuedTask: task.id)
            do {
                _ = try await tasks.send(send, principal: .anonymous, digest: "second")
                Issue.record("peer bypassed pending card")
            } catch let error as AgentContactFailure { #expect(error.code == -32004) }
            #expect(try await tasks.get(task.id, owner: AgentBridgePrincipal.anonymous.id).state == .inputRequired)
            _ = try await inbox.resolve(card.id, decision: decision, provenance: .local(decidedBy: "fixture"))
            let expected: AgentContactTaskState = decision == .approved ? .working : .canceled
            for _ in 0..<100 {
                if try await tasks.get(task.id, owner: AgentBridgePrincipal.anonymous.id).state == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await tasks.get(task.id, owner: AgentBridgePrincipal.anonymous.id).state == expected)
            if decision == .approved {
                _ = try await inbox.annotateExecution(card.id,
                    executedAction: .object(["status": .string("succeeded"), "resultClass": .string("succeeded")]), detail: "Written")
                NotificationCenter.default.post(name: .chatTurnCompleted, object: "fixture")
                for _ in 0..<100 {
                    if try await tasks.get(task.id, owner: AgentBridgePrincipal.anonymous.id).state == .completed { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(try await tasks.get(task.id, owner: AgentBridgePrincipal.anonymous.id).state == .completed)
            }
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }
    private func body(_ method: String, _ params: [String: Any], id: String = "rpc") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params], options: [.sortedKeys])
    }
    private func message(_ parts: [[String: Any]] = [["kind": "text", "text": "hello"]], id: String = UUID().uuidString) -> [String: Any] {
        ["message": ["kind": "message", "role": "user", "messageId": id, "parts": parts]]
    }
    private func request(_ url: URL, _ body: Data) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
    private func rpc(_ url: URL, _ bytes: Data, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request(url, bytes))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func frame(_ line: String) throws -> [String: Any]? {
        guard line.hasPrefix("data: ") else { return nil }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
        #expect(envelope["jsonrpc"] as? String == "2.0")
        return envelope["result"] as? [String: Any]
    }
    private func state(_ object: [String: Any]) -> String? { (object["status"] as? [String: Any])?["state"] as? String }

    @Test func sendStreamDropResubscribeCancelAndFileRoundTrip() async throws {
        let server = try A2ALoopServer { turn, emit in
            await emit(.working)
            await emit(.text("first "))
            // Real time for a client to drop/reconnect or cancel the producer.
            try await Task.sleep(for: .milliseconds(400))
            await emit(.text("second"))
            var output: [AgentContactPart] = [.text("first second")]
            for part in turn.parts where part.isAttachment {
                if case .file = part {
                    let attachment = try #require(part.attachment)
                    #expect(attachment.path == nil)
                    output.append(try AgentContactPart.output(attachment, taskID: turn.taskID))
                } else { output.append(part) }
            }
            return .init(state: .completed, parts: output)
        }
        defer { server.stop() }
        let url = try await server.start()
        let client = session(); defer { client.invalidateAndCancel() }
        let file = Data("a file from another agent\n".utf8)
        let params = message([
            ["kind": "text", "text": "read this"],
            ["kind": "file", "file": ["name": "sample.txt", "mimeType": "text/plain", "bytes": file.base64EncodedString()], "metadata": ["source": "fixture"]],
            ["kind": "data", "data": ["answer": 42], "metadata": ["source": "fixture-data"]]
        ])
        let sendBody = try body("message/send", params)
        let sent = try await rpc(url, sendBody, session: client)
        let initial = try #require(sent["result"] as? [String: Any])
        let taskID = try #require(initial["id"] as? String)
        #expect(state(initial) == "submitted")
        let replay = try await rpc(url, sendBody, session: client)
        #expect((replay["result"] as? [String: Any])?["id"] as? String == taskID)

        let droppingClient = session()
        let (bytes, response) = try await droppingClient.bytes(for: request(url, body("tasks/resubscribe", ["id": taskID])))
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        var sawPartial = false
        for try await line in bytes.lines {
            if let event = try frame(line), event["kind"] as? String == "task" {
                #expect(state(event) != "completed"); sawPartial = true; break
            }
        }
        #expect(sawPartial)
        droppingClient.invalidateAndCancel() // This MUST NOT cancel the task.
        let (resumed, _) = try await client.bytes(for: request(url, body("tasks/resubscribe", ["id": taskID])))
        var completed = false
        var artifacts: [[String: Any]] = []
        for try await line in resumed.lines {
            guard let event = try frame(line) else { continue }
            if event["kind"] as? String == "artifact-update", event["lastChunk"] as? Bool == true {
                artifacts = (event["artifact"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            }
            if state(event) == "completed" { completed = true }
        }
        #expect(completed)
        let returnedFile = try #require(artifacts.first { $0["kind"] as? String == "file" })
        let returned = try #require(returnedFile["file"] as? [String: Any])
        #expect(returned["mimeType"] as? String == "text/plain")
        #expect(Data(base64Encoded: returned["bytes"] as? String ?? "") == file)
        #expect((returnedFile["metadata"] as? [String: String])?["source"] == "agent")
        #expect((artifacts.first { $0["kind"] as? String == "data" }?["data"] as? [String: Int])?["answer"] == 42)
        let fetched = try await rpc(url, body("tasks/get", ["id": taskID]), session: client)
        #expect(state(try #require(fetched["result"] as? [String: Any])) == "completed")

        let (stream, _) = try await client.bytes(for: request(url, body("message/stream", message())))
        var cancellation: [String: Any]?
        var streamStates: [String] = []
        for try await line in stream.lines {
            guard let event = try frame(line) else { continue }
            if let state = state(event) { streamStates.append(state) }
            if cancellation == nil, let id = event["taskId"] as? String, event["kind"] as? String == "artifact-update" {
                cancellation = try await rpc(url, body("tasks/cancel", ["id": id]), session: client)
            }
        }
        #expect(state(try #require(cancellation?["result"] as? [String: Any])) == "canceled")
        #expect(streamStates.last == "canceled")
        #expect(!streamStates.contains("completed"))
    }

    @Test func approvalAndFailedTurnNeverBecomeCompletedAtEndOfStream() async throws {
        let server = try A2ALoopServer { turn, emit in
            await emit(.working)
            if turn.parts.contains(.text("fail")) { throw AgentContactFailure(code: -32603, message: "fixture failure") }
            await emit(.waiting)
            return .init(state: .inputRequired, parts: [.text("Please answer the card")])
        }
        defer { server.stop() }
        let url = try await server.start(), client = session()
        defer { client.invalidateAndCancel() }
        for (text, expected) in [("wait", "input-required"), ("fail", "failed")] {
            let (bytes, _) = try await client.bytes(for: request(url, body("message/stream", message([["kind": "text", "text": text]]))))
            var states: [String] = []
            for try await line in bytes.lines {
                if let value = try frame(line), let state = state(value) { states.append(state) }
            }
            #expect(states.last == expected)
            #expect(!states.contains("completed"))
        }
    }

    @Test func everyProtocolRefusalAndOwnerIsolation() async throws {
        let server = try A2ALoopServer { _, _ in .init(state: .completed, parts: [.text("done")]) }
        defer { server.stop() }
        let url = try await server.start(), client = session()
        defer { client.invalidateAndCancel() }
        let unknownTask = "na3.a2a-\(UUID().uuidString.lowercased()).\(UUID().uuidString.lowercased())"
        let cases: [(Data, Int)] = [
            (Data("{".utf8), -32700), (Data("[]".utf8), -32600),
            (try body("no-such-method", [:]), -32601),
            (try body("message/send", [:]), -32602), (try body("tasks/get", [:]), -32602),
            (try body("tasks/get", ["id": unknownTask]), -32001),
            (try body("tasks/cancel", ["id": unknownTask]), -32001),
            (try body("tasks/resubscribe", ["id": unknownTask]), -32001),
            (try body("tasks/pushNotificationConfig/set", [:]), -32003),
            (try body("tasks/pushNotificationConfig/get", [:]), -32003),
            (try body("tasks/pushNotificationConfig/list", [:]), -32003),
            (try body("tasks/pushNotificationConfig/delete", [:]), -32003),
            (try body("message/send", message([["kind": "file", "file": ["uri": "https://example.com/file"]]])), -32005),
            (try body("message/send", message([["kind": "file", "file": ["uri": "/private/file"]]])), -32602),
            (try body("message/send", message([["kind": "file", "file": ["name": "../a.txt", "mimeType": "text/plain", "bytes": "YQ=="]]])), -32602),
            (try body("message/send", message([["kind": "file", "file": ["name": "a.txt", "mimeType": "text/plain", "bytes": "bad"]]])), -32602),
            (try body("message/send", message([["kind": "file", "file": ["name": "a.sh", "mimeType": "application/x-sh", "bytes": "YQ=="]]])), -32005)
        ]
        for (request, code) in cases {
            let result = try await rpc(url, request, session: client)
            #expect((result["error"] as? [String: Any])?["code"] as? Int == code)
        }
        var params = message(id: "replay-fixture"); params["configuration"] = ["blocking": true]
        let sent = try await rpc(url, body("message/send", params), session: client)
        let id = try #require((sent["result"] as? [String: Any])?["id"] as? String)
        let cancel = try await rpc(url, body("tasks/cancel", ["id": id]), session: client)
        #expect((cancel["error"] as? [String: Any])?["code"] as? Int == -32002)
        var continuation = message()
        var continuedMessage = try #require(continuation["message"] as? [String: Any])
        continuedMessage["taskId"] = id; continuation["message"] = continuedMessage
        let ended = try await rpc(url, body("message/send", continuation), session: client)
        #expect((ended["error"] as? [String: Any])?["code"] as? Int == -32004)
        let conflict = try await rpc(url, body("message/send", message([["kind": "text", "text": "different"]], id: "replay-fixture")), session: client)
        #expect((conflict["error"] as? [String: Any])?["code"] as? Int == -32602)
        let other = AgentBridgePrincipal(id: "other-peer", peerID: nil, elevated: false, displayName: nil)
        let endpoint = AgentContactA2AEndpoint(tasks: server.tasks)
        guard case .json(let denied) = await endpoint.handle(try body("tasks/get", ["id": id]), principal: other) else { Issue.record("owner bypass"); return }
        #expect((denied["error"] as? [String: Any])?["code"] as? Int == -32001)
        guard case .json(let version) = await endpoint.handle(try body("tasks/get", ["id": id]), principal: .anonymous, version: "2.0") else { Issue.record("version bypass"); return }
        #expect((version["error"] as? [String: Any])?["code"] as? Int == -32009)
        // An unavailable authority store is an internal refusal, never a turn.
        try FileManager.default.removeItem(at: server.root)
        try Data("not a directory".utf8).write(to: server.root)
        let unavailable = try await rpc(url, body("message/send", message()), session: client)
        #expect((unavailable["error"] as? [String: Any])?["code"] as? Int == -32603)
    }

    @Test func outputFilesAreBytesAndNeverPathsOrUnverifiedWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-output-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("result.txt")
        let bytes = Data("produced file".utf8)
        try bytes.write(to: path)
        let attachment = ChatOrchestration.MultimodalAttachment(type: "file", base64: "", mime: "text/plain", name: "result.txt", path: path.path)
        let output = try AgentContactPart.output(attachment, taskID: "task")
        let encoded = try JSONSerialization.data(withJSONObject: output.wire03)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(root.path))
        #expect((output.wire03["file"] as? [String: String])?["bytes"] == bytes.base64EncodedString())
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        var unsafe = attachment; unsafe.path = link.path
        #expect(throws: (any Error).self) { try AgentContactPart.output(unsafe, taskID: "task") }
        let inbound = try AgentContactPart.decode03(["kind": "file", "file": ["name": "result.txt", "mimeType": "text/plain", "bytes": bytes.base64EncodedString()], "metadata": ["origin": "peer"]])
        #expect(inbound.attachment?.path == nil)
        #expect((inbound.wire03["metadata"] as? [String: String])?["origin"] == "peer")
    }
}
