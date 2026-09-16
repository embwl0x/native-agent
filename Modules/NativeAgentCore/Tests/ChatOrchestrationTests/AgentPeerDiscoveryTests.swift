import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentPeerDiscoveryTests {
    @Test func rootAndExactCardDiscoveryReuseOneIdentityWithoutMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        try await AgentPeerHTTP.$fixtureConfiguration.withValue(Self.fixture) {
            let first = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: [
                "name": .string("First name"), "endpoint": .string("https://discover.example"), "transport": .null], surface: "chat")
            guard case .object(let result) = first else { Issue.record("Missing result"); return }
            #expect(result["status"] == .string("configured"))
            let store = AgentPeerStore(dataRoot: root)
            let initial = try #require(store.list().first)
            #expect(initial.transport == .a2a)
            #expect(initial.endpoint.absoluteString == "https://discover.example/.well-known/agent-card.json")
            let second = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: [
                "name": .string("Do not rename"), "endpoint": .string(initial.endpoint.absoluteString),
                "transport": .string("auto")], surface: "chat")
            guard case .object(let reused) = second else { Issue.record("Missing reused result"); return }
            #expect(reused["status"] == .string("already_configured"))
            #expect(try store.list() == [initial])
        }
    }

    @Test(arguments: ["unsupported.example", "auth.example", "cross.example", "plain.example"])
    func failedDiscoveryDoesNotSaveContacts(host: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-no-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await AgentPeerHTTP.$fixtureConfiguration.withValue(Self.fixture) {
            let result = try await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
                .impl_agentCommunication(tool: "agent_connect", input: ["name": .string("Fixture"),
                    "endpoint": .string("https://\(host)")], surface: "chat")
            guard case .object(let fields) = result else { Issue.record("Missing result"); return }
            #expect(fields["status"] == .string(host == "auth.example" ? "auth_required" : host == "plain.example" ? "needs_setup" : "unsupported"))
            let store = AgentPeerStore(dataRoot: root)
            #expect(try store.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    @Test func nativeCardResolvesBaseAndRequiresAdvertisedAuthentication() async throws {
        try await AgentPeerHTTP.$fixtureConfiguration.withValue(Self.fixture) {
            let url = URL(string: "https://native.example/agent/card")!
            let missing = try await AgentPeerDiscovery.resolve(url, bearerToken: nil)
            guard case .object(let evidence) = missing.evidence else { Issue.record("Missing evidence"); return }
            #expect(evidence["status"] == .string("auth_required"))
            #expect(missing.endpoint == nil)
            let supported = try await AgentPeerDiscovery.resolve(url, bearerToken: "fixture-only")
            #expect(supported.transport == .nativeAgent)
            #expect(supported.endpoint?.path == "" || supported.endpoint?.path == "/")
        }
    }

    @Test func candidatesAreBoundedAndStayOnTheSuppliedOrigin() throws {
        let url = URL(string: "https://example.test:9443/nested")!
        let candidates = AgentPeerDiscovery.candidates(for: url)
        #expect(candidates.count <= 5)
        #expect(candidates.first == url)
        #expect(candidates.allSatisfy { $0.host == url.host && $0.scheme == url.scheme && $0.port == url.port })
        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.contains(URL(string: "https://example.test:9443/.well-known/agent-card.json")!))
    }

    @Test func storeRefusesAmbiguousIdentityWithoutOverwritingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-ambiguous-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let endpoint = URL(string: "https://example.test/card")!
        try store.upsert(AgentPeerContact(name: "One", endpoint: endpoint, transport: .a2a))
        try store.upsert(AgentPeerContact(name: "Two", endpoint: endpoint, transport: .a2a))
        let before = try Data(contentsOf: store.fileURL)
        #expect(throws: (any Error).self) {
            try store.insertDiscovered(AgentPeerContact(name: "Three", endpoint: endpoint, transport: .a2a))
        }
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    private static let fixture: @Sendable () -> URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryFixtureProtocol.self]
        return config
    }
}

private final class DiscoveryFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        #expect(request.httpMethod == "GET", "Discovery must never send an agent message")
        #expect(url.host != "elsewhere.example", "Discovery must not follow a remote interface")
        var status = 200
        var body: [String: Any] = [:]
        switch url.host {
        case "discover.example":
            if url.path == "/.well-known/agent-card.json" {
                body = ["protocolVersion": "0.3.0", "url": "https://discover.example/rpc"]
            } else { body = ["name": "ordinary website"] }
        case "unsupported.example": body = ["protocolVersion": "99.0", "url": "https://unsupported.example/rpc"]
        case "auth.example": status = 401
        case "cross.example": body = ["protocolVersion": "0.3.0", "url": "https://elsewhere.example/rpc"]
        case "native.example":
            body = ["protocol": "nativeagent-bridge", "version": "1.0",
                    "authentication": ["scheme": "bearer", "required": true],
                    "message": ["method": "POST", "path": "/agent/message", "text_field": "text", "session_field": "sessionId"],
                    "reply": ["method": "POST", "path": "/agent/reply", "request_field": "request_id", "session_field": "session_id"]]
        default: body = ["name": "not an agent", "description": "ordinary JSON"]
        }
        if body["protocolVersion"] != nil {
            body["name"] = "Fixture agent"
            body["capabilities"] = [String: Any]()
            body["skills"] = [Any]()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}
