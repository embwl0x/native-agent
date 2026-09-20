import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

struct NativeAgentA2ARESTTests {
    @Test func restQueriesCardsAndErrorsUseTheCanonicalHandler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-rest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = AgentContactTasks(dataRoot: root) { _, _ in .init(state: .completed, parts: []) }
        let endpoint = AgentContactA2AEndpoint(tasks: tasks, port: 12345)
        let parsed = BridgeCore.parseRequestHead(Data("GET /a2a/tasks?pageSize=1&includeArtifacts=true HTTP/1.1\r\n\r\n".utf8))
        #expect(parsed?.path == "/a2a/tasks?pageSize=1&includeArtifacts=true")
        guard case .json(let status, let list) = await endpoint.handleREST(method: "GET", target: parsed!.path,
            body: Data(), principal: .anonymous, version: "1.0") else { Issue.record("Unexpected stream"); return }
        #expect(status == 200 && list["pageSize"] as? Int == 1)
        for query in ["pageSize=1&pageSize=2", "includeArtifacts=maybe", "pageSize=-1"] {
            guard case .json(let code, let value) = await endpoint.handleREST(method: "GET", target: "/a2a/tasks?" + query,
                body: Data(), principal: .anonymous, version: "1.0") else { Issue.record("Unexpected stream"); continue }
            #expect(code == 400 && value["error"] != nil)
        }
        let cardRequest = Data(#"{"jsonrpc":"2.0","id":"card","method":"GetExtendedAgentCard"}"#.utf8)
        guard case .json(let cardEnvelope) = await endpoint.handle(cardRequest, principal: .anonymous, version: "1.0"),
              let card = cardEnvelope["result"] as? [String: Any] else { Issue.record("Extended card missing"); return }
        let interfaces = try #require(card["supportedInterfaces"] as? [[String: String]])
        #expect(interfaces.contains { $0["protocolBinding"] == "HTTP+JSON" && $0["url"] == "http://127.0.0.1:12345/a2a" })
        #expect(!interfaces.contains { $0["protocolBinding"] == "GRPC" })
    }
}
