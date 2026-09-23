import Foundation
import Testing
import Context
import CognitiveSubstrate
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TrustCenter
@testable import ChatOrchestration
@testable import ProviderRouting
@testable import NativeAgentApp

private struct PrefixRouting: ProviderRoutingProtocol {
    var text = false
    var model: String { text ? "claude-opus-4-8" : "gpt-5.6-sol" }
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { Provider(id: id) }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider { Provider(id: id) }
    func testProvider(id: String) async throws -> ProviderRouting.ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        Dictionary(uniqueKeysWithValues: ["chat", "telegram", "bridge", "workshop"].map {
            ($0, SurfacePreference(surface: $0, model: model, reasoningEffort: "low"))
        })
    }
    func activeProvidersForSurfaces() async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ["chat", "telegram", "bridge", "workshop"].map { ($0, text ? "anthropic_oauth_direct" : "codex") })
    }
}

private struct PrefixEmbedding: EmbeddingProvider {
    let dimensions = 8
    let modelId = "prefix-fixture"
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0, 0, 0, 0, 0, 0] }
    }
}

private struct PrefixTools: ToolDispatchClient {
    let names: [String]
    func listAvailableTools() async throws -> [String] { names }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        names.map { LLMToolSchema(name: $0, description: "Fixture \($0)",
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)) }
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .null }
}

private actor PrefixCognition: CognitiveRuntimeProviding {
    let now: Date
    init(now: Date) { self.now = now }
    func observe(_ event: CognitiveEvent) async {}
    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        CognitiveCapsule(generatedAt: now, mode: .inject,
            stableKernel: "Fixture inner state", dynamicContext: "Fixture time \(now)",
            provenanceNodeIds: [], truncated: false)
    }
}

private struct CachedRequest: Sendable {
    let segments: SystemPromptSegments
    let tools: [LLMToolSchema]
    let system: String
    var deliveredText = ""

    // Serialize the actual provider blocks, including its identity block and
    // cache metadata. Only the explicitly volatile final block is excluded.
    // Keep raw section bytes too: String equality alone normalizes Unicode.
    func prefix() throws -> Data {
        let body = LLMCallContext.$systemSegments.withValue(segments) {
            ConversationPrefixShape.$override.withValue(.v2Prefix) {
                AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                    messages: [.user("fixture")], system: system,
                    coercedModel: "claude-opus-4-8", maxTokens: 128, stream: false)
            }
        }
        var blocks = body["system"] as? [[String: Any]] ?? []
        if !segments.dynamic.isEmpty {
            #expect(blocks.last?["text"] as? String == segments.dynamic)
            blocks.removeLast()
        }
        return try JSONSerialization.data(withJSONObject: [
            "stableUTF8": Array(segments.stable.utf8),
            "stableSuffixUTF8": Array(segments.stableSuffix.utf8),
            "system": blocks,
            "tools": tools.map { [
                "name": $0.name, "description": $0.description,
                "input_schema": (try? JSONSerialization.jsonObject(with: $0.parametersJSON)) ?? [:],
            ] as [String: Any] }
        ], options: [.sortedKeys])
    }

    func injecting(_ marker: String, into part: Int) -> CachedRequest {
        let changed = SystemPromptSegments(
            stable: segments.stable + (part == 0 ? marker : ""),
            stableSuffix: segments.stableSuffix + (part == 1 ? marker : ""),
            dynamic: segments.dynamic)
        var changedTools = tools
        if part == 2 {
            let first = tools[0]
            changedTools[0] = LLMToolSchema(name: first.name,
                description: first.description + marker, parametersJSON: first.parametersJSON)
        }
        return CachedRequest(segments: changed, tools: changedTools, system: changed.combined)
    }
}

