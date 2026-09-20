import Foundation
import Testing
import PersistenceCore
import ProviderRouting
@testable import ChatOrchestration

@Suite struct AgentPeerDiscoveryTests {
    @Test func optionalExtendedCardDoesNotRequireAKeyForPublicAccess() async throws {
        let url = URL(string: "https://public-agent.invalid/card.json")!
        let card: JSONValue = .object([
            "supportedInterfaces": .array([.object([
                "url": .string("https://public-agent.invalid/a2a"),
                "protocolVersion": .string("1.0"), "protocolBinding": .string("JSONRPC")])]),
            "capabilities": .object(["extendedAgentCard": .bool(true)])])
        let selected = try await AgentPeerDiscovery.authenticatedInterface(card: card, cardURL: url, bearerToken: nil)
        #expect(selected == (try AgentA2AWire.selectInterface(card: card, cardURL: url)))

        guard case .object(var protectedCard) = card else { return }
        protectedCard["securityRequirements"] = .array([.object([
            "schemes": .object(["key": .object(["list": .array([])])])])])
        protectedCard["securitySchemes"] = .object([
            "key": .object(["httpAuthSecurityScheme": .object(["scheme": .string("bearer")])])])
        await #expect(throws: (any Error).self) {
            try await AgentPeerDiscovery.authenticatedInterface(card: .object(protectedCard), cardURL: url, bearerToken: nil)
        }
    }

    @Test func acpDiscoveryOffersConnectionWithoutSettingsOrProof() throws {
        for name in ["Gemini CLI", "Goose", "Cursor CLI"] {
            let row = try #require(AgentHostDirectory.row(named: name))
            let candidate = AgentPeerDiscovery.installedCandidate(row)
            #expect(candidate.settingsPath == nil)
            guard case .object(let fields) = candidate.projection else {
                Issue.record("Missing projection"); continue
            }
            #expect(fields["settings_file"] == nil)
            #expect(fields["setup"] != nil)
            #expect(fields["route"] == .string("acp"))
            #expect(fields["can_start_turn"] == .bool(false))
            #expect(fields["can_answer_back"] == .bool(false))
            #expect(fields["state"] == .string(AgentPeerContactState.listed.rawValue))
            #expect(fields["state_detail"] == .string(AgentPeerContactState.listed.detail))
            #expect(fields["capabilities"] == .array([]))
        }
    }

    @Test func rootAndExactCardDiscoveryReuseOneIdentityWithoutMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        try await AgentPeerHTTP.$fixtureConfiguration.withValue(Self.fixture) {
            let first = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: normalizedToolArguments("agent_connect", [
                "name": .string("First name"), "endpoint": .string("https://127.0.0.1:9101"), "transport": .null]), surface: "chat")
            guard case .object(let result) = first else { Issue.record("Missing result"); return }
            #expect(result["status"] == .string("configured"))
            let store = AgentPeerStore(dataRoot: root)
            let initial = try #require(store.list().first)
            #expect(initial.transport == .a2a)
            #expect(initial.endpoint.absoluteString == "https://127.0.0.1:9101/.well-known/agent-card.json")
            let second = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: [
                "name": .string("Do not rename"), "endpoint": .string(initial.endpoint.absoluteString),
                "transport": .string("auto")], surface: "chat")
            guard case .object(let reused) = second else { Issue.record("Missing reused result"); return }
            #expect(reused["status"] == .string("already_configured"))
            #expect(try store.list() == [initial])
        }
    }

    @Test(arguments: ["127.0.0.1:9102", "127.0.0.1:9103", "127.0.0.1:9104", "127.0.0.1:9105"])
    func failedDiscoveryDoesNotSaveContacts(host: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-no-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await AgentPeerHTTP.$fixtureConfiguration.withValue(Self.fixture) {
            let result = try await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
                .impl_agentCommunication(tool: "agent_connect", input: ["name": .string("Fixture"),
                    "endpoint": .string("https://\(host)")], surface: "chat")
            guard case .object(let fields) = result else { Issue.record("Missing result"); return }
            #expect(fields["status"] == .string(host == "127.0.0.1:9103" ? "failed" : host == "127.0.0.1:9105" ? "needs_setup" : "unsupported"))
            if host == "127.0.0.1:9103" {
                let failure = try #require(fields["provider_failure"])
                let report = try JSONDecoder().decode(ProviderFailure.Report.self, from: failure.serializedData(pretty: false))
                #expect(report == ProviderFailure.Report(cause: .authExpired, work: .nothingRan))
            }
            let store = AgentPeerStore(dataRoot: root)
            #expect(try store.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    @Test func nativeCardResolvesBaseAndRequiresAdvertisedAuthentication() async throws {
        try await AgentPeerHTTP.$fixtureConfiguration.withValue(Self.fixture) {
            let url = URL(string: "https://127.0.0.1:9106/agent/card")!
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
        switch "\(url.host ?? ""):\(url.port ?? 443)" {
        case "127.0.0.1:9101":
            if url.path == "/.well-known/agent-card.json" {
                body = ["protocolVersion": "0.3.0", "url": "https://127.0.0.1:9101/rpc"]
            } else { body = ["name": "ordinary website"] }
        case "127.0.0.1:9102": body = ["protocolVersion": "99.0", "url": "https://127.0.0.1:9102/rpc"]
        case "127.0.0.1:9103": status = 401
        case "127.0.0.1:9104": body = ["protocolVersion": "0.3.0", "url": "https://elsewhere.example/rpc"]
        case "127.0.0.1:9106":
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
