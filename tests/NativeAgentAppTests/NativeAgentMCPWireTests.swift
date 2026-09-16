import Foundation
import Testing
@testable import NativeAgentApp

@Suite struct NativeAgentMCPWireTests {
    private func request(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "call-1", "method": method, "params": params])
    }

    @Test func negotiationAndToolsExposeOnlyPersistentConversationOperations() throws {
        let data = try request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:],
                                              "clientInfo": ["name": "fixture", "version": "1"]])
        guard case .immediate(let status, let envelope) = NativeAgentMCPWire.parse(data),
              let result = envelope["result"] as? [String: Any] else { Issue.record("Missing initialize result"); return }
        #expect(status == 200)
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect(Set(NativeAgentMCPWire.tools.compactMap { $0["name"] as? String }) == ["agent_message", "agent_reply"])
        #expect((result["capabilities"] as? [String: Any])?["resources"] == nil)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        guard case .acceptedNotification = NativeAgentMCPWire.parse(notification) else {
            Issue.record("Notification should be acknowledged without a body"); return
        }
    }

    @Test func newConversationRetainsExactIdentityAndNeverBorrowsHumanChat() throws {
        let data = try request("tools/call", ["name": "agent_message", "arguments": ["text": "Hello"]])
        guard case .message(let body, let project) = NativeAgentMCPWire.parse(data),
              let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let session = fields["sessionId"] as? String,
              let requestID = fields["request_id"] as? String else { Issue.record("Missing message projection"); return }
        #expect(NativeAgentMCPWire.validSession(session))
        let ack = project(200, ["ack": "enqueued", "sessionId": session, "requestId": requestID])
        let result = try #require(ack["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let continuation = try request("tools/call", ["name": "agent_message", "arguments": ["text": "Continue", "session_id": session]])
        guard case .message(let next, _) = NativeAgentMCPWire.parse(continuation) else { Issue.record("Resume rejected"); return }
        let nextFields = try #require(JSONSerialization.jsonObject(with: next) as? [String: Any])
        #expect(nextFields["sessionId"] as? String == session)
        for rejected in [UUID().uuidString, "../chat", "mcp-unknown", " " + session] {
            let invalid = try request("tools/call", ["name": "agent_message", "arguments": ["text": "No", "session_id": rejected]])
            guard case .immediate(_, let error) = NativeAgentMCPWire.parse(invalid) else { Issue.record("Invalid identity admitted"); continue }
            #expect(error["error"] != nil)
        }
        let uncertain = project(200, ["ack": "enqueued", "sessionId": "wrong", "requestId": requestID])
        let uncertainResult = try #require(uncertain["result"] as? [String: Any])
        let retained = try #require(uncertainResult["structuredContent"] as? [String: Any])
        #expect(uncertainResult["isError"] as? Bool == true)
        #expect(retained["status"] as? String == "outcome_unknown")
        #expect(retained["session_id"] as? String == session)
        #expect(retained["read_with"] != nil)
    }

    @Test func replyPagesReuseCanonicalReceiptAndScrubUnadvertisedFields() throws {
        let session = "mcp-" + UUID().uuidString.lowercased(), requestID = UUID().uuidString
        let data = try request("tools/call", ["name": "agent_reply", "arguments": [
            "session_id": session, "request_id": requestID, "offset": 8]])
        guard case .reply(let returnedRequest, let returnedSession, let offset, let project) = NativeAgentMCPWire.parse(data) else {
            Issue.record("Missing read projection"); return
        }
        #expect(returnedSession == session && returnedRequest == requestID && offset == 8)
        let reply = project(["status": "ok", "reply": "retained", "has_more": true, "next_offset": 16,
                             "log_path": "/private/should-not-escape"])
        let result = try #require(reply["result"] as? [String: Any])
        let retained = try #require(result["structuredContent"] as? [String: Any])
        #expect(retained["next_offset"] as? Int == 16)
        #expect(retained["log_path"] == nil)
        let invalid = try request("tools/call", ["name": "agent_reply", "arguments": [
            "session_id": session, "request_id": requestID, "offset": true]])
        guard case .immediate(_, let error) = NativeAgentMCPWire.parse(invalid) else { Issue.record("Boolean offset admitted"); return }
        #expect(error["error"] != nil)
    }

    @Test func malformedBatchAndUnknownMethodCannotStartTurns() throws {
        for bytes in [Data("[{}]".utf8), Data("invalid".utf8), try request("tools/delete"),
                      try request("tools/call", ["name": "shell", "arguments": ["command": "no"]])] {
            guard case .immediate(_, let envelope) = NativeAgentMCPWire.parse(bytes) else { Issue.record("Invalid request admitted"); continue }
            #expect(envelope["error"] != nil)
        }
    }
}
