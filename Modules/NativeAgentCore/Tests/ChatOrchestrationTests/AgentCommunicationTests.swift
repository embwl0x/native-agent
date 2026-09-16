import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentCommunicationTests {
    @Test func handlerNegotiatesA2AAndPreservesTaskAcrossRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-handler-a2a-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peers = ["a2a-card", "mismatch-card", "cross-card"].map {
            AgentPeerContact(name: $0, endpoint: URL(string: "https://fixture.example/" + $0)!, transport: .a2a)
        }
        for peer in peers { try store.upsert(peer) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        try await AgentPeerHTTP.$fixtureConfiguration.withValue({
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AgentHandlerFixtureProtocol.self]
            return config
        }) {
            let input: [String: JSONValue] = ["agent": .string("peer:" + peers[0].id), "text": .string("Hello"), "conversation_id": .string("conversation")]
            let sent = try await dispatcher.impl_agentCommunication(tool: "agent_message", input: input, surface: "chat")
            guard case .object(let fields) = sent else { Issue.record("Missing A2A result"); return }
            #expect(fields["status"] == .string("working"))
            #expect(fields["task_id"] == .string("task-1"))
            #expect(fields["completed"] == .bool(false))
            let read = try await dispatcher.impl_agentCommunication(tool: "agent_read", input: ["agent": .string("peer:" + peers[0].id), "task_id": .string("task-1")], surface: "chat")
            guard case .object(let completed) = read else { Issue.record("Missing A2A read"); return }
            #expect(completed["completed"] == .bool(true))
            #expect(completed["task_id"] == .string("task-1"))
            var mismatched = input
            mismatched["agent"] = .string("peer:" + peers[1].id)
            let mismatch = try await dispatcher.impl_agentCommunication(tool: "agent_message", input: mismatched, surface: "chat")
            guard case .object(let unknown) = mismatch else { Issue.record("Missing mismatch result"); return }
            #expect(unknown["status"] == .string("outcome_unknown"))
            #expect(unknown["conversation_id"] == .string("conversation"))
            var cross = input
            cross["agent"] = .string("peer:" + peers[2].id)
            await #expect(throws: (any Error).self) {
                try await dispatcher.impl_agentCommunication(tool: "agent_message", input: cross, surface: "chat")
            }
        }
    }
    @Test func handlerUsesNativeEnqueueAndExactReceiptWithoutLiveNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-handler-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = AgentPeerContact(name: "Fixture", endpoint: URL(string: "https://fixture.example/native")!, transport: .nativeAgent)
        try AgentPeerStore(dataRoot: root).upsert(peer)
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        let id = UUID().uuidString
        try await AgentPeerHTTP.$fixtureConfiguration.withValue({
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AgentHandlerFixtureProtocol.self]
            return config
        }) {
            let sent = try await dispatcher.impl_agentCommunication(tool: "agent_message", input: [
                "agent": .string("peer:" + peer.id), "text": .string("Hello"),
                "message_id": .string(id), "conversation_id": .string("conversation")], surface: "chat")
            guard case .object(let sentFields) = sent else { Issue.record("Missing send result"); return }
            #expect(sentFields["status"] == .string("enqueued"))
            #expect(sentFields["message_id"] == .string(id))
            let received = try await dispatcher.impl_agentCommunication(tool: "agent_read", input: [
                "agent": .string("peer:" + peer.id), "message_id": .string(id), "conversation_id": .string("conversation")], surface: "chat")
            guard case .object(let receivedFields) = received else { Issue.record("Missing read result"); return }
            #expect(receivedFields["status"] == .string("ok"))
            #expect(receivedFields["message_id"] == .string(id))
            #expect(receivedFields["untrusted_remote_data"] == .bool(true))
        }
    }

    @Test func omittedNativeConversationIsFreshAndRecoverableAfterLostAck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = AgentPeerContact(name: "Fixture", endpoint: URL(string: "https://fixture.example/lost")!, transport: .nativeAgent)
        try AgentPeerStore(dataRoot: root).upsert(peer)
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        try await AgentPeerHTTP.$fixtureConfiguration.withValue({
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AgentHandlerFixtureProtocol.self]
            return config
        }) {
            var conversations: Set<String> = []
            for _ in 0..<2 {
                let id = UUID().uuidString
                let result = try await dispatcher.impl_agentCommunication(tool: "agent_message", input: [
                    "agent": .string("peer:" + peer.id), "text": .string("Hello"), "message_id": .string(id)], surface: "chat")
                guard case .object(let fields) = result, case .string(let conversation)? = fields["conversation_id"] else {
                    Issue.record("Missing retained session"); return
                }
                #expect(UUID(uuidString: conversation) != nil)
                conversations.insert(conversation)
                #expect(fields["status"] == .string("outcome_unknown"))
                #expect(fields["read_with"] == AgentConversationRouting.readLocator(agent: "peer:" + peer.id,
                    message: .string(id), conversation: .string(conversation), task: nil))
                let recovered = try await dispatcher.impl_agentCommunication(tool: "agent_read", input: [
                    "agent": .string("peer:" + peer.id), "message_id": .string(id), "conversation_id": .string(conversation)], surface: "chat")
                guard case .object(let reply) = recovered else { Issue.record("Missing reply"); return }
                #expect(reply["status"] == .string("ok"))
                #expect(reply["conversation_id"] == .string(conversation))
            }
            #expect(conversations.count == 2)
        }
    }

    @Test func handlerPreservesCorrelationWhenPeerEchoIsWrong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-handler-bad-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = AgentPeerContact(name: "Fixture", endpoint: URL(string: "https://fixture.example/wrong")!, transport: .nativeAgent)
        try AgentPeerStore(dataRoot: root).upsert(peer)
        let id = UUID().uuidString
        try await AgentPeerHTTP.$fixtureConfiguration.withValue({
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AgentHandlerFixtureProtocol.self]
            return config
        }) {
            let result = try await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false).impl_agentCommunication(tool: "agent_message", input: [
                "agent": .string("peer:" + peer.id), "text": .string("Hello"),
                "message_id": .string(id), "conversation_id": .string("conversation")], surface: "chat")
            guard case .object(let fields) = result else { Issue.record("Missing result"); return }
            #expect(fields["status"] == .string("outcome_unknown"))
            #expect(fields["message_id"] == .string(id))
            #expect(fields["remote_evidence"] == nil)
        }
    }
    @Test func interfaceCannotForwardCredentialAcrossOriginsOrUnsupportedAuth() throws {
        let card = URL(string: "https://peer.example/card")!
        let elsewhere = AgentA2AWire.Interface(endpoint: URL(string: "https://other.example/rpc")!, version: "1.0", binding: "JSONRPC")
        #expect(throws: (any Error).self) { try SwiftToolDispatcher.peerAuthorizeInterface(elsewhere, cardURL: card, hasCredential: true) }
        let bearer = AgentA2AWire.Interface(endpoint: URL(string: "https://peer.example:443/rpc")!, version: "1.0", binding: "JSONRPC",
            securityRequirements: .array([.object(["auth": .array([])])]),
            securitySchemes: .object(["auth": .object(["type": .string("http"), "scheme": .string("bearer")])]))
        try SwiftToolDispatcher.peerAuthorizeInterface(bearer, cardURL: card, hasCredential: true)
        #expect(throws: (any Error).self) { try SwiftToolDispatcher.peerAuthorizeInterface(bearer, cardURL: card, hasCredential: false) }
        let apiKey = AgentA2AWire.Interface(endpoint: card, version: "1.0", binding: "JSONRPC",
            securityRequirements: .array([.object(["auth": .array([])])]),
            securitySchemes: .object(["auth": .object(["type": .string("apiKey")])]))
        #expect(throws: (any Error).self) { try SwiftToolDispatcher.peerAuthorizeInterface(apiKey, cardURL: card, hasCredential: true) }
    }

    @Test func remoteEchoRedactionIncludesKeysAndNestedParts() {
        let value: JSONValue = .object(["synthetic-token": .array([.object(["text": .string("echo synthetic-token")])])])
        #expect(SwiftToolDispatcher.peerRedact(value, token: "synthetic-token") ==
            .object(["[redacted]": .array([.object(["text": .string("echo [redacted]")])])]))
    }

    @Test func configureIsOnlyConfigurationAndSyntheticCredentialsAreDenied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-communication-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        let args: [String: JSONValue] = ["name": .string("Fixture"), "endpoint": .string("http://127.0.0.1:9"), "transport": .string("nativeAgent")]
        let result = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: args, surface: "chat")
        guard case .object(let object) = result else { Issue.record("Expected configuration result"); return }
        #expect(object["status"] == .string("configured"))
        #expect(try AgentPeerStore(dataRoot: root).list().count == 1)
        var withToken = args
        withToken["bearer_token"] = .string("synthetic-not-a-real-credential")
        await #expect(throws: (any Error).self) {
            try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: withToken, surface: "chat")
        }
        #expect(try AgentPeerStore(dataRoot: root).list().count == 1)
        var unsupported = args
        unsupported["peer_id"] = .string(UUID().uuidString)
        await #expect(throws: (any Error).self) {
            try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: unsupported, surface: "chat")
        }
    }
}

