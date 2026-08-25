import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import TrustCenter

private func toolLoopContextForkTempRoot(_ tag: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tool-loop-context-fork-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func toolLoopContextForkWrite(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private struct ToolLoopContextForkPersona: PersonaEngineProtocol {
    private let document = PersonaDoc(
        id: "SOUL",
        content: "PERSONA-CONTEXT-MARKER",
        sizeBytes: "PERSONA-CONTEXT-MARKER".utf8.count,
        mtime: .distantPast
    )

    func listPersonaDocs() async throws -> [PersonaDoc] { [document] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? {
        id == document.id ? document : nil
    }
}

private final class ToolLoopContextForkRouting: ProviderRoutingProtocol, @unchecked Sendable {
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
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "test-model", reasoningEffort: "high")]
    }
}

private final class ToolLoopContextForkTools: ToolDispatchClient, @unchecked Sendable {
    private let schema = LLMToolSchema(
        name: "tool_catalog",
        description: "List the available tools.",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .null
    }
    func listAvailableTools() async throws -> [String] { [schema.name] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [schema] }
}

private final class ToolLoopContextForkLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _systems: [String?] = []
    private var _toolNames: [[String]] = []

    var systems: [String?] {
        lock.withLock { _systems }
    }

    var toolNames: [[String]] {
        lock.withLock { _toolNames }
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "final" }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        lock.withLock {
            _systems.append(system)
            _toolNames.append((tools ?? []).map(\.name))
        }
        return "final"
    }
}

private func toolLoopContextForkEngine(
    tools: any ToolDispatchClient,
    activeToolsStore: ActiveToolsStore
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: ToolLoopContextForkPersona(),
        memory: nil,
        router: ToolLoopContextForkRouting(),
        trust: hermeticTrust(),
        llm: ToolLoopContextForkLLM(),
        tools: tools,
        memoryPromoter: nil,
        activeToolsStore: activeToolsStore
    )
}

@Test
func toolLoopContextFork_preservesPrebuiltThreadedContextAndCharacterizesRebuild() async throws {
    let root = try toolLoopContextForkTempRoot("branches")
    let sessionId = "context-fork-session"
    let message = "CURRENT-USER-MARKER"
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try toolLoopContextForkWrite(
        """
        {"id":"prior-user","role":"user","content":"HISTORY-USER-MARKER","createdAt":"2026-08-01T12:00:00Z"}
        {"id":"prior-assistant","role":"assistant","content":"HISTORY-ASSISTANT-MARKER","createdAt":"2026-08-01T12:01:00Z"}
        """ + "\n",
        to: dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
    )
    try toolLoopContextForkWrite(
        """
        [
          {"id":"prior-session","createdAt":"2026-07-31T12:00:00Z","updatedAt":"2026-08-01T11:00:00Z","title":"Prior","messageCount":2,"lastMessagePreview":"DIGEST-MARKER"},
          {"id":"\(sessionId)","createdAt":"2026-08-01T12:00:00Z","updatedAt":"2026-08-01T12:00:00Z","title":"Current","messageCount":0,"lastMessagePreview":""}
        ]
        """,
        to: dataRoot.appendingPathComponent("chat/sessions.json")
    )

    let tools = ToolLoopContextForkTools()
    let engine = toolLoopContextForkEngine(
        tools: tools,
        activeToolsStore: ActiveToolsStore(dataRoot: dataRoot)
    )
    let history = SessionHistoryReader(dataRoot: dataRoot)
    let digest = SessionDigestProvider(
        dataRoot: dataRoot,
        agentInboxDir: root.appendingPathComponent("agent_inbox"),
        worklogPath: root.appendingPathComponent("worklog.jsonl")
    )
    let threaded = try await engine.buildTurnContextWithHistory(
        surface: "chat",
        userMessage: message,
        sessionId: sessionId,
        historyLimit: 10,
        historyReader: history,
        personaOverride: "PERSONA-OVERRIDE-MARKER",
        sessionDigest: digest
    )
    let preBuilt = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
        threaded,
        runtimeContext: "COGNITIVE-CAPSULE-MARKER"
    )

    let resolvedPreBuilt = try await engine.resolveToolLoopContext(
        surface: "chat",
        userMessage: message,
        sessionId: sessionId,
        runId: "context-fork-prebuilt",
        preBuiltContext: preBuilt
    )
    let rebuilt = try await engine.resolveToolLoopContext(
        surface: "chat",
        userMessage: message,
        sessionId: sessionId,
        runId: "context-fork-rebuild",
        preBuiltContext: nil
    )

    // The real owner must return the caller's fully composed production
    // context unchanged; its rebuild branch is intentionally a bare context.
    #expect(resolvedPreBuilt.personaID == "PERSONA-OVERRIDE-MARKER")
    #expect(resolvedPreBuilt.userMessage == message)
    #expect(resolvedPreBuilt.systemPrompt == preBuilt.systemPrompt)
    #expect(resolvedPreBuilt.systemPrompt?.contains("PERSONA-CONTEXT-MARKER") == true)
    #expect(resolvedPreBuilt.systemPrompt?.contains("HISTORY-USER-MARKER") == true)
    #expect(resolvedPreBuilt.systemPrompt?.contains("DIGEST-MARKER") == true)
    #expect(resolvedPreBuilt.systemPrompt?.contains("COGNITIVE-CAPSULE-MARKER") == true)
    #expect(rebuilt.personaID == nil)
    #expect(rebuilt.systemPrompt?.contains("HISTORY-USER-MARKER") == false)
    #expect(rebuilt.systemPrompt?.contains("DIGEST-MARKER") == false)
    #expect(rebuilt.systemPrompt?.contains("COGNITIVE-CAPSULE-MARKER") == false)
    #expect(resolvedPreBuilt.toolSchemas.map(\.name) == rebuilt.toolSchemas.map(\.name))

    let preBuiltLLM = ToolLoopContextForkLLM()
    let rebuiltLLM = ToolLoopContextForkLLM()
    let preBuiltResult = try await engine.executeTurnWithToolLoop(
        surface: "chat",
        userMessage: message,
        sessionId: sessionId,
        llm: preBuiltLLM,
        tools: tools,
        preBuiltContext: preBuilt
    )
    let rebuiltResult = try await engine.executeTurnWithToolLoop(
        surface: "chat",
        userMessage: message,
        sessionId: sessionId,
        llm: rebuiltLLM,
        tools: tools
    )

    // Both branches retain the loop's own behavior (one provider call, no
    // dispatches, same filtered schemas); only the declared context inputs differ.
    #expect(preBuiltResult.providerCallCount == 1)
    #expect(rebuiltResult.providerCallCount == 1)
    #expect(preBuiltResult.toolDispatches.isEmpty)
    #expect(rebuiltResult.toolDispatches.isEmpty)
    #expect(preBuiltLLM.toolNames == rebuiltLLM.toolNames)
    #expect(preBuiltLLM.systems.first == preBuilt.systemPrompt)
    let rebuiltSystem = try #require(rebuiltLLM.systems.first ?? nil)
    #expect(!rebuiltSystem.contains("HISTORY-USER-MARKER"))
    #expect(!rebuiltSystem.contains("DIGEST-MARKER"))
    #expect(!rebuiltSystem.contains("COGNITIVE-CAPSULE-MARKER"))
}
