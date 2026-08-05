import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - helpers

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sessionhistory-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeMessagesJSONL(root: URL, sessionId: String, lines: [String]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
                  .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(sessionId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: path, atomically: true, encoding: .utf8)
}

private func writeSessionsJSON(root: URL, sessions: [[String: String]]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("sessions.json")
    var arr: [JSONValue] = []
    for s in sessions {
        var obj: [String: JSONValue] = [:]
        for (k, v) in s { obj[k] = .string(v) }
        arr.append(.object(obj))
    }
    let bytes = try JSONValue.array(arr).serializedData(pretty: true)
    try bytes.write(to: path)
}

private func msgLine(
    role: String,
    content: String,
    createdAt: String,
    runId: String? = nil,
    metadata: JSONValue? = nil
) -> String {
    var fields: [String: JSONValue] = [
        "id": .string(UUID().uuidString),
        "role": .string(role),
        "content": .string(content),
        "createdAt": .string(createdAt),
    ]
    if let runId { fields["runId"] = .string(runId) }
    if let metadata { fields["metadata"] = metadata }
    let obj: JSONValue = .object(fields)
    return (try? obj.serialize(pretty: false)) ?? "{}"
}

// MARK: - SessionHistoryReader

@Test
func SessionHistoryReader_messages_returns_chronological_order() async throws {
    let root = try makeTempRoot("chrono")
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: [
        msgLine(role: "user", content: "first",  createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "second", createdAt: "2026-05-31T10:00:01Z"),
        msgLine(role: "user", content: "third",  createdAt: "2026-05-31T10:00:02Z"),
    ])
    let reader = SessionHistoryReader(dataRoot: root)
    let msgs = try await reader.messages(forSessionId: "s1")
    #expect(msgs.count == 3)
    #expect(msgs[0].content == "first")
    #expect(msgs[1].content == "second")
    #expect(msgs[2].content == "third")
}

@Test
func SessionHistoryReader_messages_handles_missing_file_returns_empty() async throws {
    let root = try makeTempRoot("missing")
    let reader = SessionHistoryReader(dataRoot: root)
    let msgs = try await reader.messages(forSessionId: "unknown")
    #expect(msgs.isEmpty)
}

@Test
func SessionHistoryReader_messages_rejects_path_traversal_session_id() async throws {
    let root = try makeTempRoot("traversal")
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    let escapedPath = chatDir.appendingPathComponent("evil.jsonl")
    try (msgLine(role: "user", content: "escaped", createdAt: "2026-05-31T10:00:00Z") + "\n")
        .write(to: escapedPath, atomically: true, encoding: .utf8)

    let reader = SessionHistoryReader(dataRoot: root)
    let msgs = try await reader.messages(forSessionId: "../evil")

    #expect(msgs.isEmpty)
}

@Test
func SessionHistoryReader_messages_handles_malformed_JSONL_lines_skipping_bad_ones() async throws {
    let root = try makeTempRoot("malformed")
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: [
        msgLine(role: "user", content: "ok-one", createdAt: "2026-05-31T10:00:00Z"),
        "this is not json at all",
        "{\"role\": \"user\"}", // missing content — should be skipped
        msgLine(role: "assistant", content: "ok-two", createdAt: "2026-05-31T10:00:01Z"),
    ])
    let reader = SessionHistoryReader(dataRoot: root)
    let msgs = try await reader.messages(forSessionId: "s1")
    #expect(msgs.count == 2)
    #expect(msgs[0].content == "ok-one")
    #expect(msgs[1].content == "ok-two")
}