private final class AgentHandlerFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        if url.path.contains("lost"), url.lastPathComponent == "message" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < 65536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let input = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let output: [String: Any]
        switch url.lastPathComponent {
        case "a2a-card", "mismatch-card", "cross-card":
            let endpoint = url.lastPathComponent == "cross-card" ? "https://other.example/rpc" : "https://fixture.example/" + (url.lastPathComponent == "mismatch-card" ? "mismatch-rpc" : "rpc")
            output = ["protocolVersion": "0.3.0", "url": endpoint]
        case "rpc", "mismatch-rpc":
            if url.host != "fixture.example" { Issue.record("Cross-origin request escaped preflight") }
            output = ["jsonrpc": "2.0", "id": input["id"] ?? "missing", "result": [
                "kind": "task", "id": "task-1", "contextId": url.lastPathComponent == "mismatch-rpc" ? "wrong-context" : "conversation",
                "status": ["state": input["method"] as? String == "tasks/get" ? "completed" : "working"]]]
        case "card": output = ["protocol": "nativeagent-bridge", "version": "1.0"]
        case "message": output = ["status": "ok", "ack": "enqueued", "requestId": url.path.contains("wrong") ? "wrong-id" : (input["request_id"] ?? "missing"), "sessionId": input["sessionId"] ?? "active"]
        case "reply": output = ["status": "ok", "request_id": input["request_id"] ?? "missing", "session_id": input["session_id"] ?? "missing", "reply": "Peer answer", "original_status": "ok"]
        default: output = ["error": "unexpected_fixture_path"]
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: output))
        client?.urlProtocolDidFinishLoading(self)
    }
}
