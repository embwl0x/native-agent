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

// MARK: - Helpers

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("memintegration-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class StubRoutingForMemory: ProviderRoutingProtocol, @unchecked Sendable {
    let prefs: [String: SurfacePreference]
    init(prefs: [String: SurfacePreference]) { self.prefs = prefs }
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
}

/// Captures the system prompt + user prompt the chat() path actually feeds the LLM.
private final class CapturingLLM: LLMClient, @unchecked Sendable {
    private let q = DispatchQueue(label: "CapturingLLM")
    private var _systems: [String?] = []
    private var _prompts: [String] = []
    let reply: String
    init(reply: String = "assistant-reply") { self.reply = reply }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        q.sync {
            _systems.append(system)
            _prompts.append(prompt)
        }
        return reply
    }
    var systems: [String?] { q.sync { _systems } }
    var prompts: [String] { q.sync { _prompts } }
}

/// Counts observeTurn() calls and records the last (user, assistant, session) tuple.
private final class SpyPromoter: MemoryPromoting, @unchecked Sendable {
    private let q = DispatchQueue(label: "SpyPromoter")
    private var _count: Int = 0
    private var _last: (String, String, String)?
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        q.sync {
            _count += 1
            _last = (userMessage, assistantMessage, sessionId)
        }
    }
    var count: Int { q.sync { _count } }
    var last: (String, String, String)? { q.sync { _last } }
}

private func makeWiredClient(
    root: URL,
    recaller: SwiftNativeMemoryRecaller,
    llm: any LLMClient,
    promoter: (any MemoryPromoting)? = nil
) -> SwiftNativeChatOrchestrationClient {
    let persona = SwiftNativePersonaEngine(root: root)
    let tools = MockToolDispatchClient()
    let engine = SwiftNativeTurnEngine(
        persona: persona,
        memory: recaller,
        router: StubRoutingForMemory(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "test-model", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        memoryPromoter: promoter
    )
    let history = SessionHistoryReader(dataRoot: root)
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: history,
        dataRoot: root,
        promoter: promoter
    )
}

// MARK: - Tests

@Test
func chatClient_recalled_memories_are_in_system_prompt() async throws {
    let root = try makeTempRoot("recall-in-prompt")
    let store = JSONLEmbeddingStore(path: root.appendingPathComponent("emb.jsonl"))
    let embedder = MockEmbeddingProvider(dimensions: 64)
    let recaller = SwiftNativeMemoryRecaller(embedder: embedder, store: store)
    // Seed three memories. The MockEmbeddingProvider is deterministic per text,
    // so recall against an identical/overlapping query returns them ranked.
    try await recaller.index(id: "m-1", text: "MEMORY_TOKEN_ONE about pineapples")
    try await recaller.index(id: "m-2", text: "MEMORY_TOKEN_TWO about marlins")
    try await recaller.index(id: "m-3", text: "MEMORY_TOKEN_THREE about diesel engines")

    let llm = CapturingLLM(reply: "ok")
    let client = makeWiredClient(root: root, recaller: recaller, llm: llm)

    let resp = try await client.chat(
        message: "Tell me about pineapples",
        sessionId: "s-mem",
        model: "test-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(resp.output == "ok")

    let sys = llm.systems.first.flatMap { $0 } ?? ""
    // The system prompt must include the renderSystemPrompt "Recent memory:" header
    // and at least one of the seeded memory previews.
    #expect(sys.contains("Recent memory:"))
    let anyPreviewPresent =
        sys.contains("MEMORY_TOKEN_ONE") ||
        sys.contains("MEMORY_TOKEN_TWO") ||
        sys.contains("MEMORY_TOKEN_THREE")
    #expect(anyPreviewPresent)
}

@Test
func chatClient_no_memories_yields_no_memory_block() async throws {
    let root = try makeTempRoot("nomem")
    let store = JSONLEmbeddingStore(path: root.appendingPathComponent("emb.jsonl"))
    let recaller = SwiftNativeMemoryRecaller(
        embedder: MockEmbeddingProvider(dimensions: 64), store: store
    )
    let llm = CapturingLLM(reply: "ok")
    let client = makeWiredClient(root: root, recaller: recaller, llm: llm)
    _ = try await client.chat(
        message: "hi", sessionId: "s-empty",
        model: "test-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    let sys = llm.systems.first.flatMap { $0 } ?? ""
    #expect(!sys.contains("Recent memory:"))
}

@Test
func chatClient_promotesThroughTurnEngine_after_assistant_turn() async throws {
    let root = try makeTempRoot("promoter")
    let store = JSONLEmbeddingStore(path: root.appendingPathComponent("emb.jsonl"))
    let recaller = SwiftNativeMemoryRecaller(
        embedder: MockEmbeddingProvider(dimensions: 64), store: store
    )
    let llm = CapturingLLM(reply: "the-assistant-said-this")
    let promoter = SpyPromoter()
    let client = makeWiredClient(root: root, recaller: recaller, llm: llm, promoter: promoter)
    _ = try await client.chat(
        message: "the-user-said-this", sessionId: "s-prom",
        model: "test-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(promoter.count == 1)
    let last = promoter.last
    #expect(last?.0 == "the-user-said-this")
    #expect(last?.1 == "the-assistant-said-this")
    #expect(last?.2 == "s-prom")
}

@Test
func chatClient_no_promoter_is_silently_skipped() async throws {
    let root = try makeTempRoot("nopromoter")
    let store = JSONLEmbeddingStore(path: root.appendingPathComponent("emb.jsonl"))
    let recaller = SwiftNativeMemoryRecaller(
        embedder: MockEmbeddingProvider(dimensions: 64), store: store
    )
    let llm = CapturingLLM(reply: "ok")
    let client = makeWiredClient(root: root, recaller: recaller, llm: llm, promoter: nil)
    let resp = try await client.chat(
        message: "hi", sessionId: "s-nop",
        model: "test-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(resp.output == "ok")
}
