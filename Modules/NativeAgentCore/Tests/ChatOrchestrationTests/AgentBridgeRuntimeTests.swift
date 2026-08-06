import Foundation
import Testing
@testable import ChatOrchestration

@Suite("Agent bridge runtime discovery")
struct AgentBridgeRuntimeTests {
    @Test("app-only install resolves bundled Codex, Claude, and OMP wakeup helpers")
    func resolvesBundledHelpers() throws {
        let root = try temporaryDirectory("bundled")
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let bundle = resources.appendingPathComponent("NativeAgent_NativeAgentApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let codex = bundle.appendingPathComponent("codex_thread_wakeup.js")
        let claude = bundle.appendingPathComponent("claude_thread_wakeup.js")
        let omp = bundle.appendingPathComponent("omp_thread_wakeup.js")
        try "codex".write(to: codex, atomically: true, encoding: .utf8)
        try "claude".write(to: claude, atomically: true, encoding: .utf8)
        try "omp".write(to: omp, atomically: true, encoding: .utf8)

        let missingRepo = root.appendingPathComponent("no-source-checkout", isDirectory: true)
        #expect(AgentBridgeRuntime.codexHelperURL(
            repoRoot: missingRepo,
            homeDirectory: root,
            bundleResourceRoot: resources,
            environment: [:]
        ) == codex.standardizedFileURL)
        #expect(AgentBridgeRuntime.claudeHelperURL(
            repoRoot: missingRepo,
            bundleResourceRoot: resources,
            environment: [:]
        ) == claude.standardizedFileURL)
        #expect(AgentBridgeRuntime.ompHelperURL(
            repoRoot: missingRepo,
            bundleResourceRoot: resources,
            environment: [:]
        ) == omp.standardizedFileURL)
    }

    @Test("explicit helper override wins over source and bundle candidates")
    func overrideWins() throws {
        let root = try temporaryDirectory("override")
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let script = repo.appendingPathComponent("script", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let bundle = resources.appendingPathComponent("NativeAgent_NativeAgentApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let override = root.appendingPathComponent("override.js")
        for url in [
            override,
            script.appendingPathComponent("codex_thread_wakeup.js"),
            bundle.appendingPathComponent("codex_thread_wakeup.js"),
        ] {
            try "helper".write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(AgentBridgeRuntime.codexHelperURL(
            override: override,
            repoRoot: repo,
            homeDirectory: root,
            bundleResourceRoot: resources,
            environment: [:]
        ) == override.standardizedFileURL)
    }

    @Test("Finder-style PATH still discovers user-local coding CLIs")
    func discoversUserLocalExecutables() throws {
        let root = try temporaryDirectory("executables")
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        #expect(AgentBridgeRuntime.executableURL(
            named: "codex",
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: root
        ) == codex.standardizedFileURL)
    }

    @Test("standalone Codex installer layout is discovered without shell PATH")
    func discoversStandaloneCodex() throws {
        let root = try temporaryDirectory("standalone-codex")
        let codex = root.appendingPathComponent(
            ".codex/packages/standalone/current/bin/codex"
        )
        try FileManager.default.createDirectory(
            at: codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        #expect(AgentBridgeRuntime.executableURL(
            named: "codex",
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: root
        ) == codex.standardizedFileURL)
    }

    @Test("readiness does not confuse installed files with authenticated execution")
    func readinessIsStructuralOnly() throws {
        let root = try temporaryDirectory("readiness")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        let codex = bin.appendingPathComponent("codex")
        for url in [node, codex] {
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let helper = root.appendingPathComponent("helper.js")
        try "helper".write(to: helper, atomically: true, encoding: .utf8)

        let readiness = AgentBridgeRuntime.readiness(
            helper: helper,
            cliName: "codex",
            environment: ["PATH": bin.path],
            homeDirectory: root
        )
        #expect(readiness.readyToAttempt)
        #expect(readiness.helper == helper)
        #expect(readiness.runtime == node)
        #expect(readiness.cli == codex)
        #expect(readiness.readyForAsyncRoundTrip == readiness.returnPath.isReady)
    }

    @Test("return path requires a live internally consistent loopback descriptor")
    func validatesReturnPath() throws {
        let root = try temporaryDirectory("return-path")
        let bridge = root.appendingPathComponent("claude-bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try "private-test-token".write(
            to: bridge.appendingPathComponent("token"),
            atomically: true,
            encoding: .utf8
        )
        let descriptor: [String: Any] = [
            "host": "127.0.0.1",
            "port": 49152,
            "url": "http://127.0.0.1:49152",
            "token": "private-test-token",
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
        ]
        try JSONSerialization.data(withJSONObject: descriptor).write(
            to: bridge.appendingPathComponent("bridge.json")
        )

        let readiness = AgentBridgeRuntime.returnPathReadiness(configRoot: root)
        #expect(readiness.isReady)
        #expect(readiness.reason == "ready")
        #expect(readiness.endpoint?.absoluteString == "http://127.0.0.1:49152")
        #expect(String(describing: readiness).contains("private-test-token") == false)
    }

    @Test("return path rejects missing, mismatched, remote, and dead discovery")
    func rejectsInvalidReturnPaths() throws {
        let root = try temporaryDirectory("invalid-return-path")
        let bridge = root.appendingPathComponent("claude-bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        #expect(AgentBridgeRuntime.returnPathReadiness(configRoot: root).reason == "token_missing")

        try "token-a".write(to: bridge.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        func writeDescriptor(token: String, url: String, host: String, port: Int, pid: Int32) throws {
            let object: [String: Any] = [
                "host": host, "port": port, "url": url, "token": token,
                "processIdentifier": pid,
            ]
            try JSONSerialization.data(withJSONObject: object).write(
                to: bridge.appendingPathComponent("bridge.json")
            )
        }
        try writeDescriptor(token: "token-b", url: "http://127.0.0.1:49152", host: "127.0.0.1", port: 49152, pid: ProcessInfo.processInfo.processIdentifier)
        #expect(AgentBridgeRuntime.returnPathReadiness(configRoot: root).reason == "token_descriptor_mismatch")

        try writeDescriptor(token: "token-a", url: "https://example.com:49152", host: "example.com", port: 49152, pid: ProcessInfo.processInfo.processIdentifier)
        #expect(AgentBridgeRuntime.returnPathReadiness(configRoot: root).reason == "endpoint_not_loopback_http")

        try writeDescriptor(token: "token-a", url: "http://127.0.0.1:49152", host: "127.0.0.1", port: 49152, pid: Int32.max)
        #expect(AgentBridgeRuntime.returnPathReadiness(configRoot: root).reason == "publisher_not_running")
    }

    private func temporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bridge-runtime-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
