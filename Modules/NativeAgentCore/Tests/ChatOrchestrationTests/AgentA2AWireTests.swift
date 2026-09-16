import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentA2AWireTests {
    private let endpoint = URL(string: "https://peer.example/a2a")!
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }
    private func rpc(_ version: String = "1.0") -> AgentA2AWire.Interface {
        .init(endpoint: endpoint, version: version, binding: "JSONRPC")
    }
    private func field(_ value: JSONValue?, _ name: String) -> JSONValue? {
        guard case .object(let object)? = value else { return nil }; return object[name]
    }

    @Test func selectsOnlyAdvertisedSupportedPairsInOrder() throws {
        let card = try json(#"{"supportedInterfaces":[{"url":"https://peer.example/future","protocolBinding":"JSONRPC","protocolVersion":"9.0"},{"url":"https://peer.example/rest","protocolBinding":"HTTP+JSON","protocolVersion":"1.0.2"},{"url":"https://peer.example/rpc","protocolBinding":"JSONRPC","protocolVersion":"1.0"}],"securityRequirements":[{"schemes":{"token":{"list":[]}}}],"securitySchemes":{"token":{"httpAuthSecurityScheme":{"scheme":"Bearer"}}}}"#)
        let selected = try AgentA2AWire.selectInterface(card: card, cardURL: endpoint)
        #expect(selected.endpoint.path == "/rest")
        #expect(selected.version == "1.0")
        #expect(selected.binding == "HTTP+JSON")
        #expect(selected.securityRequirements == field(card, "securityRequirements"))
        #expect(selected.securitySchemes == field(card, "securitySchemes"))
    }

    @Test func rejectsUnknownLegacyVersionRequiredExtensionsAndCredentialURLs() throws {
        for fixture in [
            #"{"protocolVersion":"9.0","url":"https://peer.example","preferredTransport":"JSONRPC"}"#,
            #"{"protocolVersion":"0.3","url":"https://peer.example","capabilities":{"extensions":[{"uri":"https://extension.example","required":true}]}}"#,
            #"{"protocolVersion":"0.3","url":"https://user:secret@peer.example"}"#,
            #"{"protocolVersion":"0.3","url":"file:///tmp/socket"}"#,
            #"{"supportedInterfaces":[],"protocolVersion":"0.3","url":"https://peer.example"}"#
        ] {
            #expect(throws: AgentA2AWire.WireError.self) {
                try AgentA2AWire.selectInterface(card: json(fixture), cardURL: endpoint)
            }
        }
    }

    @Test func legacyAndCurrentRequestsUseTheirOwnWireShapes() throws {
        for version in ["0.3", "1.0"] {
            let request = try AgentA2AWire.messageRequest(text: "Hello", messageID: "m1", contextID: "c1", taskID: "t1", interface: rpc(version))
            #expect(request.headers["A2A-Version"] == version)
            #expect(field(request.body, "method") == .string(version == "0.3" ? "message/send" : "SendMessage"))
            let message = field(field(request.body, "params"), "message")
            #expect(field(message, "role") == .string(version == "0.3" ? "user" : "ROLE_USER"))
            #expect(field(message, "contextId") == .string("c1"))
            #expect(field(message, "taskId") == .string("t1"))
            #expect(field(message, "kind") == (version == "0.3" ? .string("message") : nil))
            let task = try AgentA2AWire.taskRequest(taskID: "t1", interface: rpc(version), requestID: "r1")
            #expect(field(task.body, "method") == .string(version == "0.3" ? "tasks/get" : "GetTask"))
            #expect(field(field(task.body, "params"), "id") == .string("t1"))
        }
    }

    @Test func restPreservesBasePathEscapesTaskIDAndCarriesTenant() throws {
        let selected = AgentA2AWire.Interface(endpoint: endpoint, version: "1.0", binding: "HTTP+JSON", tenant: "tenant & one")
        let send = try AgentA2AWire.messageRequest(text: "Hi", messageID: "m1", interface: selected)
        #expect(send.url.path == "/a2a/message:send")
        #expect(field(send.body, "tenant") == .string("tenant & one"))
        let get = try AgentA2AWire.taskRequest(taskID: "a/b?c#d", interface: selected)
        #expect(get.httpMethod == "GET")
        #expect(get.body == nil)
        #expect(get.url.absoluteString.contains("a%2Fb%3Fc%23d"))
        #expect(URLComponents(url: get.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "tenant & one")
    }

    @Test func submittedAndReplyAreNotCompletedActions() throws {
        let submitted = try json(#"{"jsonrpc":"2.0","id":"r","result":{"task":{"id":"t","contextId":"c","status":{"state":"TASK_STATE_SUBMITTED"}}}}"#)
        let result = try AgentA2AWire.normalizeResponse(submitted, interface: rpc(), expectedRequestID: "r")
        #expect(result.state == "submitted")
        #expect(!result.completed && !result.terminal)
        let reply = try json(#"{"jsonrpc":"2.0","id":"r","result":{"message":{"messageId":"m","role":"ROLE_AGENT","parts":[{"text":"Accepted"}]}}}"#)
        let message = try AgentA2AWire.normalizeResponse(reply, interface: rpc(), expectedRequestID: "r")
        #expect(message.kind == "message" && message.state == "reply")
        #expect(message.text == "Accepted")
        #expect(!message.completed && !message.terminal)
    }

    @Test(arguments: ["input-required", "auth-required", "completed", "failed", "canceled", "rejected", "future-state"])
    func normalizesLifecycleWithoutInventingUnknownSuccess(_ state: String) throws {
        for version in ["0.3", "1.0"] {
            let wireState = version == "0.3" ? state : "TASK_STATE_" + state.uppercased().replacingOccurrences(of: "-", with: "_")
            var task: [String: JSONValue] = ["id": .string("t"), "status": .object(["state": .string(wireState)])]
            if version == "0.3" { task["kind"] = .string("task") }
            let body: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .string("r"),
                "result": version == "0.3" ? .object(task) : .object(["task": .object(task)])])
            let result = try AgentA2AWire.normalizeResponse(body, interface: rpc(version), expectedRequestID: "r", expectedTaskID: "t")
            #expect(result.state == (state == "future-state" ? "unknown" : state))
            #expect(result.completed == (state == "completed"))
            #expect(result.needsInput == (state == "input-required"))
            #expect(result.needsAuthentication == (state == "auth-required"))
        }
    }

    @Test func getTaskKeepsArtifactsAndDoesNotFetchTheirURLs() throws {
        let value = try json(#"{"jsonrpc":"2.0","id":"r","result":{"id":"t","status":{"state":"TASK_STATE_COMPLETED"},"artifacts":[{"artifactId":"a","parts":[{"text":"Done"},{"url":"https://files.example/result","mediaType":"text/plain"}]}]}}"#)
        let result = try AgentA2AWire.normalizeResponse(value, interface: rpc(), expectedRequestID: "r", expectedTaskID: "t")
        #expect(result.completed && result.terminal)
        #expect(result.text == "Done")
        #expect(result.artifacts.count == 1)
        #expect(result.raw == value)
    }

    @Test func refusesMismatchedIDsAndMalformedOrAmbiguousResults() throws {
        for fixture in [
            #"{"jsonrpc":"2.0","id":"other","result":{"task":{"id":"t","status":{"state":"TASK_STATE_COMPLETED"}}}}"#,
            #"{"jsonrpc":"2.0","id":"r","result":{"task":{"id":"wrong","status":{"state":"TASK_STATE_COMPLETED"}}}}"#,
            #"{"jsonrpc":"2.0","id":"r","result":{"task":{"id":"t","status":{}},"message":{}}}"#,
            #"{"jsonrpc":"2.0","id":"r","result":{"task":{"id":"t","status":{}}}}"#,
            #"{"jsonrpc":"2.0","id":"r","result":{},"error":{"code":-1,"message":"bad"}}"#,
            #"{"jsonrpc":"2.0","id":"r","result":{"message":{"taskId":"t","messageId":"m","role":"ROLE_AGENT","parts":[{"text":"x","url":"https://example.com"}]}}}"#
        ] {
            #expect(throws: AgentA2AWire.WireError.self) {
                try AgentA2AWire.normalizeResponse(json(fixture), interface: rpc(), expectedRequestID: "r", expectedTaskID: "t")
            }
        }
        #expect(throws: AgentA2AWire.WireError.self) {
            try AgentA2AWire.normalizeResponse(json(#"{"jsonrpc":"2.0","id":"r","error":{"code":-32001,"message":"No such task"}}"#), interface: rpc(), expectedRequestID: "r")
        }
    }
}