private final class PrefixLLM: LLMClient, StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [CachedRequest] = []
    var requests: [CachedRequest] { lock.withLock { rows } }
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let segments = LLMCallContext.systemSegments
            if let segments {
                lock.withLock { rows.append(CachedRequest(segments: segments, tools: [], system: system ?? "",
                    deliveredText: (system ?? "") + prompt)) }
                continuation.yield("Fixture reply.")
            } else { Issue.record("Missing production system segments") }
            continuation.finish()
        }
    }
    func streamMessages(messages: [LLMMessage], system: String?, model: String?, surface: String,
                        tools: [LLMToolSchema]?) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if let segments = LLMCallContext.systemSegments {
                #expect(segments.reassembles(into: system ?? ""))
                lock.withLock { rows.append(CachedRequest(segments: segments, tools: tools ?? [], system: system ?? "",
                    deliveredText: (system ?? "") + String(describing: messages))) }
                continuation.yield(.textDelta("Fixture reply."))
            } else { Issue.record("Missing production system segments") }
            continuation.finish()
        }
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model,
            surface: LLMCallContext.surface ?? "chat", tools: nil)
    }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?,
                          surface: String, tools: [LLMToolSchema]?) async throws -> String {
        let segments = try #require(LLMCallContext.systemSegments)
        #expect(segments.reassembles(into: system ?? ""))
        lock.withLock { rows.append(CachedRequest(segments: segments, tools: tools ?? [], system: system ?? "",
            deliveredText: (system ?? "") + String(describing: messages))) }
        return "Fixture reply."
    }
}

