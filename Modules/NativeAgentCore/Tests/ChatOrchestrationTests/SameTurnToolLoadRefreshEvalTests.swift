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
// Ledger row closed here:
//   * chat.toolLoop.sameTurnToolLoadSchemaRefresh (UNCOVERED → COVERED)
//
// Silent-failure class: dead control — the model can SEE a loaded tool and be
// unable to CALL it. `tool_load` is the whole lazy-catalog design: the model
// loads a capability mid-turn and the loop must append the new schemas before
// the next provider call. If the refresh silently returns `current` (empty
// session id, or `listAvailableToolSchemas` throwing into the `try?`), the
// model gets the schema TEXT back from tool_load, cannot emit a call for it,
// and either narrates the work or burns iterations retrying — which reads
// exactly like the model being lazy, not like a wiring break.
//
// Both loops are driven, because both fire the refresh from the shared
// `runToolDispatchRound`.

private func lazySchema(_ name: String) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "test tool \(name)",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
}

/// The tool the model loads mid-turn. Not always-on, not a Mac tool, so it is
/// only reachable through the session's persisted loadout.
private let lateLoadedTool = "workshop_submit"

/// Advertises `tool_load` up front; `dispatch("tool_load")` persists the new
/// name into the REAL ActiveToolsStore on a hermetic root, exactly as the
/// production tool does, and the catalog then also lists the loaded schema.
private final class ToolLoadingDispatch: ToolDispatchClient, @unchecked Sendable {
    private let store: ActiveToolsStore
    private let sessionId: String
    nonisolated(unsafe) private(set) var dispatched: [String] = []

    init(store: ActiveToolsStore, sessionId: String) {
        self.store = store
        self.sessionId = sessionId
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        dispatched.append(tool)
        if tool == "tool_load" {
            _ = try await store.addLoaded(sessionId: sessionId, names: [lateLoadedTool])
            return .object([
                "ok": .bool(true),
                "schemas_added": .array([.string(lateLoadedTool)]),
            ])
        }
        return .object(["ok": .bool(true), "tool": .string(tool)])
    }

    func listAvailableTools() async throws -> [String] {
        ["tool_load", "recall_memory", lateLoadedTool]
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        ["tool_load", "recall_memory", lateLoadedTool].map(lazySchema)
    }
}

/// Captures the `tools:` array of every provider call — the only place the
/// model's ABILITY to emit a call for a tool is visible.
private final class ToolsArrayCapturingLLM: LLMClient, @unchecked Sendable {
    private let scripted: [String]
    nonisolated(unsafe) private(set) var toolsPerCall: [[String]] = []

    init(scripted: [String]) { self.scripted = scripted }

    func complete(prompt: String, system: String?, model: String?) async throws -> String { next(nil) }

    func completeMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        next(tools)
    }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let reply = next(tools)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.finish()
        }
    }

    private func next(_ tools: [LLMToolSchema]?) -> String {
        toolsPerCall.append((tools ?? []).map(\.name).sorted())
        let idx = toolsPerCall.count - 1
        guard !scripted.isEmpty else { return "" }
        return scripted[min(idx, scripted.count - 1)]
    }
}

private func toolCallJSON(id: String, name: String) -> String {
    #"{"tool_calls":[{"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]}"#
}

private struct RefreshPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class RefreshRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "m", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

private func makeRefreshEngine(
    store: ActiveToolsStore,
    llm: any LLMClient,
    tools: any ToolDispatchClient
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: RefreshPersona(),
        memory: nil,
        router: RefreshRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        activeToolsStore: store
    )
}

private func refreshRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sameturnload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - the positive path

@Test
func toolLoadMidTurn_exposesTheLoadedSchemaOnTheNextProviderCall_andItIsCallable() async throws {
    let root = try refreshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let session = "s-refresh"
    let tools = ToolLoadingDispatch(store: store, sessionId: session)
    let llm = ToolsArrayCapturingLLM(scripted: [
        toolCallJSON(id: "c1", name: "tool_load"),
        toolCallJSON(id: "c2", name: lateLoadedTool),
        "submitted",
    ])
    let engine = makeRefreshEngine(store: store, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "load the workshop tool and use it",
        sessionId: session,
        llm: llm,
        tools: tools
    )

    #expect(result.reply == "submitted")
    #expect(llm.toolsPerCall.count == 3)
    // Iteration 1 could NOT have advertised it — that is the lazy catalog.
    #expect(!llm.toolsPerCall[0].contains(lateLoadedTool))
    #expect(llm.toolsPerCall[0].contains("tool_load"))
    // Iteration 2 MUST advertise it: this is the whole refresh.
    #expect(llm.toolsPerCall[1].contains(lateLoadedTool))
    // Pre-existing schemas stay in place (provider aliases already in the
    // conversation must remain stable).
    #expect(llm.toolsPerCall[1].contains("tool_load"))
    #expect(llm.toolsPerCall[1].contains("recall_memory"))
    // And the model's call for it actually REACHED the dispatcher.
    #expect(tools.dispatched == ["tool_load", lateLoadedTool])
    #expect(result.toolDispatches.map(\.name) == ["tool_load", lateLoadedTool])
}

@Test
func toolLoadMidTurn_refreshAlsoFiresOnTheStreamingLoop() async throws {
    let root = try refreshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let session = "s-refresh-stream"
    let tools = ToolLoadingDispatch(store: store, sessionId: session)
    let llm = ToolsArrayCapturingLLM(scripted: [
        toolCallJSON(id: "c1", name: "tool_load"),
        toolCallJSON(id: "c2", name: lateLoadedTool),
        "submitted",
    ])
    let engine = makeRefreshEngine(store: store, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "load it then use it",
        sessionId: session,
        llm: llm,
        tools: tools
    )

    #expect(result.reply == "submitted")
    #expect(llm.toolsPerCall.count == 3)
    #expect(!llm.toolsPerCall[0].contains(lateLoadedTool))
    #expect(llm.toolsPerCall[1].contains(lateLoadedTool))
    #expect(tools.dispatched == ["tool_load", lateLoadedTool])
}

// MARK: - the fail-closed control

@Test
func toolLoadMidTurn_withNoSessionId_doesNotExposeTheLoadedSchema_andTheTurnStillCompletes() async throws {
    // The refresh needs a session to read the persisted loadout from. With no
    // session it must return `current` — NOT crash, NOT expose the whole
    // catalog. The turn still finishes; that combination is exactly what makes
    // this failure silent in production.
    let root = try refreshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let tools = ToolLoadingDispatch(store: store, sessionId: "unused")
    let llm = ToolsArrayCapturingLLM(scripted: [
        toolCallJSON(id: "c1", name: "tool_load"),
        "gave up and narrated instead",
    ])
    let engine = makeRefreshEngine(store: store, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "load it",
        sessionId: nil,
        llm: llm,
        tools: tools
    )

    #expect(result.reply == "gave up and narrated instead")
    #expect(llm.toolsPerCall.count == 2)
    #expect(!llm.toolsPerCall[1].contains(lateLoadedTool))
    #expect(tools.dispatched == ["tool_load"])
}
