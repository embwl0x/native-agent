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

// MARK: - Helpers (duplicated from ChatOrchestrationTurnEngineTests.swift —
// private there, redeclared fileprivate here so this file compiles standalone).

fileprivate func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("streamengine-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

fileprivate final class StubRouting: ProviderRoutingProtocol, @unchecked Sendable {
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

fileprivate final class ThrowingPersonaStub: PersonaEngineProtocol, @unchecked Sendable {
    struct Boom: Error {}
    func listPersonaDocs() async throws -> [PersonaDoc] { throw Boom() }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { throw Boom() }
}

fileprivate func makeEngine(
    persona: any PersonaEngineProtocol,
    routerPrefs: [String: SurfacePreference] = [
        "chat": SurfacePreference(surface: "chat", model: "stream-model-X", reasoningEffort: "high"),
    ],
    llm: any LLMClient = MockLLMClient(scriptedResponses: ["unused-sync"]),
    tools: any ToolDispatchClient = MockToolDispatchClient()
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: persona,
        memory: nil,
        router: StubRouting(prefs: routerPrefs),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

fileprivate func collect(
    _ stream: AsyncThrowingStream<TurnStreamEvent, Error>
) async -> (events: [TurnStreamEvent], thrown: Error?) {
    var out: [TurnStreamEvent] = []
    do {
        for try await ev in stream { out.append(ev) }
        return (out, nil)
    } catch {
        return (out, error)
    }
}

fileprivate func deltaTexts(_ events: [TurnStreamEvent]) -> [String] {
    events.compactMap { if case .delta(let s) = $0 { return s } else { return nil } }
}

fileprivate func finalResult(_ events: [TurnStreamEvent]) -> TurnEngineResult? {
    for ev in events { if case .final(let r) = ev { return r } }
    return nil
}

fileprivate func errorEvent(_ events: [TurnStreamEvent]) -> String? {
    for ev in events { if case .error(let s) = ev { return s } }
    return nil
}

fileprivate func hasToolUse(_ events: [TurnStreamEvent]) -> Bool {
    for ev in events { if case .toolUse = ev { return true } }
    return false
}

// MARK: - MockStreamingLLMClient tests

@Test
func mockStreamingLLMClient_returns_scripted_chunks_in_order() async throws {
    let mock = MockStreamingLLMClient(chunks: ["a", "bb", "ccc"])
    var got: [String] = []
    for try await c in mock.stream(prompt: "p", system: nil, model: "m") {
        got.append(c)
    }
    #expect(got == ["a", "bb", "ccc"])
    #expect(mock.callCount == 1)
    #expect(mock.lastPrompt == "p")
    #expect(mock.lastModel == "m")
}

@Test
func mockStreamingLLMClient_yields_error_when_scripted_to_throw() async throws {
    let mock = MockStreamingLLMClient(chunks: ["x", "y", "z"], errorAfter: 2)
    var got: [String] = []
    var thrown: Error?
    do {
        for try await c in mock.stream(prompt: "p", system: nil, model: nil) {
            got.append(c)
        }
    } catch {
        thrown = error
    }
    #expect(got == ["x", "y"])
    #expect(thrown is MockStreamingLLMClient.MockStreamError)
}

// MARK: - streamTurn tests

@Test
func streamTurn_yields_deltas_in_order() async throws {
    let dir = try makeTempDir("delta-order")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(persona: persona)
    let streamer = MockStreamingLLMClient(chunks: ["Hel", "lo, ", "world"])
    let (events, thrown) = await collect(engine.streamTurn(
        userMessage: "hi", streamingLLM: streamer
    ))
    #expect(thrown == nil)
    #expect(deltaTexts(events) == ["Hel", "lo, ", "world"])
}

@Test
func streamTurn_yields_final_with_accumulated_reply() async throws {
    let dir = try makeTempDir("accum")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(persona: persona)
    let streamer = MockStreamingLLMClient(chunks: ["one ", "two ", "three"])
    let (events, _) = await collect(engine.streamTurn(
        userMessage: "go", streamingLLM: streamer
    ))
    let f = finalResult(events)
    #expect(f != nil)
    #expect(f?.reply == "one two three")
    #expect(f?.rawLLMResponse == "one two three")
}

@Test
func streamTurn_cleanEmptyEOF_isAnErrorNotASuccessfulBlankReply() async throws {
    let dir = try makeTempDir("empty-provider-stream")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(persona: persona)
    let streamer = MockStreamingLLMClient(chunks: [])
    let (events, thrown) = await collect(engine.streamTurn(
        userMessage: "build it", streamingLLM: streamer
    ))
    #expect(thrown == nil)
    #expect(finalResult(events) == nil)
    #expect(errorEvent(events)?.contains("no answer text or tool call") == true)
}

@Test
func textToolCompatibilityLayout_cachesToolContractBeforeVolatileContext() throws {
    let stable = "persona-stable"
    let dynamic = "clock-and-recall-dynamic"
    let baseSegments = SystemPromptSegments(stable: stable, dynamic: dynamic)
    let schema = LLMToolSchema(
        name: "write_file",
        description: "Write one workspace file.",
        parametersJSON: Data(
            #"{"type":"object","properties":{"path":{"type":"string"}}}"#.utf8
        )
    )
    let context = TurnContext(
        surface: "telegram",
        personaDocs: [:],
        recalled: [],
        modelId: "claude-opus-5",
        reasoningEffort: "high",
        toolsAvailable: ["write_file"],
        systemPrompt: baseSegments.combined,
        userMessage: "build it",
        toolSchemas: [schema],
        systemSegments: baseSegments
    )

    let layout = SwiftNativeTurnEngine.textToolCompatibilityLayout(
        baseSystem: baseSegments.combined,
        segments: baseSegments,
        context: context
    )
    let resolved = try #require(layout.segments)
    #expect(layout.system == resolved.combined)
    #expect(resolved.stable.hasPrefix(stable))
    #expect(resolved.stable.contains("NativeAgent Swift tool protocol"))
    #expect(resolved.stable.contains("write_file"))
    #expect(resolved.dynamic == dynamic)
    #expect(!resolved.dynamic.contains("NativeAgent Swift tool protocol"))
    #expect(layout.system.range(of: "write_file")!.lowerBound
        < layout.system.range(of: dynamic)!.lowerBound)
}

@Test
func streamTurn_persona_load_failure_yields_error_event() async throws {
    let engine = makeEngine(persona: ThrowingPersonaStub())
    let streamer = MockStreamingLLMClient(chunks: ["never"])
    let (events, thrown) = await collect(engine.streamTurn(
        userMessage: "hi", streamingLLM: streamer
    ))
    #expect(thrown == nil)
    let err = errorEvent(events)
    #expect(err != nil)
    #expect(err?.contains("persona") == true || err?.contains("Boom") == true)
    #expect(finalResult(events) == nil)
    #expect(deltaTexts(events).isEmpty)
    #expect(streamer.callCount == 0)
}

@Test
func streamTurn_empty_message_yields_error_event() async throws {
    let dir = try makeTempDir("empty")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(persona: persona)
    let streamer = MockStreamingLLMClient(chunks: ["never"])
    let (events, thrown) = await collect(engine.streamTurn(
        userMessage: "", streamingLLM: streamer
    ))
    #expect(thrown == nil)
    let err = errorEvent(events)
    #expect(err != nil)
    #expect(err?.contains("empty") == true || err?.contains("whitespace") == true)
    #expect(finalResult(events) == nil)
    #expect(streamer.callCount == 0)
}

@Test
func streamTurn_propagates_upstream_LLM_throw_as_error_event() async throws {
    let dir = try makeTempDir("llm-throw")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(persona: persona)
    let streamer = MockStreamingLLMClient(chunks: ["partial-1", "partial-2", "wont-arrive"], errorAfter: 2)
    let (events, thrown) = await collect(engine.streamTurn(
        userMessage: "hi", streamingLLM: streamer
    ))
    #expect(thrown == nil)
    #expect(deltaTexts(events) == ["partial-1", "partial-2"])
    #expect(errorEvent(events) != nil)
    #expect(finalResult(events) == nil)
}

@Test
func streamTurn_no_tool_dispatch_in_phase_B() async throws {
    let dir = try makeTempDir("no-tool")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(persona: persona)
    let streamer = MockStreamingLLMClient(chunks: [
        "I will call <tool_use ",
        "name=\"alpha\">{\"k\":1}",
        "</tool_use> now.",
    ])
    let (events, _) = await collect(engine.streamTurn(
        userMessage: "use tools", streamingLLM: streamer
    ))
    #expect(hasToolUse(events) == false)
    let f = finalResult(events)
    #expect(f != nil)
    #expect(f?.toolDispatches.isEmpty == true)
    #expect(f?.reply.contains("<tool_use") == true)
}

@Test
func streamTurn_final_TurnEngineResult_includes_modelUsed_and_elapsedMs() async throws {
    let dir = try makeTempDir("final-fields")
    let persona = SwiftNativePersonaEngine(root: dir)
    let engine = makeEngine(
        persona: persona,
        routerPrefs: [
            "chat": SurfacePreference(surface: "chat", model: "stream-pick-XYZ", reasoningEffort: "high"),
        ]
    )
    let streamer = MockStreamingLLMClient(chunks: ["ok"])
    let (events, _) = await collect(engine.streamTurn(
        userMessage: "hello", streamingLLM: streamer
    ))
    let f = finalResult(events)
    #expect(f?.modelUsed == "stream-pick-XYZ")
    #expect((f?.elapsedMs ?? -1) >= 0)
}
