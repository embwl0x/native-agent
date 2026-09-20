import Foundation
import Security
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentPeerTransportTests {
    @Test func legacyCredentialSurvivesUpgradeAndRevocationWithoutRecreatingContact() throws {
        let service = "fixture-install"
        var keys = [AgentPeerCredentials.legacyService: "old-contact-key"]
        #expect(try AgentPeerCredentials.compatibleToken(service: service, read: { keys[$0] }) == "old-contact-key")
        keys[service] = "new-contact-key"
        #expect(try AgentPeerCredentials.compatibleToken(service: service, read: { keys[$0] }) == "new-contact-key")
        try AgentPeerCredentials.revoke(service: service) { keys.removeValue(forKey: $0) }
        #expect(try AgentPeerCredentials.compatibleToken(service: service, read: { keys[$0] }) == nil)
        #expect(throws: AgentPeerCredentials.CredentialError.self) {
            try AgentPeerCredentials.compatibleToken(service: service) { _ in throw AgentPeerCredentials.CredentialError.unavailable }
        }
        var peer = AgentPeerContact(name: "Old friend", endpoint: URL(string: "http://127.0.0.1:1234")!, transport: .a2a,
                                    provenInboundAt: "before-upgrade")
        peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id)
        #expect(peer.state == .connected)
        peer.unavailableAt = "now"
        #expect(peer.state == .setUp)
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PeerFixtureProtocol.self]
        return config
    }
    private func exchange(_ path: String, token: String? = nil) async throws -> AgentPeerHTTP.Response {
        try await AgentPeerHTTP.exchange(url: URL(string: "https://localhost/" + path)!, method: "GET",
            headers: [:], body: nil, bearerToken: token, timeout: 2, configuration: configuration())
    }

    @Test func validatesHTTPSAndOnlyExactLoopbackHTTP() throws {
        for value in ["https://peer.example/rpc", "https://localhost/rpc", "http://127.0.0.1:8080", "http://[::1]:80", "http://localhost"] {
            try AgentPeerHTTP.validateURL(URL(string: value)!)
        }
        for value in ["http://peer.example", "http://127.1", "http://localhost.example", "https://user:token@peer.example", "file:///tmp/a", "https://peer.example/#fragment"] {
            #expect(throws: AgentPeerHTTP.TransportError.self) { try AgentPeerHTTP.validateURL(URL(string: value)!) }
        }
    }

    @Test func preservesHTTPFailureStatusWithoutDisclosingNonJSONBody() async throws {
        let json = try await exchange("json", token: "fixture-token")
        #expect(json.statusCode == 200)
        #expect(json.json == .object(["authorizationPresent": .bool(true)]))
        let failure = try await exchange("failure")
        #expect(failure.statusCode == 401)
        #expect(failure.json == nil)
    }

    @Test func boundsDeclaredAndIncrementalResponseCapture() async {
        for path in ["declared-large", "chunked-large"] {
            do { _ = try await exchange(path); Issue.record("Expected bounded capture rejection") }
            catch { #expect(error as? AgentPeerHTTP.TransportError == .tooLarge) }
        }
    }

    @Test func refusesRedirectStatusWithoutFollowingLocation() async {
        do { _ = try await exchange("redirect"); Issue.record("Expected redirect rejection") }
        catch { #expect(error as? AgentPeerHTTP.TransportError == .redirected) }
    }

    @Test func rejectsHeaderInjectionBeforeTransport() async {
        do { _ = try await exchange("json", token: "bad\r\nAuthorization: other"); Issue.record("Expected invalid credential rejection") }
        catch { #expect(error as? AgentPeerHTTP.TransportError == .invalidRequest) }
    }

    @Test func cancellationDoesNotWaitForRemoteCompletion() async {
        let config = configuration()
        let task = Task {
            try await AgentPeerHTTP.exchange(url: URL(string: "https://localhost/hang")!, method: "GET",
                headers: [:], body: nil, bearerToken: nil, timeout: 2, configuration: config)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error as? AgentPeerHTTP.TransportError == .cancelled) }
    }

    @Test func credentialQueriesUseOnlyDedicatedPeerNamespaceWithoutKeychainAccess() throws {
        let id = UUID().uuidString.lowercased()
        let query = try AgentPeerCredentials.query(peerID: id)
        #expect(query[kSecAttrAccount as String] as? String == AgentPeerContact.credentialKey(for: id))
        #expect(query[kSecAttrService as String] as? String == AgentPeerCredentials.service)
        #expect(query[kSecValueData as String] == nil)
        #expect(throws: AgentPeerCredentials.CredentialError.self) { try AgentPeerCredentials.query(peerID: "provider-token") }
        #expect(!AgentPeerHTTP.validToken(""))
        #expect(!AgentPeerHTTP.validToken(String(repeating: "a", count: 16_385)))
    }
}

private final class PeerFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "hang" { return }
        let status = path == "failure" ? 401 : (path == "redirect" ? 307 : 200)
        var headers = ["Content-Type": "application/json"]
        if path == "redirect" { headers["Location"] = "https://must-not-be-contacted.example" }
        if path == "declared-large" { headers["Content-Length"] = String(AgentPeerHTTP.maximumResponseBytes + 1) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "chunked-large" {
            let chunk = Data(repeating: 0x20, count: 128 * 1_024)
            for _ in 0..<17 { client?.urlProtocol(self, didLoad: chunk) }
        } else if path == "failure" {
            client?.urlProtocol(self, didLoad: Data("private server diagnostic".utf8))
        } else {
            let present = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
            client?.urlProtocol(self, didLoad: Data("{\"authorizationPresent\":\(present)}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
