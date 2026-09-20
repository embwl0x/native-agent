import Foundation
import Network
import Testing
import ChatOrchestration
@testable import NativeAgentApp

@Suite(.timeLimit(.minutes(1)))
struct AgentContactRouteAuthenticationTests {
    @Test(arguments: [false, true])
    func authenticatedContactKeepsItsIdentityThroughMessageAndReply(mcp: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contact-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var contact = AgentPeerContact(name: "Test contact", endpoint: URL(string: "https://example.com")!, transport: .a2a)
        contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
        try AgentPeerStore(dataRoot: root).upsert(contact)
        let owner = contact.id
        let tasks = AgentContactTasks(dataRoot: root) { turn, _ in
            #expect(turn.principal.peerID == owner)
            #expect(turn.principal.displayName == "Test contact")
            return .init(state: .completed, parts: [.text("Retained answer")])
        }
        let bridge = ClaudeBridge()
        // Exercise the real route with an isolated address book and credential
        // reader. Never start the app listener or consult its live data root.
        func post(_ path: String, _ object: [String: Any]) async throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: object)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            defer { listener.cancel() }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                _ = bridge.routeAgentContact(conn: connection, method: "POST", path: path,
                    headers: ["authorization": "Bearer contact-key", "content-type": "application/json",
                              "accept": "application/json, text/event-stream", "mcp-protocol-version": "2025-11-25"], body: body,
                    dataRoot: root, liveToken: "listener-key", readCredential: { _ in "contact-key" }, tasks: tasks)
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
            let port = try #require(listener.port)
            let client = URLSession(configuration: .ephemeral)
            defer { client.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
            request.timeoutInterval = 5
            let (data, response) = try await client.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": "call", "method": "tools/call",
             "params": ["name": tool, "arguments": arguments]]
        }
        let requestID = UUID().uuidString.lowercased()
        let sent = try await post(mcp ? "/agent/mcp" : "/agent/message", mcp
            ? call("agent_message", ["text": "Hello", "request_id": requestID])
            : ["text": "Hello", "request_id": requestID])
        let receipt = mcp ? try #require((sent["result"] as? [String: Any])?["structuredContent"] as? [String: Any]) : sent
        let session = try #require(receipt[mcp ? "session_id" : "sessionId"] as? String)
        let context = mcp ? session : String(session.dropFirst(ClaudeBridge.genericAgentSessionPrefix(owner: owner).count))
        let finished = try await tasks.settled("na3.\(context).\(requestID)", owner: owner)
        #expect(finished.state == .completed)
        let arguments: [String: Any] = ["request_id": requestID, "session_id": session]
        let read = try await post(mcp ? "/agent/mcp" : "/agent/reply", mcp ? call("agent_reply", arguments) : arguments)
        let reply = mcp ? try #require((read["result"] as? [String: Any])?["structuredContent"] as? [String: Any]) : read
        #expect(reply["reply"] as? String == "Retained answer")
        #expect(reply["session_id"] as? String == session)
    }

    @Test func contactAuthenticationDoesNotInterceptBuilderRoutes() {
        let bridge = ClaudeBridge()
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        defer { connection.cancel() }
        for path in ["/claude/message", "/codex/message", "/omp/state"] {
            #expect(!bridge.routeAgentContact(conn: connection, method: "POST", path: path,
                                             headers: [:], body: Data()))
        }
    }

    @Test("direct inbound route refuses unauthenticated work even without a listener gate",
          arguments: [[:], ["authorization": ""], ["authorization": "Bearer invalid"]])
    func refusesBeforeWork(headers: [String: String]) async throws {
        // Never start the real bridge: doing so would publish discovery files.
        let bridge = ClaudeBridge()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            // Call the production route directly, without reading/authenticating HTTP.
            #expect(bridge.routeAgentContact(conn: connection, method: "POST", path: "/a2a",
                headers: headers,
                body: Data(#"{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"messageId":"auth-regression","role":"user","parts":[{"kind":"text","text":"must not run"}]}}}"#.utf8)))
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
        let port = try #require(listener.port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port.rawValue)/a2a")!)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        // An unstarted/stopped bridge must refuse before resolving a principal,
        // parsing the valid send, or initializing the production task runtime.
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["error": "server_stopping"])
        #expect(bridge.recentEventPayloads().isEmpty)
    }
}
