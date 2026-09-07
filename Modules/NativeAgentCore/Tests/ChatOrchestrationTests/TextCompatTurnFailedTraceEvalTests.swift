import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger row closed here (EMISSION half):
//   * chat.textCompat.turnFailedTrace (UNCOVERED → COVERED for the emitter)
//
// `turn.failed` is the compat lane's ONLY terminal trace for a failed turn (the
// structured lane emits `turn.terminal`). Silent-failure class: dropped row —
// compat-lane failures are invisible to the instrument's turn accounting, so a
// rising failure rate on that lane reads as a falling turn VOLUME, not as
// errors.
//
// SCOPE NOTE: the ledger's proposed eval is instrument-tier (teach
// script/agent_instrument.swift to READ turn.failed and raise a lead). That
// reader lives outside this fence and is reported under productionSeamNeeded.
// What is pinned here is the half this fence owns and that nothing asserted:
// the row is EMITTED, exactly once, with its surface, reason, iteration and
// dispatchCount — so the instrument work has something real to count, and a
// lane that stops emitting fails here instead of quietly deflating a chart.

private func failedTraceRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("turnfailed-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeCompatOAuthFixture(_ root: URL) throws {
    let dir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["access_token": "tok-turnfailed"])
        .write(to: dir.appendingPathComponent("anthropic_oauth_direct.json"))
}

/// Streams `deltas` and then fails, exactly like a provider dying mid-answer.
private final class FailingCompatStreamingLLM:
    StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    struct Boom: Error, LocalizedError {
        var errorDescription: String? { "upstream-529-overloaded" }
    }
    private let deltas: [String]
    init(deltas: [String]) { self.deltas = deltas }

    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        let deltas = self.deltas
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.finish(throwing: Boom())
        }
    }

    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let deltas = self.deltas
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(.textDelta(delta)) }
            continuation.finish(throwing: Boom())
        }
    }
}

private final class UnusedStructuredLLM: LLMClient, @unchecked Sendable {
    nonisolated(unsafe) private(set) var calls = 0
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        calls += 1
        return "structured-path-should-not-run"
    }
}

private final class FailedTraceRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "claude-opus-4-8", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

private func stringField(_ event: TurnTraceEvent, _ key: String) -> String? {
    guard case .object(let payload) = event.payload,
          case .string(let value)? = payload[key] else { return nil }
    return value
}

private func intPayloadField(_ event: TurnTraceEvent, _ key: String) -> Int64? {
    guard case .object(let payload) = event.payload,
          case .int(let value)? = payload[key] else { return nil }
    return value
}

private func persistedRows(_ root: URL, sessionId: String) -> [[String: Any]] {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard let d = String(line).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

@Test
func textCompatLane_emitsExactlyOneTurnFailedRowCarryingReasonIterationAndDispatchCount() async throws {
    let root = try failedTraceRoot("emit")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCompatOAuthFixture(root)

    let structured = UnusedStructuredLLM()
    let streaming = FailingCompatStreamingLLM(deltas: ["Half an answ"])
    let tools = MockToolDispatchClient()
    let errors = LockedBox<[String]>([])

    let events = try await withHermeticTraceBus(kinds: ["turn.failed", "turn.terminal"]) { bus in
        let engine = SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: FailedTraceRouting(),
            trust: SwiftNativeTrustCenter(dataRoot: root),
            llm: structured,
            tools: tools,
            providerRecoverySleep: { _ in try Task.checkCancellation() },
            activeToolsStore: ActiveToolsStore(dataRoot: root),
            turnTraceBus: bus
        )
        let client = SwiftNativeChatOrchestrationClient(
            engine: engine, tools: tools, llm: structured,
            streamingLLM: streaming,
            history: SessionHistoryReader(dataRoot: root), dataRoot: root,
            turnTraceBus: bus,
            trust: SwiftNativeTrustCenter(dataRoot: root)
        )
        for try await event in client.chatStream(
            message: "explain it", sessionId: "s-turnfailed",
            model: "claude-opus-4-8", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], persona: nil,
            surface: "chat", suppressUserAppend: false
        ) {
            if case .error(let message) = event {
                var current = errors.get()
                current.append(message)
                errors.set(current)
            }
        }
    }

    // The structured lane must not have run — this is the compat lane's row.
    #expect(structured.calls == 0)
    #expect(!errors.get().isEmpty, "the provider failure never reached the consumer")

    let failedRows = events.filter { $0.kind == "turn.failed" }
    #expect(failedRows.count == 1, "expected exactly 1 turn.failed, got \(failedRows.count)")
    let row = try #require(failedRows.first)
    #expect(row.surface == "chat")
    // The reason must name the real failure, not a generic placeholder — this
    // is the field an instrument lead would have to quote.
    let reason = try #require(stringField(row, "reason"))
    #expect(reason.contains("529") || reason.contains("overloaded"), "reason was \(reason)")
    #expect(reason.count <= 200)
    // Iteration + dispatchCount make the row usable for rate accounting.
    #expect(intPayloadField(row, "iteration") != nil)
    #expect(intPayloadField(row, "dispatchCount") == 0)

    // A failed compat turn emits turn.failed and NOT the structured lane's
    // turn.terminal — which is exactly why an instrument that only reads
    // turn.terminal sees a missing turn instead of an error.
    #expect(events.filter { $0.kind == "turn.terminal" }.isEmpty)

    // And the prose the user already watched render is still persisted, so the
    // dropped ROW is the only loss — not the transcript.
    let rows = persistedRows(root, sessionId: "s-turnfailed")
    #expect(rows.contains { ($0["role"] as? String) == "assistant" })
}

@Test
func textCompatLane_successfulTurnEmitsNoTurnFailedRow() async throws {
    // The negative control: an always-emitting `turn.failed` would poison the
    // very failure-rate metric this row exists to make countable.
    let root = try failedTraceRoot("clean")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCompatOAuthFixture(root)

    final class CleanCompatLLM: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
        func stream(prompt: String, system: String?, model: String?)
            -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("all good")
                continuation.finish()
            }
        }
        func streamMessages(
            messages: [LLMMessage], system: String?, model: String?,
            surface: String, tools: [LLMToolSchema]?
        ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("all good"))
                continuation.finish()
            }
        }
    }

    let structured = UnusedStructuredLLM()
    let tools = MockToolDispatchClient()
    let final = LockedBox<String?>(nil)

    let events = try await withHermeticTraceBus(kinds: ["turn.failed"], expecting: 0) { bus in
        let engine = SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: FailedTraceRouting(),
            trust: SwiftNativeTrustCenter(dataRoot: root),
            llm: structured,
            tools: tools,
            providerRecoverySleep: { _ in try Task.checkCancellation() },
            activeToolsStore: ActiveToolsStore(dataRoot: root),
            turnTraceBus: bus
        )
        let client = SwiftNativeChatOrchestrationClient(
            engine: engine, tools: tools, llm: structured,
            streamingLLM: CleanCompatLLM(),
            history: SessionHistoryReader(dataRoot: root), dataRoot: root,
            turnTraceBus: bus,
            trust: SwiftNativeTrustCenter(dataRoot: root)
        )
        for try await event in client.chatStream(
            message: "explain it", sessionId: "s-turnclean",
            model: "claude-opus-4-8", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], persona: nil,
            surface: "chat", suppressUserAppend: false
        ) {
            if case .final(let result) = event { final.set(result.reply) }
        }
    }

    #expect(final.get() == "all good")
    #expect(events.isEmpty, "a clean turn emitted \(events.count) turn.failed row(s)")
}
