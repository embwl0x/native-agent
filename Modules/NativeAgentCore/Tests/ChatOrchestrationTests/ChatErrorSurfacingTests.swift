import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
@testable import ProviderRouting
import TrustCenter

// MARK: - Chat error surfacing (repro for "Anthropic stream failure shows
// nothing in chat, OpenAI shows something")
//
// Production symptom (2026-06-14, flaky hotspot): a mid-stream network drop on
// the Anthropic chat path surfaced as `LLMError.transient("anthropic_oauth_direct
// streamMessages network connection was lost ... (code=-1005)")` on the bridge,
// but the Mac chat UI showed no error. the user: "if something fails it should tell
// me in chat what and why."
//
// These tests pin the ENGINE-layer contract that the chat stream MUST emit a
// non-empty `.error` TurnStreamEvent (and no `.final`) when the underlying
// provider stream fails — for BOTH the mid-stream case (some deltas already
// rendered) and the immediate case (connection lost before any token = the
// "nothing at all" scenario). The Mac UI relies on this `.error` event to
// render its "Chat error: …" bubble.

// MARK: - Helpers (redeclared fileprivate so this file compiles standalone)

private func makeTempRootES(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("errsurface-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// OAuth fixture so the compat loop selects the messages (streamMessages)
/// transport — the exact transport that failed in production.
private func writeOAuthFixtureES(_ root: URL) throws {
    let dir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["access_token": "tok-es"])
        .write(to: dir.appendingPathComponent("anthropic_oauth_direct.json"))
}

private final class StubRoutingES: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "qa-model", reasoningEffort: "high")]
    }
}

private final class UnusedLLMES: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "structured-path-should-not-run"
    }
}

/// Messages- and prompt-capable streaming client that yields N chunks then
/// fails the stream with `LLMError.transient` — mirrors the adapter's
/// `continuation.finish(throwing: transientNetworkError(...))` on a -1005.
private final class FailingStreamingLLM: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    let chunksBeforeFail: [String]
    let failMessage: String
    init(chunksBeforeFail: [String], failMessage: String) {
        self.chunksBeforeFail = chunksBeforeFail
        self.failMessage = failMessage
    }
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            Task {
                for c in chunksBeforeFail { cont.yield(c) }
                cont.finish(throwing: LLMError.transient(message: failMessage))
            }
        }
    }
    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?,
        surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { cont in
            Task {
                for c in chunksBeforeFail { cont.yield(.textDelta(c)) }
                cont.finish(throwing: LLMError.transient(message: failMessage))
            }
        }
    }
}

private func makeClientES(root: URL, streaming: any StreamingLLMClient) -> SwiftNativeChatOrchestrationClient {
    let llm = UnusedLLMES()
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: StubRoutingES(),
        trust: hermeticTrust(),
        llm: llm,
        tools: MockToolDispatchClient()
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: MockToolDispatchClient(),
        llm: llm,
        streamingLLM: streaming,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
}

private func collectChat(
    _ client: SwiftNativeChatOrchestrationClient,
    message: String, sessionId: String
) async -> (deltas: [String], finalReply: String?, errors: [String], thrown: Error?) {
    var deltas: [String] = []
    var finalReply: String?
    var errors: [String] = []
    do {
        for try await event in client.chatStream(
            message: message, sessionId: sessionId,
            model: "claude-opus-4-8", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], persona: nil,
            surface: "chat", suppressUserAppend: false
        ) {
            switch event {
            case .delta(let s): deltas.append(s)
            case .final(let r): finalReply = r.reply
            case .toolUse, .toolResult, .notice: break
            case .error(let m): errors.append(m)
            }
        }
        return (deltas, finalReply, errors, nil)
    } catch {
        return (deltas, finalReply, errors, error)
    }
}

// MARK: - Tests