@Test
func SessionHistoryReader_messages_with_limit_returns_last_N() async throws {
    let root = try makeTempRoot("limit")
    var lines: [String] = []
    for i in 0..<10 {
        lines.append(msgLine(
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: "msg-\(i)",
            createdAt: "2026-05-31T10:00:0\(i)Z"
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: lines)
    let reader = SessionHistoryReader(dataRoot: root)
    let msgs = try await reader.messages(forSessionId: "s1", limit: 3)
    #expect(msgs.count == 3)
    #expect(msgs[0].content == "msg-7")
    #expect(msgs[1].content == "msg-8")
    #expect(msgs[2].content == "msg-9")
}

@Test
func SessionHistoryReader_messagesWithStats_reports_bounded_read_metadata() async throws {
    let root = try makeTempRoot("stats-limit")
    var lines: [String] = []
    for i in 0..<12 {
        lines.append(msgLine(
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: "stats-msg-\(i)",
            createdAt: "2026-05-31T10:00:\(String(format: "%02d", i))Z"
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s-stats", lines: lines)
    let reader = SessionHistoryReader(dataRoot: root)

    let limited = try await reader.messagesWithStats(forSessionId: "s-stats", limit: 3)
    let full = try await reader.messagesWithStats(forSessionId: "s-stats")

    #expect(limited.messages.map(\.content) == ["stats-msg-9", "stats-msg-10", "stats-msg-11"])
    #expect(limited.stats.mode == "tail")
    #expect(limited.stats.returnedCount == 3)
    #expect(limited.stats.decodedCount == 12)
    #expect(limited.stats.linesRead == 12)
    #expect(limited.stats.sourceBytes > 0)
    #expect(limited.stats.bytesRead > 0)
    #expect(limited.stats.truncated)
    #expect(full.stats.mode == "full")
    #expect(full.stats.returnedCount == 12)
    #expect(!full.stats.truncated)
}

@Test
func SessionHistoryReader_largeToolTranscript_keepsPromptAndRelevanceReadsBounded() async throws {
    let root = try makeTempRoot("bounded-heavy-tools")
    let giantResult = String(repeating: "x", count: 56_000)
    var lines: [String] = [
        msgLine(role: "user", content: "OPENING-BOUNDARY", createdAt: "2026-05-31T10:00:00Z"),
    ]
    for i in 0..<18 {
        lines.append(msgLine(
            role: "tool",
            content: "",
            createdAt: "2026-05-31T10:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60))Z",
            metadata: .object([
                "toolName": .string("tool_catalog"),
                "resultSummary": .string("result-\(i)-\(giantResult)"),
            ])
        ))
        lines.append(msgLine(
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: "small continuity row \(i)",
            createdAt: "2026-05-31T11:00:\(String(format: "%02d", i))Z"
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s-heavy", lines: lines)
    let reader = SessionHistoryReader(dataRoot: root)

    let prompt = try await reader.promptMessagesWithStats(
        forSessionId: "s-heavy",
        anchorLimit: 3,
        tailLimit: 80
    )
    let relevance = try await reader.relevanceMessagesWithStats(forSessionId: "s-heavy")

    #expect(prompt.stats.sourceBytes > 800_000)
    #expect(prompt.stats.bytesRead <= 256 * 1024)
    #expect(prompt.stats.bytesRead < prompt.stats.sourceBytes)
    #expect(prompt.stats.truncated)
    #expect(prompt.messages.contains(where: { $0.content == "OPENING-BOUNDARY" }))

    #expect(relevance.stats.mode == "relevance_sampled")
    #expect(relevance.stats.bytesRead <= 96 * 1024)
    #expect(relevance.stats.bytesRead < relevance.stats.sourceBytes)
    #expect(relevance.stats.truncated)
}

@Test
func SessionHistoryReader_messages_can_exclude_current_run_id() async throws {
    let root = try makeTempRoot("exclude-run")
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: [
        msgLine(role: "user", content: "prior", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "user", content: "CURRENT-RUN", createdAt: "2026-05-31T10:00:01Z", runId: "run-current"),
        msgLine(role: "assistant", content: "same-run-tool-loop", createdAt: "2026-05-31T10:00:02Z", runId: "run-current"),
        msgLine(role: "assistant", content: "older assistant", createdAt: "2026-05-31T10:00:03Z"),
    ])
    let reader = SessionHistoryReader(dataRoot: root)
    let msgs = try await reader.messages(forSessionId: "s1", excludingRunId: "run-current")
    #expect(msgs.map(\.content) == ["prior", "older assistant"])
}

@Test
func SessionHistoryReader_session_metadata_returns_record() async throws {
    let root = try makeTempRoot("sessmeta")
    try writeSessionsJSON(root: root, sessions: [
        ["id": "alpha", "createdAt": "2026-05-30T09:00:00Z", "title": "Alpha Chat"],
        ["id": "beta",  "createdAt": "2026-05-31T09:00:00Z", "title": "Beta Chat"],
    ])
    let reader = SessionHistoryReader(dataRoot: root)
    let sess = try await reader.session(id: "beta")
    #expect(sess?.id == "beta")
    #expect(sess?.title == "Beta Chat")
    #expect(sess?.createdAt == "2026-05-31T09:00:00Z")
}

@Test
func SessionHistoryReader_session_metadata_unknown_id_returns_nil() async throws {
    let root = try makeTempRoot("sessunknown")
    try writeSessionsJSON(root: root, sessions: [
        ["id": "alpha", "createdAt": "2026-05-30T09:00:00Z", "title": "Alpha"],
    ])
    let reader = SessionHistoryReader(dataRoot: root)
    let sess = try await reader.session(id: "does-not-exist")
    #expect(sess == nil)
}

// MARK: - buildTurnContextWithHistory

private final class StubRouting2: ProviderRoutingProtocol, @unchecked Sendable {
    let prefs: [String: SurfacePreference]
    let activeProviders: [String: String]
    init(
        prefs: [String: SurfacePreference],
        activeProviders: [String: String] = [:]
    ) {
        self.prefs = prefs
        self.activeProviders = activeProviders
    }
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] { prefs }
    func activeProvidersForSurfaces() async -> [String: String] { activeProviders }
}

private func makeEngine2(
    personaRoot: URL,
    llm: any LLMClient,
    memory: (any MemoryRecalling)? = nil
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: memory,
        router: StubRouting2(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: llm,
        tools: MockToolDispatchClient()
    )
}

@Test
func buildTurnContextWithHistory_includes_user_assistant_turns_in_systemPrompt() async throws {
    let root = try makeTempRoot("history-in-sysprompt")
    try writeMessagesJSONL(root: root, sessionId: "s-Z", lines: [
        msgLine(role: "user", content: "MARKER-USER-1", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "MARKER-ASST-1", createdAt: "2026-05-31T10:00:01Z"),
    ])
    let personaDir = try makeTempRoot("persona-1")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-Z",
        historyLimit: 20, historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(sp.contains("Conversation history:"))
    #expect(sp.contains("[user] MARKER-USER-1"))
    #expect(sp.contains("[assistant] MARKER-ASST-1"))
}

@Test
func buildTurnContextWithHistory_shortApprovalAnchorsPreviousAssistant() async throws {
    let root = try makeTempRoot("history-short-approval")
    try writeMessagesJSONL(root: root, sessionId: "s-short", lines: [
        msgLine(role: "user", content: "look at SOUL.md", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(
            role: "assistant",
            content: "Want me to fix that reference so it points at the real location?",
            createdAt: "2026-05-31T10:00:01Z"
        ),
    ])
    let personaDir = try makeTempRoot("persona-short-approval")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "telegram",
        userMessage: "Yeah go ahead",
        sessionId: "s-short",
        historyLimit: 20,
        historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(sp.contains("Immediate reply reference:"))
    #expect(sp.contains("short approval or continuation"))
    #expect(sp.contains("Want me to fix that reference so it points at the real location?"))
}

@Test
func buildTurnContextWithHistory_chronological_order_oldest_first() async throws {
    let root = try makeTempRoot("history-order")
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: [
        msgLine(role: "user", content: "AAA-oldest", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "BBB-mid", createdAt: "2026-05-31T10:00:01Z"),
        msgLine(role: "user", content: "CCC-newest", createdAt: "2026-05-31T10:00:02Z"),
    ])
    let personaDir = try makeTempRoot("persona-2")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s1",
        historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    guard let a = sp.range(of: "AAA-oldest"),
          let b = sp.range(of: "BBB-mid"),
          let c = sp.range(of: "CCC-newest") else {
        Issue.record("missing markers in systemPrompt")
        return
    }
    #expect(a.lowerBound < b.lowerBound)
    #expect(b.lowerBound < c.lowerBound)
}

@Test
func buildTurnContextWithHistory_respects_historyLimit() async throws {
    let root = try makeTempRoot("history-limit")
    var lines: [String] = []
    for i in 0..<8 {
        lines.append(msgLine(
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: "TURN-\(i)",
            createdAt: "2026-05-31T10:00:0\(i)Z"
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: lines)
    let personaDir = try makeTempRoot("persona-3")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s1",
        historyLimit: 2, historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(sp.contains("TURN-6"))
    #expect(sp.contains("TURN-7"))
    #expect(!sp.contains("TURN-0"))
    #expect(!sp.contains("TURN-5"))
}

@Test
func buildTurnContextWithHistory_excludes_current_user_run_from_systemPrompt() async throws {
    let root = try makeTempRoot("history-exclude-current")
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: [
        msgLine(role: "user", content: "REAL-PRIOR-TURN", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "REAL-PRIOR-ANSWER", createdAt: "2026-05-31T10:00:01Z"),
        msgLine(role: "user", content: "CURRENT-TURN-SHOULD-NOT-BE-HISTORY", createdAt: "2026-05-31T10:00:02Z", runId: "run-now"),
    ])
    let personaDir = try makeTempRoot("persona-exclude")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat",
        userMessage: "CURRENT-TURN-SHOULD-NOT-BE-HISTORY",
        sessionId: "s1",
        historyLimit: 20,
        historyReader: reader,
        personaOverride: nil,
        excludeHistoryRunId: "run-now"
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(sp.contains("REAL-PRIOR-TURN"))
    #expect(!sp.contains("[user] CURRENT-TURN-SHOULD-NOT-BE-HISTORY"))
    #expect(ctx.userMessage == "CURRENT-TURN-SHOULD-NOT-BE-HISTORY")
}

@Test
func buildTurnContextWithHistory_long_session_keeps_continuity_anchors_and_search_hint() async throws {
    let root = try makeTempRoot("history-continuity")
    var lines: [String] = []
    for i in 0..<60 {
        let role = i.isMultiple(of: 2) ? "user" : "assistant"
        let content: String
        if i == 0 {
            content = "OPENING-ANCHOR native Swift conversion"
        } else if i == 57 {
            content = "LATEST-ASSISTANT open loop: I can patch the context next?"
        } else if i == 58 {
            content = "LATEST-USER correction actually keep Agent context"
        } else {
            content = "turn-\(i)"
        }
        lines.append(msgLine(
            role: role,
            content: content,
            createdAt: "2026-05-31T10:00:\(String(format: "%02d", i % 60))Z"
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s1", lines: lines)
    let personaDir = try makeTempRoot("persona-continuity")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat",
        userMessage: "what did I just ask you to keep?",
        sessionId: "s1",
        historyLimit: 12,
        historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(sp.contains("SESSION_CONTINUITY_STATE:"))
    #expect(sp.contains("OPENING-ANCHOR native Swift conversion"))
    #expect(sp.contains("LATEST-USER correction actually keep Agent context"))
    #expect(sp.contains("search_chat_history/session_search"))
    #expect(sp.contains("Conversation history:"))
    #expect(sp.contains("[NOTICE: Earlier session details are elided."))
}

@Test
func buildTurnContextWithHistory_addsRelevantMiddleSessionSnippets() async throws {
    let root = try makeTempRoot("history-middle-snippets")
    var lines: [String] = []
    for i in 0..<90 {
        let role = i.isMultiple(of: 2) ? "user" : "assistant"
        let content: String
        if i == 0 {
            content = "OPENING-ANCHOR morning chat"
        } else if i == 20 {
            content = "MIDDLE-MARKER coffee calibration belongs in the session middle"
        } else if i == 89 {
            content = "CURRENT-RUN coffee calibration should not be rendered as prior context"
        } else {
            content = "ordinary turn \(i) unrelated"
        }
        lines.append(msgLine(
            role: role,
            content: content,
            createdAt: "2026-05-31T10:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60))Z",
            runId: i == 89 ? "run-now" : nil
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s-middle", lines: lines)
    let personaDir = try makeTempRoot("persona-middle")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "telegram",
        userMessage: "what was the coffee calibration thing?",
        sessionId: "s-middle",
        historyLimit: 8,
        historyReader: reader,
        personaOverride: nil,
        excludeHistoryRunId: "run-now"
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(sp.contains("Relevant earlier session snippets:"))
    #expect(sp.contains("MIDDLE-MARKER coffee calibration belongs in the session middle"))
    #expect(!sp.contains("CURRENT-RUN coffee calibration should not be rendered"))
    #expect(sp.contains("ordinary turn 88 unrelated"))
    guard let middle = sp.range(of: "Relevant earlier session snippets:"),
          let history = sp.range(of: "Conversation history:") else {
        Issue.record("missing middle/history sections in systemPrompt")
        return
    }
    #expect(middle.lowerBound < history.lowerBound)
}

@Test
func buildTurnContextWithHistory_empty_history_falls_back_to_normal_buildTurnContext() async throws {
    let root = try makeTempRoot("history-empty")
    // No chat/messages dir created — should fall back cleanly.
    let personaDir = try makeTempRoot("persona-4")
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hello",
        sessionId: "no-such-session",
        historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    #expect(!sp.contains("Conversation history:"))
    #expect(ctx.userMessage == "hello")
}

// MARK: - caching-contract segment order (U1 step 2)

private struct FixedRecallStub: MemoryRecalling {
    let hits: [MemoryRecallHit]
    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] { hits }
}

private actor CapturingRecallStub: MemoryRecalling {
    private var queries: [String] = []

    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        queries.append(query)
        return []
    }

    func lastQuery() -> String? {
        queries.last
    }
}

@Test
func buildTurnContextWithHistory_expandsRecallQueryWithSessionContinuity() async throws {
    let root = try makeTempRoot("history-recall-query")
    try writeMessagesJSONL(root: root, sessionId: "s-recall", lines: [
        msgLine(role: "user", content: "OPENING-ANCHOR native Swift memory", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "We found AGENT-DREAM-CYCLE belongs in Swift.", createdAt: "2026-05-31T10:00:01Z"),
        msgLine(role: "user", content: "actually keep AGENT-DREAM-CYCLE in Swift memory", createdAt: "2026-05-31T10:00:02Z"),
        msgLine(role: "assistant", content: "I can patch HYBRID-RECALL next?", createdAt: "2026-05-31T10:00:03Z"),
        msgLine(role: "user", content: "CURRENT-HISTORY-ROW-SHOULD-NOT-ENTER", createdAt: "2026-05-31T10:00:04Z", runId: "run-now"),
    ])
    let personaDir = try makeTempRoot("persona-recall-query")
    let recall = CapturingRecallStub()
    let engine = makeEngine2(
        personaRoot: personaDir,
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        memory: recall
    )
    let reader = SessionHistoryReader(dataRoot: root)

    _ = try await engine.buildTurnContextWithHistory(
        surface: "telegram",
        userMessage: "can you do that recall thing?",
        sessionId: "s-recall",
        historyLimit: 12,
        historyReader: reader,
        personaOverride: nil,
        excludeHistoryRunId: "run-now"
    )

    let query = try #require(await recall.lastQuery())
    #expect(query.contains("Current user: can you do that recall thing?"))
    #expect(query.contains("OPENING-ANCHOR native Swift memory"))
    #expect(query.contains("AGENT-DREAM-CYCLE"))
    #expect(query.contains("HYBRID-RECALL"))
    #expect(!query.contains("CURRENT-HISTORY-ROW-SHOULD-NOT-ENTER"))
    #expect(query.count <= 1_200)
}

@Test
func buildTurnContextWithHistory_caching_contract_stable_segments_before_dynamic_history() async throws {
    // CACHING CONTRACT (U1 step 2): the rendered system prompt must be
    // STABLE → SEMI-STABLE → DYNAMIC so provider prefix caches survive
    // across turns:
    //   persona packet → REM pins → memory recall → history block.
    // The history block (SESSION_CONTINUITY_STATE + Conversation history)
    // is per-turn dynamic and must land at the TAIL, never at byte 0.
    let root = try makeTempRoot("history-cache-order")
    var lines: [String] = []
    for i in 0..<12 {
        lines.append(msgLine(
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: "HIST-TURN-\(i)",
            createdAt: "2026-05-31T10:00:\(String(format: "%02d", i))Z"
        ))
    }
    try writeMessagesJSONL(root: root, sessionId: "s-cache", lines: lines)

    // Persona doc (STABLE segment).
    let personaDir = try makeTempRoot("persona-cache-order")
    try "PERSONA-MARKER-STABLE body of the persona doc."
        .write(to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

    // REM pin (SEMI-STABLE segment) — rem_pins.json in the same dataRoot.
    let pinsJSON = """
    {"SOUL.md": [{"id": "pin-1", "text": "PIN-MARKER-SEMISTABLE", "createdAt": "2026-06-01T00:00:00Z"}]}
    """
    try pinsJSON.write(to: root.appendingPathComponent("rem_pins.json"), atomically: true, encoding: .utf8)

    // Memory recall (per-turn, but more stable than raw history).
    let recall = FixedRecallStub(hits: [
        MemoryRecallHit(score: 0.9, preview: "RECALL-MARKER-CONTEXTUAL"),
    ])

    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaDir),
        memory: recall,
        router: StubRouting2(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: root,
        memoryPromoter: nil
    )
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-cache",
        historyLimit: 8, historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""

    // History must NOT sit at the head of the prompt (the old prepend order).
    #expect(!sp.hasPrefix("SESSION_CONTINUITY_STATE:"))
    #expect(!sp.hasPrefix("Conversation history:"))

    guard let persona = sp.range(of: "PERSONA-MARKER-STABLE"),
          let pins = sp.range(of: "# Pinned facts (REM-approved overrides)"),
          let pinText = sp.range(of: "PIN-MARKER-SEMISTABLE"),
          let recallHeader = sp.range(of: "Recent memory:"),
          let recallText = sp.range(of: "RECALL-MARKER-CONTEXTUAL"),
          let continuity = sp.range(of: "SESSION_CONTINUITY_STATE:"),
          let history = sp.range(of: "Conversation history:") else {
        Issue.record("missing segment markers in systemPrompt:\n\(sp)")
        return
    }
    // STABLE → SEMI-STABLE → DYNAMIC:
    #expect(persona.lowerBound < pins.lowerBound)           // persona before pins
    #expect(pins.lowerBound < pinText.lowerBound)           // pin text under its header
    #expect(pinText.lowerBound < recallHeader.lowerBound)   // pins before recall
    #expect(recallHeader.lowerBound < recallText.lowerBound)
    #expect(recallText.lowerBound < continuity.lowerBound)  // recall before history block
    #expect(continuity.lowerBound < history.lowerBound)     // continuity heads the history block
}

// MARK: - segmented system threading (U1 step 2b/3b)

@Test
func buildTurnContextWithHistory_populates_systemSegments_stable_personaPins_dynamic_recallHistory() async throws {
    // Same fixture as the caching-contract test above, but asserting the
    // ADDITIVE stable/dynamic split: stable = persona packet + REM pins,
    // dynamic = memory recall + history block, and the byte-level
    // INVARIANT systemPrompt == stable + "\n\n" + dynamic.
    let root = try makeTempRoot("segments-split")
    try writeMessagesJSONL(root: root, sessionId: "s-seg", lines: [
        msgLine(role: "user", content: "HIST-MARKER-DYNAMIC", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "HIST-ANSWER", createdAt: "2026-05-31T10:00:01Z"),
    ])
    let personaDir = try makeTempRoot("persona-segments")
    try "PERSONA-MARKER-STABLE body of the persona doc."
        .write(to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    let pinsJSON = """
    {"SOUL.md": [{"id": "pin-1", "text": "PIN-MARKER-SEMISTABLE", "createdAt": "2026-06-01T00:00:00Z"}]}
    """
    try pinsJSON.write(to: root.appendingPathComponent("rem_pins.json"), atomically: true, encoding: .utf8)
    let recall = FixedRecallStub(hits: [
        MemoryRecallHit(score: 0.9, preview: "RECALL-MARKER-CONTEXTUAL"),
    ])
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaDir),
        memory: recall,
        router: StubRouting2(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: root,
        memoryPromoter: nil
    )
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-seg",
        historyLimit: 8, historyReader: reader
    )

    guard let seg = ctx.systemSegments else {
        Issue.record("systemSegments not populated by buildTurnContextWithHistory")
        return
    }
    // Stable: persona + pins, NO per-turn content.
    #expect(seg.stable.contains("PERSONA-MARKER-STABLE"))
    #expect(seg.stable.contains("PIN-MARKER-SEMISTABLE"))
    #expect(!seg.stable.contains("RECALL-MARKER-CONTEXTUAL"))
    #expect(!seg.stable.contains("Conversation history:"))
    // Dynamic: recall + history, NO persona/pins.
    #expect(seg.dynamic.contains("RECALL-MARKER-CONTEXTUAL"))
    #expect(seg.dynamic.contains("Conversation history:"))
    #expect(seg.dynamic.contains("HIST-MARKER-DYNAMIC"))
    #expect(!seg.dynamic.contains("PERSONA-MARKER-STABLE"))
    #expect(!seg.dynamic.contains("PIN-MARKER-SEMISTABLE"))
    // INVARIANT byte-check: combined systemPrompt == stable + "\n\n" + dynamic.
    #expect(ctx.systemPrompt == seg.stable + "\n\n" + seg.dynamic)
    #expect(seg.reassembles(into: ctx.systemPrompt ?? ""))
}

@Test
func buildTurnContextWithHistory_appends_clock_context_after_history_tail() async throws {
    let root = try makeTempRoot("history-clock")
    try writeMessagesJSONL(root: root, sessionId: "s-clock", lines: [
        msgLine(role: "user", content: "history before the clock", createdAt: "2026-05-31T10:00:00Z"),
        msgLine(role: "assistant", content: "history reply", createdAt: "2026-05-31T10:00:01Z"),
    ])
    let personaDir = try makeTempRoot("persona-clock")
    try "CLOCK-HISTORY-STABLE"
        .write(to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(utc.date(from: DateComponents(
        year: 2026, month: 6, day: 17, hour: 11, minute: 31
    )))
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaDir),
        memory: nil,
        router: StubRouting2(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        clock: { now },
        memoryPromoter: nil
    )
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "continue", sessionId: "s-clock",
        historyLimit: 8, historyReader: SessionHistoryReader(dataRoot: root)
    )
    let seg = try #require(ctx.systemSegments)
    let history = try #require(seg.dynamic.range(of: "Conversation history:"))
    let clock = try #require(seg.dynamic.range(of: "Current time:"))
    let runtime = try #require(seg.dynamic.range(of: "Current runtime:"))

    #expect(seg.stable.contains("CLOCK-HISTORY-STABLE"))
    #expect(!seg.stable.contains("Current time:"))
    #expect(!seg.stable.contains("Current runtime:"))
    #expect(history.lowerBound < clock.lowerBound)
    #expect(clock.lowerBound < runtime.lowerBound)
    #expect(seg.dynamic.contains("surface=chat"))
    #expect(seg.dynamic.contains("provider=openai_oauth_direct"))
    #expect(seg.dynamic.contains("model=gpt-5.5"))
    #expect(ctx.systemPrompt == seg.combined)
}

@Test
func buildTurnContext_noHistory_segments_invariant_holds() async throws {
    // buildTurnContext (no history threading) also populates segments and
    // keeps the invariant — dynamic carries recall only.
    let personaDir = try makeTempRoot("persona-segments-nohist")
    try "PERSONA-ONLY-STABLE".write(
        to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8
    )
    let recall = FixedRecallStub(hits: [
        MemoryRecallHit(score: 0.8, preview: "RECALL-ONLY-DYNAMIC"),
    ])
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaDir),
        memory: recall,
        router: StubRouting2(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        memoryPromoter: nil
    )
    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "hi")
    guard let seg = ctx.systemSegments else {
        Issue.record("systemSegments not populated by buildTurnContext")
        return
    }
    #expect(seg.stable.contains("PERSONA-ONLY-STABLE"))
    #expect(seg.dynamic.contains("RECALL-ONLY-DYNAMIC"))
    #expect(!seg.stable.contains("RECALL-ONLY-DYNAMIC"))
    #expect(ctx.systemPrompt == seg.combined)
}

// Vision wave (integration review 2026-06-11): an image turn must survive
// the history rebuild as a compact reference — image-only turns vanished
// (empty content dropped), captioned ones lost the image entirely.
@Test
func buildTurnContextWithHistory_image_turn_renders_compact_reference() async throws {
    let root = try makeTempRoot("history-image")
    let personaDir = try makeTempRoot("persona-img")
    try writeMessagesJSONL(root: root, sessionId: "img-session", lines: [
        #"{"role":"user","content":"","createdAt":"2026-06-11T01:00:00Z","id":"m0","metadata":{"attachments":[{"id":"a1","type":"image","mime":"image/png","name":"photo.png","byteSize":204800}]}}"#,
        #"{"role":"assistant","content":"nice shot of the bay","createdAt":"2026-06-11T01:00:05Z","id":"m1"}"#,
        #"{"role":"user","content":"and this one?","createdAt":"2026-06-11T01:01:00Z","id":"m2","metadata":{"attachments":[{"id":"a2","type":"image","mime":"image/jpeg","name":"second.jpg","byteSize":102400}]}}"#,
    ])
    let engine = makeEngine2(personaRoot: personaDir, llm: MockLLMClient(scriptedResponses: ["ok"]))
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "follow-up",
        sessionId: "img-session",
        historyReader: reader
    )
    let sp = ctx.systemPrompt ?? ""
    // Image-only turn: present as a reference, not vanished.
    #expect(sp.contains("[sent image: photo.png, 200kB]"))
    // Captioned turn: marker + caption both present.
    #expect(sp.contains("[sent image: second.jpg, 100kB] and this one?"))
    // Never base64 in the rebuilt prompt.
    #expect(!sp.contains("base64"))
}
