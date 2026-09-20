import Foundation
import Testing
import NativeAgentCore
import Research
@testable import ChatOrchestration

@Suite struct LocalMCPFailureTests {
    private struct DownHTTP: ResearchHTTPClient {
        func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?) {
            throw URLError(.cannotConnectToHost)
        }
    }

    @Test func searxngFetchDoesNotBlameSearxngForRefusedDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeResearchClient(dataRoot: root, http: DownHTTP())
        do {
            _ = try await client.fetchURL("http://localhost:3000/page")
            Issue.record("Expected refused connection")
        } catch {
            #expect(SwiftToolDispatcher.localMCPFailure(error, serverId: "searxng-local",
                toolName: "fetch", endpoint: "http://127.0.0.1:8080") == nil)
            guard case ResearchClientError.localServerNotRunning(let url) = error else {
                Issue.record("Expected original destination failure"); return
            }
            #expect(url == "http://localhost:3000/page")
        }
        #expect(SwiftToolDispatcher.localMCPFailure(ResearchClientError.transport("remote failed"),
            serverId: "searxng-local", toolName: "search", endpoint: "http://127.0.0.1:8080") == nil)
    }

    @Test func searxngSearchNamesTheLocalServerThatIsDown() {
        let result = SwiftToolDispatcher.localMCPFailure(
            ResearchClientError.localServerNotRunning("http://127.0.0.1:8080/search"),
            serverId: "searxng-local", toolName: "search", endpoint: "http://127.0.0.1:8080")
        guard case .object(let object) = result else { Issue.record("Missing server result"); return }
        #expect(object["server"] == .string("searxng-local"))
        #expect(object["reason"] == .string("server_not_running"))
        #expect(String(describing: object["detail"]).contains("not running"))
    }
}
