import Foundation
import Testing

@Suite("feeds.mcp harness", .serialized)
struct MCPFeedHarnessEvalTests {
    private let repo = ScriptFenceEval.repo

    private func makeDataRoot() throws -> URL {
        try ScriptFenceEval.makeTempDir("mcp-feed-harness")
            .appendingPathComponent("data", isDirectory: true)
    }

    private func write(_ text: String, under root: URL) throws {
        let path = root.appendingPathComponent("activity/events.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    private func report(_ root: URL) throws -> ScriptFenceEval.RunResult {
        try ScriptFenceEval.run(
            "/usr/bin/env",
            ["swift", repo.appendingPathComponent("script/feed_coverage_eval.swift").path,
             "--data-root", root.path, "--days", "7"],
            cwd: repo,
            environment: ScriptFenceEval.environment(stubDir: nil),
            timeout: 45
        )
    }

    @Test("MCP feed harness reads bounded durable receipts and rejects incoherent evidence metadata")
    func mcpReceiptsAreClassifiedAndValidated() throws {
        let data = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let now = ISO8601DateFormatter().string(from: Date())
        let digest = String(repeating: "a", count: 64)
        try write("""
        {"id":"other","kind":"scheduler","createdAt":"\(now)"}
        {"id":"mcp-ok","kind":"mcp_tool","status":"ok","createdAt":"\(now)","payload":{"callId":"call-ok","serverId":"local","toolName":"search","toolStatus":"ok","transportOutcome":"response_received","durationSeconds":0.1,"result":{},"resultByteCount":2,"redactedByteCount":2,"resultTruncated":false,"resultDigest":"\(digest)"}}
        {"id":"mcp-error","kind":"mcp_tool","status":"warn","createdAt":"\(now)","payload":{"callId":"call-error","serverId":"local","toolName":"search","toolStatus":"error","transportOutcome":"remote_reported_error","durationSeconds":0.2,"result":{},"resultByteCount":2,"redactedByteCount":2,"resultTruncated":false,"resultDigest":"\(digest)"}}
        """, under: data)

        let healthy = try report(data)
        #expect(healthy.status == 0, Comment(rawValue: healthy.combined))
        #expect(healthy.stdout.contains("`feeds.mcp` | **ACTIVE** | 2"))
        #expect(healthy.stdout.contains("receipt reader: 2 durable MCP receipt(s), 1 ok, 1 error, 0 other status"))

        try write("""
        {"id":"mcp-bad","kind":"mcp_tool","status":"ok","createdAt":"\(now)","payload":{"callId":"call-bad","serverId":"local","toolName":"search","toolStatus":"ok","transportOutcome":"response_received","durationSeconds":0.1,"result":{},"resultByteCount":2,"redactedByteCount":3,"resultTruncated":false,"resultDigest":"\(digest)"}}
        """, under: data)
        let corrupt = try report(data)
        #expect(corrupt.stdout.contains("`feeds.mcp` | **UNREADABLE** | 1"))
        #expect(corrupt.stdout.contains("durable Activity envelope or redaction metadata contract"))
    }
}