@Test
func compatPath_midStreamFailure_surfacesNonEmptyErrorEvent() async throws {
    let root = try makeTempRootES("mid")
    try writeOAuthFixtureES(root)
    let failMsg = "anthropic_oauth_direct streamMessages network connection was lost: api.anthropic.com (code=-1005)"
    let failing = FailingStreamingLLM(chunksBeforeFail: ["Hel", "lo"], failMessage: failMsg)
    let client = makeClientES(root: root, streaming: failing)

    let r = await collectChat(client, message: "hi", sessionId: "s-es-mid")

    // The partial text the user watched render is preserved (deltas may be
    // coalesced by the compat flush buffer, so compare joined content).
    #expect(r.deltas.joined() == "Hello")
    // ...AND the failure is surfaced as a non-empty error event carrying WHY.
    #expect(!r.errors.isEmpty, "compat mid-stream failure must emit a .error event")
    #expect(r.errors.contains { $0.contains("connection was lost") || $0.contains("-1005") },
            "the .error event must carry the failure reason, got: \(r.errors)")
    // A failed turn must NOT look like a completed one.
    #expect(r.finalReply == nil, "no .final should be emitted on a failed stream")
}

@Test
func compatPath_immediateFailure_surfacesNonEmptyErrorEvent() async throws {
    // The "nothing at all" case: connection lost before any token streams.
    let root = try makeTempRootES("immediate")
    try writeOAuthFixtureES(root)
    let failMsg = "anthropic_oauth_direct streamMessages network connection was lost: api.anthropic.com (code=-1005)"
    let failing = FailingStreamingLLM(chunksBeforeFail: [], failMessage: failMsg)
    let client = makeClientES(root: root, streaming: failing)

    let r = await collectChat(client, message: "hi", sessionId: "s-es-immediate")

    #expect(r.deltas.isEmpty)
    #expect(!r.errors.isEmpty, "compat immediate failure must still emit a .error event (the silent-no-reply case)")
    #expect(r.errors.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            "the .error event must be non-empty, got: \(r.errors)")
    #expect(r.finalReply == nil)
}

@Test
func compatPath_valueErrorAfterToolMarker_doesNotDispatchToolAndSurfacesError() async throws {
    // audit finding #1 (2026-06-14): a provider failure mid-turn must be
    // TERMINAL. The compat loop surfaces the failure as a VALUE .error event
    // (streamTurn converts the upstream throw). The engine must NOT fall through
    // to ToolCallParser.parse and dispatch a <tool_use> marker that arrived
    // before the failure (a bogus post-error tool round), must still surface the
    // .error, and must not emit a .final.
    let root = try makeTempRootES("toolmarker")
    try writeOAuthFixtureES(root)
    let marker = "<tool_use name=\"echo\">{}</tool_use>"
    let failMsg = "anthropic_oauth_direct streamMessages network connection was lost: api.anthropic.com (code=-1005)"
    let failing = FailingStreamingLLM(chunksBeforeFail: [marker], failMessage: failMsg)
    let client = makeClientES(root: root, streaming: failing)

    var sawToolEvent = false
    var errors: [String] = []
    var finalReply: String?
    var deltas: [String] = []
    for try await event in client.chatStream(
        message: "hi", sessionId: "s-es-toolmarker",
        model: "claude-opus-4-8", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], persona: nil,
        surface: "chat", suppressUserAppend: false
    ) {
        switch event {
        case .toolUse, .toolResult: sawToolEvent = true
        case .error(let m): errors.append(m)
        case .final(let r): finalReply = r.reply
        case .delta(let s): deltas.append(s)
        case .notice: break
        }
    }
    #expect(!sawToolEvent, "a tool marker before a provider .error must NOT be dispatched (post-error tool round)")
    #expect(!errors.isEmpty, "the failure must still be surfaced as a .error event")
    #expect(finalReply == nil, "a failed turn must not emit a .final")
    // audit #1 + #6: a raw/partial tool marker mid-emission when the stream fails
    // must NEVER render as visible text (the force-flush must hold it back).
    #expect(!deltas.joined().contains("<tool"), "a raw tool marker must not stream as visible text on the error path, got: \(deltas)")
}
