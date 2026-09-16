import Foundation
import Testing
@testable import NativeAgentApp

@Suite struct NativeAgentA2AWireTests {
    private func request(_ message: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "rpc-1", "method": "message/send", "params": ["message": message]])
    }
    private var message: [String: Any] {
        ["kind": "message", "role": "user", "messageId": "client-message", "parts": [["kind": "text", "text": "hello"]]]
    }
    @Test func firstTurnCreatesIsolatedContextAndContinuationRetainsIt() throws {
        guard case .send(let first) = NativeAgentA2AWire.parse(try request(message)) else { Issue.record("send not admitted"); return }
        #expect(NativeAgentA2AWire.validContext(first.context))
        #expect(NativeAgentA2AWire.locator(first.taskID)?.request == first.request)
        var followup = message; followup["contextId"] = first.context
        guard case .send(let second) = NativeAgentA2AWire.parse(try request(followup)) else { Issue.record("continuation rejected"); return }
        #expect(second.context == first.context)
        #expect(second.taskID != first.taskID)
        #expect(ClaudeBridge.validGenericAgentMessage(try #require(JSONSerialization.jsonObject(with: second.body) as? [String: Any])))
        followup["contextId"] = "users-selected-chat"
        guard case .response(let rejected) = NativeAgentA2AWire.parse(try request(followup)) else { Issue.record("local session accepted"); return }
        #expect(rejected["error"] != nil)
    }
    @Test func taskStateRequiresExactEvidenceAndNeverInventsCompletion() throws {
        guard case .send(let send) = NativeAgentA2AWire.parse(try request(message)) else { Issue.record("send not admitted"); return }
        let accepted = NativeAgentA2AWire.acknowledgement(send, status: 200, body: ["ack": "enqueued", "requestId": send.request, "sessionId": send.context])
        #expect(((accepted["result"] as? [String: Any])?["status"] as? [String: Any])?["state"] as? String == "submitted")
        #expect(NativeAgentA2AWire.acknowledgement(send, status: 504, body: [:])["error"] != nil)
        var receipt: [String: Any] = ["status": "ok", "request_id": send.request, "session_id": send.context, "original_status": "ok", "reply": "hello back", "has_more": false]
        func project() -> [String: Any] { NativeAgentA2AWire.receipt(id: "rpc", task: send.taskID, context: send.context, request: send.request, body: receipt) }
        #expect(((project()["result"] as? [String: Any])?["status"] as? [String: Any])?["state"] as? String == "completed")
        receipt["original_status"] = "no_reply"; receipt["reply"] = ""
        let unansweredStatus = (project()["result"] as? [String: Any])?["status"] as? [String: Any]
        #expect(unansweredStatus?["state"] as? String == "failed")
        #expect(unansweredStatus?["message"] != nil)
        receipt["original_status"] = "ok"; receipt["reply"] = "hello back"
        receipt["session_id"] = "other"
        #expect(project()["error"] != nil)
        receipt["session_id"] = send.context; receipt["status"] = "not_found"
        #expect(project()["error"] != nil)
        receipt["status"] = "ok"; receipt["has_more"] = true
        #expect(project()["error"] != nil)
    }
    @Test func unsupportedInputIsRejectedBeforeDispatchAndCardIsHonest() throws {
        var value = message; value["parts"] = [["kind": "file", "file": ["uri": "https://example.com/file"]]]
        guard case .response(let response) = NativeAgentA2AWire.parse(try request(value)) else { Issue.record("unsupported content admitted"); return }
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32005)
        #expect(NativeAgentA2AWire.locator("na3.user-chat.abc") == nil)
        let card = NativeAgentA2AWire.card(port: 9999)
        #expect(card["url"] as? String == "http://127.0.0.1:9999/a2a")
        #expect(card["protocolVersion"] as? String == "0.3.0")
        #expect((card["capabilities"] as? [String: Bool])?["streaming"] == false)
    }
    @Test func mcpTransportRejectsForeignOriginAndUnsupportedNegotiation() {
        var headers = ["accept": "application/json, text/event-stream", "content-type": "application/json"]
        #expect(ClaudeBridge.mcpTransportRejection(headers: headers, port: 8771) == nil)
        headers["origin"] = "https://foreign.example"
        #expect(ClaudeBridge.mcpTransportRejection(headers: headers, port: 8771) == 403)
        headers["origin"] = "http://127.0.0.1:8771"
        headers["mcp-protocol-version"] = "future-unsupported"
        #expect(ClaudeBridge.mcpTransportRejection(headers: headers, port: 8771) == 400)
        headers["mcp-protocol-version"] = "2025-11-25"
        headers["accept"] = ";"
        #expect(ClaudeBridge.mcpTransportRejection(headers: headers, port: 8771) == 406)
    }
    @Test func optionalBlockingAndBoundedRPCIdentityAreExplicit() throws {
        var json = try #require(JSONSerialization.jsonObject(with: request(message)) as? [String: Any])
        var params = try #require(json["params"] as? [String: Any])
        // Omitted blocking has no true default in the tagged 0.3 schema.
        guard case .send = NativeAgentA2AWire.parse(try JSONSerialization.data(withJSONObject: json)) else {
            Issue.record("optional configuration rejected"); return
        }
        params["configuration"] = ["blocking": true]; json["params"] = params
        guard case .response(let blocked) = NativeAgentA2AWire.parse(try JSONSerialization.data(withJSONObject: json)) else {
            Issue.record("blocking request silently downgraded"); return
        }
        #expect((blocked["error"] as? [String: Any])?["code"] as? Int == -32004)
        params["configuration"] = ["blocking": false]; json["params"] = params
        guard case .send = NativeAgentA2AWire.parse(try JSONSerialization.data(withJSONObject: json)) else {
            Issue.record("explicit nonblocking rejected"); return
        }
        for invalidID in [NSNull(), true, 1.5, String(repeating: "x", count: 257)] as [Any] {
            json["id"] = invalidID
            guard case .response(let invalid) = NativeAgentA2AWire.parse(try JSONSerialization.data(withJSONObject: json)) else {
                Issue.record("invalid RPC ID admitted"); continue
            }
            #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32600)
        }
    }
}
