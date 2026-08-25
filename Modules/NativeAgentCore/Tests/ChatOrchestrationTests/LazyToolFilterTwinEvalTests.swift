import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger row closed here:
//   * chat.structured.applyLazyToolFilterTwin (UNCOVERED → COVERED)
//
// LEDGER CORRECTION (verified at HEAD, ChatOrchestration+ToolLoop.swift:1409):
// the two are NOT independent implementations any more —
// `SwiftNativeTurnEngine.lazyFilteredTurnContext` DERIVES the effective active
// set and then DELEGATES to `SwiftNativeChatOrchestrationClient
// .applyLazyToolFilter`. The divergence risk the row names is therefore split
// in two, and both halves are pinned here:
//   (1) the FILTER RULE itself (alwaysOnCore ∪ activeTools, mcp__* always
//       passes) — applyLazyToolFilter had zero tests naming it;
//   (2) the DERIVATION that feeds it (persisted ∪ turn-local, fail-closed to
//       turn-local on an empty/nil session, pinned set bypasses the store) —
//       and the equality of the two, so re-inlining the filter into the engine
//       (the shape the row warns about) fails here instead of silently
//       shipping a different tool catalog than the reviewer thinks.
//
// Silent-failure class: wrong value. Neither direction errors: the model just
// sees a different tool catalog.

private func schema(_ name: String) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "test tool \(name)",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
}

/// A catalog spanning every class the filter distinguishes.
private let alwaysOnName = "recall_memory"           // in alwaysOnCoreNames
private let lazyNameA = "workshop_submit"            // lazy built-in
private let lazyNameB = "task_ledger_post"           // lazy built-in
private let mcpName = "mcp__server__do_thing"        // MCP, always passes

private func catalogContext() -> TurnContext {
    let schemas = [alwaysOnName, lazyNameA, lazyNameB, mcpName].map(schema)
    return TurnContext(
        surface: "chat",
        personaDocs: [:],
        recalled: [],
        modelId: "m",
        reasoningEffort: "high",
        toolsAvailable: schemas.map(\.name),
        systemPrompt: "sys",
        userMessage: "hi",
        toolSchemas: schemas
    )
}

private func filteredNames(_ context: TurnContext?) -> [String] {
    (context?.toolSchemas.map(\.name) ?? []).sorted()
}

// MARK: - (1) the filter RULE

@Test
func applyLazyToolFilter_dropsInactiveBuiltIns_keepsAlwaysOnCoreAndEveryMCPTool() {
    let filtered = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: catalogContext(), activeTools: []
    )
    // Empty active set is the fail-closed floor: core + MCP only.
    #expect(filteredNames(filtered) == [mcpName, alwaysOnName].sorted())
    #expect(!filteredNames(filtered).contains(lazyNameA))
    #expect(!filteredNames(filtered).contains(lazyNameB))
}

@Test
func applyLazyToolFilter_admitsExactlyTheNamedActiveTools() {
    let filtered = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: catalogContext(), activeTools: [lazyNameA]
    )
    #expect(filteredNames(filtered) == [mcpName, alwaysOnName, lazyNameA].sorted())
    // A tool that was never loaded stays out — the whole point of lazy loading.
    #expect(!filteredNames(filtered).contains(lazyNameB))
}

@Test
func applyLazyToolFilter_preservesTheRestOfTheTurnContextAndReturnsNilForNil() {
    let original = catalogContext()
    guard let rebuilt = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: original, activeTools: []
    ) else {
        Issue.record("applyLazyToolFilter returned nil for a non-nil context")
        return
    }
    // The filter rebuilds a 15-field context; a dropped field here is a silent
    // loss of persona/system/user content on every lazily-filtered turn.
    #expect(rebuilt.surface == original.surface)
    #expect(rebuilt.modelId == original.modelId)
    #expect(rebuilt.reasoningEffort == original.reasoningEffort)
    #expect(rebuilt.systemPrompt == original.systemPrompt)
    #expect(rebuilt.userMessage == original.userMessage)
    // `toolsAvailable` is the NAME list; it is deliberately not re-filtered,
    // pinned here so a change to that becomes a visible decision.
    #expect(rebuilt.toolsAvailable == original.toolsAvailable)

    #expect(SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: nil, activeTools: [lazyNameA]
    ) == nil)
}

// MARK: - (2) the DERIVATION that feeds it, and twin equality

