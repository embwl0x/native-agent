import Testing
import Foundation
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// LIVE probe, opt-in TWICE: it runs only with A3_LIVE_CACHE_PROBE=1 AND an
// explicit auth.json path in A3_LIVE_PROBE_AUTH_PATH. Two switches on purpose —
// a token refresh ROTATES the single-use refresh_token in whatever auth file it
// resolves, so a probe that silently fell back to the running app's credentials
// could knock the live app off its account. Point it at a copy, never at
// data/codex_home/auth.json of a running install.
//
// What it measures: whether the `tools` array sits inside the cached request
// prefix on the openai_oauth_direct lane. Four calls, one session id (the
// routing header the 2026-09-11 fix added), a fixed instruction prefix, history
// growing two messages per call exactly like a real turn:
//
//   1. warm the node (tools T1)
//   2. same tools, longer history  -> a cross-turn read is expected
//   3. ONE TOOL REMOVED           -> the read is expected to collapse to 0
//   4. same reduced tools again    -> the read is expected to come back
@Suite("A3 live tools-prefix cache probe", .serialized)
struct A3LiveToolsPrefixCacheProbe {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["A3_LIVE_CACHE_PROBE"] == "1"
            && authPath != nil
    }

    static var authPath: URL? {
        guard let raw = ProcessInfo.processInfo.environment["A3_LIVE_PROBE_AUTH_PATH"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    private func tool(_ index: Int) -> LLMToolSchema {
        LLMToolSchema(
            name: "probe_tool_\(index)",
            description: String(
                repeating: "Probe tool \(index) exists only to occupy schema bytes. ",
                count: 8
            ),
            parametersJSON: Data(
                """
                {"type":"object","properties":{"query":{"type":"string","description":"\(String(repeating: "q", count: 200))"}},"required":["query"]}
                """.utf8
            )
        )
    }

    @Test(
        "live: dropping one tool from the array costs the whole cached prefix",
        .enabled(if: A3LiveToolsPrefixCacheProbe.enabled)
    )
    func toolsAreInThePrefix() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a3-live-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = OpenAIOAuthDirectAdapter(
            authPathOverride: Self.authPath,
            telemetryDataRootOverride: root
        )
        let system = String(
            repeating: "You are a measurement fixture. Answer every message with the single word OK. ",
            count: 320
        )
        let fullTools = (0..<20).map(tool)
        let reducedTools = Array(fullTools.dropLast())
        let sessionId = "A3PROBE-\(UUID().uuidString)"

        func history(_ pairs: Int) -> [LLMMessage] {
            var out: [LLMMessage] = []
            for index in 0..<pairs {
                out.append(LLMMessage(role: .user, content: [.text("Fixture turn \(index). Say OK.")]))
                out.append(LLMMessage(role: .assistant, content: [.text("OK")]))
            }
            out.append(LLMMessage(role: .user, content: [.text("Say OK.")]))
            return out
        }

        func call(_ label: String, pairs: Int, tools: [LLMToolSchema]) async throws {
            _ = try await LLMCallContext.$sessionId.withValue(sessionId) {
                try await LLMCallContext.$surface.withValue("chat") {
                    try await adapter.completeMessages(
                        messages: history(pairs),
                        system: system,
                        model: "gpt-6-astra",
                        tools: tools
                    )
                }
            }
            print("A3PROBE \(label): \(latestUsage(root: root))")
        }

        try await call("1 warm (20 tools)", pairs: 1, tools: fullTools)
        try await call("2 same tools, +2 messages", pairs: 2, tools: fullTools)
        try await call("3 ONE TOOL REMOVED, +2 messages", pairs: 3, tools: reducedTools)
        try await call("4 same reduced tools, +2 messages", pairs: 4, tools: reducedTools)
    }

    private func latestUsage(root: URL) -> String {
        let path = root
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "no rows" }
        guard let line = text.split(separator: "\n").last,
              let data = String(line).data(using: .utf8),
              let value = try? JSONValue.parse(data),
              case .object(let row) = value,
              case .object(let payload)? = row["payload"] else { return "unreadable row" }
        func int(_ key: String) -> String {
            if case .int(let number)? = payload[key] { return String(number) }
            return "-"
        }
        return "input=\(int("inputTokens")) cached=\(int("cacheReadInputTokens"))"
    }
}