@Suite("Production prompt cache assembly")
struct PromptCacheProductionAssemblyTests {
    @Test(arguments: ["chat", "telegram", "bridge", "ephemeral", "chat-text", "telegram-text"], ["", "Surface instructions — unchanged\n"])
    func persistedPrefixSurvivesColdResidentAndRelaunch(lane: String, guidance: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-production-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("mcp/servers.json")
        try FileManager.default.createDirectory(at: servers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"id":"z","status":"ready"},{"id":"a","status":"configured"}]"#.utf8).write(to: servers)
        let text = lane.hasSuffix("-text")
        let surface = lane == "ephemeral" ? "bridge" : lane.replacingOccurrences(of: "-text", with: "")
        let router = PrefixRouting(text: text)
        if text {
            let providers = root.appendingPathComponent("providers")
            try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
            try Data(#"{"access_token":"fixture-only-not-a-credential"}"#.utf8)
                .write(to: providers.appendingPathComponent("anthropic_oauth_direct.json"))
        }
        let persona = SwiftNativePersonaEngine.isolated(dataRoot: root)
        let personaRoot = await persona.personaRoot
        let docs = [("SOUL", "Identity — unchanged\n"), ("VOICE", "Voice\n\n"),
                    ("USER", "Relationship\n"), ("GROWTH", "Growth\n"),
                    ("MEMORY", "Memory e\u{301}\n"), ("AGENTS", "Instructions\n")]
        try FileManager.default.createDirectory(at: personaRoot.appendingPathComponent("surfaces"), withIntermediateDirectories: true)
        for (id, body) in docs {
            try Data(body.utf8).write(to: personaRoot.appendingPathComponent("\(id).md"))
        }
        try Data(guidance.utf8).write(to: personaRoot.appendingPathComponent("surfaces/\(surface).md"))
        // Literal base-commit compile algorithm, independent of renderPrompt.
        let baseText = (docs.map { "# \($0.0)\n\($0.1)" }
            + ["Surface guidance for \(surface):\n\(guidance)"]).joined(separator: "\n\n")
        let compiled = try await PersonaCompiler(engine: persona).compile(surface: surface)
        #expect(Data(compiled.compiledSystemPrompt.utf8) == Data(baseText.utf8))

        var requests: [CachedRequest] = []
        let session = "prefix-session"
        // Establish the session through production before comparing relaunches.
        // The base intentionally falls back to v1 for its first history-free
        // turn; that one-time layout transition is not a relaunch regression.
        for turn in -1..<4 {
            // Every resident turn starts a fresh production runtime and reads
            // the on-disk persona through makeBuild -> makeMirror. The second
            // resident start also reopens the persisted context generation.
            let runtime = NativeContextFlowRuntime(dataRoot: root,
                configurationOverride: .init(mode: .active, budget: .mib32),
                memoryOverride: SwiftNativeMemoryV2(embedder: PrefixEmbedding(), storage: InMemoryMemoryStorage()),
                environmentOverride: [:], personaOverride: { nil })
            if turn > 0 {
                await runtime.start()
                #expect(await runtime.contextFlowMode() == .active)
            }
            let names = lane == "ephemeral" || turn <= 0 || turn == 3
                ? ["mcp__z__tool", "mcp__a__tool"] : (turn == 1 ? [] : ["mcp__z__tool"])
            let tools = PrefixTools(names: names)
            let llm = PrefixLLM()
            let trust = SwiftNativeTrustCenter(dataRoot: root)
            let store = ActiveToolsStore(dataRoot: root)
            let now = Date(timeIntervalSince1970: 1_756_000_000 + Double(turn) * 86_400)
            let engine = SwiftNativeTurnEngine(persona: SwiftNativePersonaEngine.isolated(dataRoot: root),
                memory: nil, router: router, trust: trust, llm: llm, tools: tools,
                clock: { now }, remPinsDataRoot: root, memoryPromoter: nil, activeToolsStore: store,
                contextFlow: turn <= 0 ? nil : runtime, quietHoursReader: { _ in nil })
            let client = SwiftNativeChatOrchestrationClient(engine: engine, tools: tools, llm: llm,
                streamingLLM: text ? llm : nil, history: SessionHistoryReader(dataRoot: root),
                dataRoot: root, trust: trust, promoter: nil,
                cognitiveObserver: PrefixCognition(now: now), clock: { now })
            do {
                try await ConversationPrefixShape.$override.withValue(.v2Prefix) {
                try await ChatToolSessionContext.$envelope.withValue(
                    TurnEnvelope(surface: surface, agent: lane == "bridge" ? "codex" : nil,
                        verifiedUserId: lane == "bridge" ? "peer-fixture" : "user-fixture")
                ) {
                if lane == "ephemeral" {
                    _ = try await client.runEphemeralToolTurn(message: "Fixture turn \(turn)", surface: surface)
                } else {
                    _ = try await client.chat(message: "Fixture turn \(turn)", sessionId: session,
                        model: router.model, reasoningEffort: "low", fileAccess: "read_only",
                        attachments: [], persona: nil, surface: surface, suppressUserAppend: false)
                }
                }
                }
                let request = try #require(llm.requests.first)
                #expect(request.deliveredText.contains("run_id:"))
                #expect(request.deliveredText.contains("Fixture time"))
                #expect(request.segments.stable.utf8.starts(with: baseText.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                if text {
                    #expect(request.tools.isEmpty)
                } else {
                    #expect(request.tools.map(\.name) == ["mcp_z_tool", "mcp_a_tool"])
                }
                if turn >= 0 { requests.append(request) }
            } catch {
                await runtime.stop()
                throw error
            }
            await runtime.stop()
        }
        let first = try #require(requests.first)
        let expected = try first.prefix()
        #expect(requests.last?.deliveredText != first.deliveredText)
        for request in requests.dropFirst() {
            #expect(request.segments.stable == first.segments.stable)
            #expect(request.segments.stableSuffix == first.segments.stableSuffix)
            let actual = try request.prefix()
            if actual != expected {
                let index = zip(actual, expected).prefix(while: { $0 == $1 }).count
                print("PREFIX DIFFERENCE \(lane) at \(index): actual=\(String(decoding: actual.dropFirst(max(0, index - 60)).prefix(240), as: UTF8.self)) expected=\(String(decoding: expected.dropFirst(max(0, index - 60)).prefix(240), as: UTF8.self))")
            }
            #expect(actual == expected)
        }
        // Negative controls must reject drift in EACH cached component, even
        // when the other two are unchanged and the split still reassembles.
        for marker in ["2026-09-19T12:34:56Z", "run-injected-123"] {
            for part in 0..<3 {
                if part == 2 && first.tools.isEmpty { continue }
                #expect(try first.injecting(marker, into: part).prefix() != expected)
            }
        }
        for (id, body) in docs {
            #expect(try Data(contentsOf: personaRoot.appendingPathComponent("\(id).md")) == Data(body.utf8))
        }
    }
}