private struct FilterPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class FilterRouting: ProviderRoutingProtocol, @unchecked Sendable {
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

private func makeFilterEngine(store: ActiveToolsStore) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: FilterPersona(),
        memory: nil,
        router: FilterRouting(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        activeToolsStore: store
    )
}

private func hermeticStoreRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lazyfilter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test
func lazyFilteredTurnContext_derivationFailsClosedOnAnEmptyOrNilSession() async throws {
    let root = try hermeticStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    // Something IS persisted — under a different session id.
    _ = try await store.addLoaded(sessionId: "other-session", names: [lazyNameA])
    let engine = makeFilterEngine(store: store)

    for sessionId in [nil, "", "   "] as [String?] {
        let filtered = await engine.lazyFilteredTurnContext(catalogContext(), sessionId: sessionId)
        #expect(
            filteredNames(filtered) == [mcpName, alwaysOnName].sorted(),
            "sessionId \(String(describing: sessionId)) leaked another session's loadout"
        )
    }
}

@Test
func lazyFilteredTurnContext_readsThePersistedSessionLoadout_andUnionsTheTurnLocal() async throws {
    let root = try hermeticStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    _ = try await store.addLoaded(sessionId: "s-1", names: [lazyNameA])
    let engine = makeFilterEngine(store: store)

    let persistedOnly = await engine.lazyFilteredTurnContext(catalogContext(), sessionId: "s-1")
    #expect(filteredNames(persistedOnly) == [mcpName, alwaysOnName, lazyNameA].sorted())

    // The turn-local mechanical preload set unions in — it never grows the file.
    let unioned = await LLMCallContext.$turnActiveTools.withValue([lazyNameB]) {
        await engine.lazyFilteredTurnContext(catalogContext(), sessionId: "s-1")
    }
    #expect(filteredNames(unioned) == [mcpName, alwaysOnName, lazyNameA, lazyNameB].sorted())
}

@Test
func lazyFilteredTurnContext_pinnedSetBypassesTheStoreRead_keepingTheCatalogByteStable() async throws {
    // turn-context-iteration-cache: a mid-turn `tool_load` must NOT grow the
    // advertised catalog inside the cache-breakpointed stable system segment.
    // A pinned set that started honoring the store again is a silent
    // prompt-cache bust (369k cache-creation tokens on one live turn), with no
    // failing assertion anywhere before this one.
    let root = try hermeticStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    _ = try await store.addLoaded(sessionId: "s-pin", names: [lazyNameA, lazyNameB])
    let engine = makeFilterEngine(store: store)

    let pinned = await engine.lazyFilteredTurnContext(
        catalogContext(), sessionId: "s-pin", pinnedActiveTools: []
    )
    #expect(filteredNames(pinned) == [mcpName, alwaysOnName].sorted())

    // Unpinned on the SAME session sees both — proving the pin, not an empty store.
    let unpinned = await engine.lazyFilteredTurnContext(catalogContext(), sessionId: "s-pin")
    #expect(filteredNames(unpinned) == [mcpName, alwaysOnName, lazyNameA, lazyNameB].sorted())
}

@Test
func lazyToolFilterTwins_agreeOnEveryInputInTheSameMatrix() async throws {
    // The anti-divergence assertion: for each case, the engine's derive+filter
    // must equal the client filter applied to the SAME effective active set.
    let root = try hermeticStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    _ = try await store.addLoaded(sessionId: "s-twin", names: [lazyNameA])
    let engine = makeFilterEngine(store: store)

    let cases: [(session: String?, turnLocal: Set<String>, expectedEffective: Set<String>)] = [
        (nil, [], []),
        ("", [lazyNameB], [lazyNameB]),
        ("s-twin", [], [lazyNameA]),
        ("s-twin", [lazyNameB], [lazyNameA, lazyNameB]),
        ("s-unknown", [lazyNameB], [lazyNameB]),
    ]

    for testCase in cases {
        let viaEngine = await LLMCallContext.$turnActiveTools.withValue(testCase.turnLocal) {
            await engine.lazyFilteredTurnContext(catalogContext(), sessionId: testCase.session)
        }
        let viaClient = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: catalogContext(), activeTools: testCase.expectedEffective
        )
        #expect(
            filteredNames(viaEngine) == filteredNames(viaClient),
            "twins diverged for session \(String(describing: testCase.session))"
        )
    }
}
