import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import DreamREMCycle
import ApprovalInbox
import MacIntegration
import CognitiveSubstrate

private let makeTempRoot: @Sendable (String) throws -> URL = makeChatOrchestrationTempRoot

// MARK: - 658.14 session provenance

/// The bridge cannot express origin through `surface:` — that parameter is also
/// the tool-authorization surface, and the claude/codex bridges deliberately
/// run with `surface: "chat"` so they keep chat's tool permissions. Origin
/// therefore rides a TaskLocal. This proves the TaskLocal actually reaches the
/// bytes on disk rather than assuming the binding propagates.
@Test
func appendMessage_stampsBridgeOriginOnUserRowsOnly() async throws {
    let root = try makeTempRoot("origin-stamp")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let sessionId = "origin-session"
    try await ChatPersistenceContext.$originProvenance.withValue(
        ChatMessageOrigin(surface: "claude-bridge", agent: "claude")
    ) {
        try await client.appendMessage(
            sessionId: sessionId, role: "user",
            content: "[from: claude, via bridge] wake payload",
            runId: "run-1", attachments: []
        )
        try await client.appendMessage(
            sessionId: sessionId, role: "assistant",
            content: "reply", runId: "run-1", attachments: []
        )
    }
    // And a row appended with NO binding must carry no origin at all.
    try await client.appendMessage(
        sessionId: sessionId, role: "user",
        content: "typed by user", runId: "run-2", attachments: []
    )

    let path = root.appendingPathComponent("chat/messages/\(sessionId).jsonl")
    let lines = try String(contentsOf: path, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    let rows = try lines.map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }

    func origin(_ row: [String: Any]) -> [String: Any]? {
        (row["metadata"] as? [String: Any])?["origin"] as? [String: Any]
    }

    // 1. The bridge user row is durably marked.
    let bridged = try #require(origin(rows[0]))
    #expect(bridged["surface"] as? String == "claude-bridge")
    #expect(bridged["agent"] as? String == "claude")
    // The persisted `source` stays "app" — that is exactly WHY the badge is
    // needed, and pinning it here keeps the tool-surface semantics from
    // silently drifting under a future provenance change.
    #expect(rows[0]["source"] as? String == "app")

    // 2. The assistant row is NOT marked: the reply is hers, not the bridge's.
    #expect(origin(rows[1]) == nil)

    // 3. An unbound row carries nothing — no origin is invented.
    #expect(origin(rows[2]) == nil)
}

/// The same text marker is forgeable; the TaskLocal origin is not inferred
/// from text. A Mac user typing the Codex prefix must remain a live,
/// user-stated turn, while a server-bound Codex lane is imported/debug work.
@Test
func appendMessage_outOfBandOriginControlsCognitiveTrust() async throws {
    let root = try makeTempRoot("origin-cognitive-trust")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )

    let forgeable = "[from: codex, via bridge] codex bridge test"
    try await client.appendMessage(
        sessionId: "origin-cognition",
        role: "user",
        content: forgeable,
        runId: "human-run",
        attachments: []
    )
    try await ChatPersistenceContext.$originProvenance.withValue(
        ChatMessageOrigin(surface: "codex-bridge", agent: "codex")
    ) {
        try await client.appendMessage(
            sessionId: "origin-cognition",
            role: "user",
            content: forgeable,
            runId: "codex-run",
            attachments: []
        )
    }
    try await ChatPersistenceContext.$originProvenance.withValue(
        ChatMessageOrigin(surface: "codex-bridge", agent: "claude")
    ) {
        try await client.appendMessage(
            sessionId: "origin-cognition",
            role: "user",
            content: forgeable,
            runId: "contradictory-run",
            attachments: []
        )
    }
    try await ChatPersistenceContext.$originProvenance.withValue(
        ChatMessageOrigin(surface: "omp-bridge", agent: "omp")
    ) {
        try await client.appendMessage(
            sessionId: "origin-cognition",
            role: "user",
            content: forgeable,
            runId: "omp-run",
            attachments: []
        )
    }

    let events = await observer.all()
    #expect(events.count == 4)
    let human = try #require(events.first)
    let trustedBridge = try #require(events.dropFirst().first)
    let contradictory = try #require(events.dropFirst(2).first)
    let ompBridge = try #require(events.dropFirst(3).first)
    #expect(human.sourceClass == .userStated)
    #expect(human.turnKind == .live)
    #expect(human.metadata["origin"] == nil)
    #expect(trustedBridge.sourceClass == .imported)
    #expect(trustedBridge.turnKind == .verification)
    #expect(trustedBridge.metadata["origin"] == .object([
        "surface": .string("codex-bridge"),
        "agent": .string("codex"),
    ]))
    #expect(contradictory.sourceClass == .imported)
    #expect(contradictory.turnKind == .live)
    #expect(contradictory.metadata["origin"] == .object([
        "surface": .string("codex-bridge"),
        "agent": .string("claude"),
    ]))
    #expect(ompBridge.sourceClass == .imported)
    #expect(ompBridge.turnKind == .verification)
    #expect(ompBridge.metadata["origin"] == .object([
        "surface": .string("omp-bridge"),
        "agent": .string("omp"),
    ]))
}
