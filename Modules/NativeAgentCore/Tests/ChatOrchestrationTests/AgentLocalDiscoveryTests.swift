import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration
@testable import NativeAgentCore

@Suite struct AgentLocalDiscoveryTests {
    @Test func standaloneCodexLinksAreInstalledWithoutPATHOrSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        let package = home.appendingPathComponent(".codex/packages/standalone/v1/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let command = package.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let current = home.appendingPathComponent(".codex/packages/standalone/current")
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: "v1")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("codex").path,
            withDestinationPath: current.appendingPathComponent("bin/codex").path)
        let row = try #require(AgentHostDirectory.row(named: "Codex"))
        #expect(row.isInstalled(applicationExists: { _ in false }, executable: {
            AgentHostCommandLines.resolveExecutable($0, directories: ["~/.local/bin"], home: home.path)
        }))
        #expect(AgentHostCommandLines.resolveExecutable("codex", directories: ["~/.local/bin"], home: home.path) == command.path)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }
    @Test func lookupDoesNotRunShellStartupOrFoundExecutable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let name = "fixture-\(UUID().uuidString)"
        let command = bin.appendingPathComponent(name)
        let sentinel = home.appendingPathComponent("executed")
        try Data("#!/bin/sh\ntouch '\(sentinel.path)'\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        try Data("touch '\(sentinel.path)'\n".utf8).write(to: home.appendingPathComponent(".zprofile"))
        let paths = AgentHostCommandLines.searchPaths
        #expect(AgentHostCommandLines.resolveExecutable(name, directories: paths, home: home.path) == command.path)
        for id in ["codex", "gemini-cli", "goose", "cursor-cli"] {
            let row = try #require(AgentHostDirectory.row(named: id))
            #expect(row.isInstalled(applicationExists: { _ in false }, executable: {
                _ in AgentHostCommandLines.resolveExecutable(name, directories: paths, home: home.path)
            }))
        }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(Array(paths.prefix(4)) == ["~/.local/bin", "~/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test func fallbackBinsAndBundleLookupDoNotRequireSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-bins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        for directory in AgentHostCommandLines.searchPaths where directory.hasPrefix("~/") {
            let bin = home.appendingPathComponent(String(directory.dropFirst(2)))
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let name = "fixture-\(UUID().uuidString)"
            let command = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            #expect(AgentHostCommandLines.resolveExecutable(name, directories: AgentHostCommandLines.searchPaths, home: home.path) == command.path)
        }
        #expect(AgentHostCommandLines.searchPaths.contains("/opt/homebrew/bin"))
        #expect(AgentHostCommandLines.searchPaths.contains("/usr/local/bin"))
        let row = try #require(AgentHostDirectory.row(named: "codex"))
        #expect(row.isInstalled(applicationExists: { $0 == "com.openai.codex" }, executable: { _ in nil }))
        #expect(!row.isInstalled(applicationExists: { _ in false }, executable: { _ in nil }))
        for id in ["gemini-cli", "goose", "cursor-cli"] {
            let acpRow = try #require(AgentHostDirectory.row(named: id))
            // An app or settings marker alone cannot supply the ACP executable.
            #expect(!acpRow.isInstalled(applicationExists: { _ in true }, executable: { _ in nil }))
        }
    }

    @Test func localPortsIncludeOnlyInstalledDocumentedPorts() throws {
        var row = try #require(AgentHostDirectory.rows.first)
        row.a2aPorts = [12345, 0, 70000]
        let urls = AgentPeerDiscovery.localCandidates(installedHosts: [row])
        #expect(urls.count == 2)
        #expect(urls.contains { $0.port == 12345 })
        #expect(AgentPeerDiscovery.localCandidates(installedHosts: []).isEmpty)
        #expect(AgentPeerDiscovery.localCandidates(installedHosts: AgentHostDirectory.rows).isEmpty)
        for url in urls { try AgentPeerHTTP.validateLoopbackCandidate(url) }
    }

    @Test(arguments: ["https://example.com/card", "http://192.168.1.2/card", "http://localhost:8000/card",
                      "http://127.0.0.1.example.com/card", "http://secret@127.0.0.1/card"])
    func externalCandidatesAreRefusedBeforeTransport(address: String) async {
        await #expect(throws: AgentPeerHTTP.TransportError.invalidURL) {
            try await AgentPeerDiscovery.localCard(URL(string: address)!)
        }
    }

    @Test func cardsAreReadWithoutSecretsAndExternalInterfacesAreRefused() async throws {
        try await AgentPeerHTTP.$fixtureConfiguration.withValue({
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [LocalCardFixture.self]
            return config
        }) {
            let url = URL(string: "http://127.0.0.1:8000/.well-known/agent-card.json")!
            let candidate = try #require(try await AgentPeerDiscovery.localCard(url))
            #expect(candidate.name == "Local helper")
            #expect(candidate.endpoint?.absoluteString == "http://127.0.0.1:8000/a2a")
            #expect(candidate.cardURL == url)
            guard case .object(let fields) = candidate.projection else { Issue.record("Missing candidate"); return }
            #expect(fields["state"] == .string("listed"))
            #expect(fields["agent"] == nil)
            await #expect(throws: AgentPeerHTTP.TransportError.invalidURL) {
                try await AgentPeerDiscovery.localCard(URL(string: "http://127.0.0.1:9000/.well-known/agent-card.json")!)
            }
            #expect(try await AgentPeerDiscovery.localCard(URL(string: "http://127.0.0.1:9999/.well-known/agent-card.json")!) == nil)
        }
    }

    @Test func sessionCacheRefreshesAndCoalescesRequests() async {
        let counter = DiscoveryScanCounter()
        let session = AgentDiscoverySession { await counter.scan() }
        #expect(await session.candidates().isEmpty)
        #expect(await counter.count == 0)
        async let first = session.candidates(refresh: true)
        async let second = session.candidates(refresh: true)
        _ = await (first, second)
        #expect(await counter.count == 1)
        _ = await session.candidates()
        #expect(await counter.count == 1)
        _ = await session.candidates(refresh: true)
        #expect(await counter.count == 2)
    }
}

private actor DiscoveryScanCounter {
    var count = 0
    func scan() async -> [AgentDiscoveryCandidate] {
        count += 1
        try? await Task.sleep(for: .milliseconds(30))
        return []
    }
}

private final class LocalCardFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.timeoutInterval <= 0.6)
        #expect(url.host == "127.0.0.1")
        #expect(url.path == "/.well-known/agent-card.json")
        let endpoint = url.port == 9000 ? "https://example.com/a2a" : "http://localhost:8000/a2a"
        let card: [String: Any] = url.port == 9999 ? ["name": "ordinary website"] : [
            "name": "Local helper", "protocolVersion": "0.3.0", "url": endpoint,
            "capabilities": [:], "skills": [],
            "securitySchemes": ["key": ["type": "http", "scheme": "bearer"]],
            "security": [["key": []]]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: card))
        client?.urlProtocolDidFinishLoading(self)
    }
}
