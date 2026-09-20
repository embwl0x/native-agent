import Foundation
import Testing
import ChatOrchestration
import PersistenceCore
import ProviderRouting
@testable import NativeAgentApp

@Suite struct ProviderFailureDoorTests {
    @Test func retainedFailureReachesA2AMCPAndPlainReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ProviderFailure.Report(cause: .rateLimited(retryAfter: 30), work: .ranPartly)
        let tasks = AgentContactTasks(dataRoot: root) { _, _ in throw failure }
        let context = "mcp-" + UUID().uuidString.lowercased()
        let request = UUID().uuidString
        let send = NativeAgentA2AWire.Send(rpcID: request, context: context, request: request,
            text: "Hello", clientMessageID: request, parts: [.text("Hello")])
        let accepted = try await tasks.send(send, principal: .anonymous, digest: "fixture", protocolName: "mcp")
        let task = try await tasks.settled(accepted.id, owner: AgentBridgePrincipal.anonymous.id)
        #expect(task.state == .failed)
        #expect(task.failure == failure)
        let reloaded = AgentContactTasks(dataRoot: root) { _, _ in Issue.record("Must not run again"); throw failure }
        #expect(try await reloaded.get(task.id, owner: task.owner).failure == failure)
        for version in ["0.3", "1.0"] {
            let projected = try NativeAgentA2AWire.project(task, version: version)
            let payload = NativeAgentA2AWire.result(request, version == "1.0" ? ["task": projected] : projected)
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
            let result = try AgentA2AWire.normalizeResponse(value, interface: .init(
                endpoint: URL(string: "http://127.0.0.1/a2a")!, version: version, binding: "JSONRPC"), expectedRequestID: request)
            #expect(result.failure == failure)
            #expect(result.text.contains("usage limit"))
            #expect(result.text.contains("ran partly"))
        }
        let receipt = ClaudeBridge.contactReply(task, requestID: request, sessionID: context, offset: 0, maxChars: 8000)
        #expect(receipt["reply"] as? String == failure.errorDescription)
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "agent_reply", "arguments": ["session_id": context, "request_id": request]]]
        guard case .reply(_, _, _, let project) = NativeAgentMCPWire.parse(try JSONSerialization.data(withJSONObject: call)) else {
            Issue.record("Expected reply projection"); return
        }
        let result = try #require(project(receipt)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["work"] as? String == "ran partly")
        #expect(structured["provider_failure"] != nil)
    }
}
