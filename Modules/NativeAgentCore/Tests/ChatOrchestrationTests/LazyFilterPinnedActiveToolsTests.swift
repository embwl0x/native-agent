import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import DreamREMCycle

// turn-context-iteration-cache (2026-08-13): the text-compat marker lane pins
// the advertised tool catalog to its turn-start set so a mid-turn tool_load
// (which writes ActiveToolsStore) cannot mutate the stable cache-breakpointed
// system segment on the next iteration's rebuild. These tests pin the seam:
// lazyFilteredTurnContext(pinnedActiveTools:) must IGNORE store growth, and
// the nil default must keep today's fresh-store-read behavior byte-for-byte.

fileprivate func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lazypin-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

fileprivate final class PinPersonaStub: PersonaEngineProtocol, @unchecked Sendable {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

fileprivate final class PinRoutingStub: ProviderRoutingProtocol, @unchecked Sendable {
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
    func computeModelPreferences() async throws -> [String: SurfacePreference] { [:] }
}

fileprivate func schema(_ name: String) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "probe schema \(name)",
        parametersJSON: try! JSONSerialization.data(withJSONObject: ["type": "object"])
    )
}

/// A context whose catalog carries one always-on tool, one mcp tool, and one
/// lazily-gated probe tool — the three filter classes.
fileprivate func probeContext() -> TurnContext {
    let alwaysOn = SwiftToolDispatcher.alwaysOnCoreNames.sorted().first ?? "recall_memory"
    return TurnContext(
        surface: "telegram",
        personaDocs: [:],
        recalled: [],
        modelId: "test-model",
        reasoningEffort: "low",
        toolsAvailable: [alwaysOn, "mcp__probe__x", "zz_lazy_probe"],
        systemPrompt: "sys",
        userMessage: "hello",
        toolSchemas: [schema(alwaysOn), schema("mcp__probe__x"), schema("zz_lazy_probe")]
    )
}

fileprivate func makeEngine(store: ActiveToolsStore) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: PinPersonaStub(),
        memory: nil,
        router: PinRoutingStub(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        activeToolsStore: store
    )
}

@Test func pinnedSetIgnoresMidTurnStoreGrowth() async throws {
    let root = try makeTempDir("grow")
    let store = ActiveToolsStore(dataRoot: root)
    let engine = makeEngine(store: store)
    let session = "pin-session"

    // Turn start: probe tool NOT loaded. The loop captures this set and pins it.
    let pinned: Set<String> = []

    // Mid-turn tool_load lands in the store (iteration N).
    _ = try await store.addLoaded(sessionId: session, names: ["zz_lazy_probe"])

    // Iteration N+1 rebuild with the pin: catalog must NOT grow.
    let pinnedCtx = await engine.lazyFilteredTurnContext(
        probeContext(), sessionId: session, pinnedActiveTools: pinned
    )
    #expect(!pinnedCtx.toolSchemas.map(\.name).contains("zz_lazy_probe"))

    // Same rebuild WITHOUT the pin (today's behavior): store read wins.
    let unpinnedCtx = await engine.lazyFilteredTurnContext(
        probeContext(), sessionId: session
    )
    #expect(unpinnedCtx.toolSchemas.map(\.name).contains("zz_lazy_probe"))
}

@Test func pinnedSetAdvertisesItsOwnTools() async throws {
    let root = try makeTempDir("own")
    let store = ActiveToolsStore(dataRoot: root)
    let engine = makeEngine(store: store)

    // Pin carries the probe tool (turn-start set included it); the store has
    // nothing — the pin alone must advertise it.
    let ctx = await engine.lazyFilteredTurnContext(
        probeContext(), sessionId: "pin-own", pinnedActiveTools: ["zz_lazy_probe"]
    )
    #expect(ctx.toolSchemas.map(\.name).contains("zz_lazy_probe"))
}

@Test func pinnedFilterKeepsAlwaysOnAndMCPClasses() async throws {
    let root = try makeTempDir("classes")
    let store = ActiveToolsStore(dataRoot: root)
    let engine = makeEngine(store: store)
    let alwaysOn = SwiftToolDispatcher.alwaysOnCoreNames.sorted().first ?? "recall_memory"

    let ctx = await engine.lazyFilteredTurnContext(
        probeContext(), sessionId: "pin-classes", pinnedActiveTools: []
    )
    let names = ctx.toolSchemas.map(\.name)
    #expect(names.contains(alwaysOn))
    #expect(names.contains("mcp__probe__x"))
}

@Test func turnStartEquivalence_pinnedMatchesUnpinnedWhenStoreUnchanged() async throws {
    let root = try makeTempDir("equiv")
    let store = ActiveToolsStore(dataRoot: root)
    let engine = makeEngine(store: store)
    let session = "pin-equiv"
    _ = try await store.addLoaded(sessionId: session, names: ["zz_lazy_probe"])

    // Iteration 1: the loop's pinned set == the store set it just loaded.
    let pinned = await store.load(sessionId: session).activeTools
    let pinnedCtx = await engine.lazyFilteredTurnContext(
        probeContext(), sessionId: session, pinnedActiveTools: pinned
    )
    let unpinnedCtx = await engine.lazyFilteredTurnContext(
        probeContext(), sessionId: session
    )
    #expect(pinnedCtx.toolSchemas.map(\.name) == unpinnedCtx.toolSchemas.map(\.name))
}

@Test func toolLoadProjectionBudgetCoversFullCatalog() {
    // Review fix (gpt-5.5, 2026-08-13): with the catalog pinned per turn,
    // tool_load's schemas_added is the model's only in-turn schema source —
    // its provider projection budget must exceed the full eager catalog
    // (~73KB) so no category load truncates, while staying a real ceiling.
    #expect(ProviderToolResultProjection.maxUTF8Bytes(for: "tool_load") == 96_000)
    #expect(ProviderToolResultProjection.maxUTF8Bytes(for: "tool_load")
            > ProviderToolResultProjection.defaultMaxUTF8Bytes)
}

@Test func clockNowOverridePinsDynamicSegmentAcrossBuilds() async throws {
    // Clock-churn follow-up (2026-08-13): the clock line renders into the
    // DYNAMIC system segment; two builds in the same turn that cross a
    // minute boundary produced different bytes (byte-diff: "5:59 PM" ->
    // "6:00 PM") and busted the prompt cache. clockNowOverride freezes the
    // turn's instant: same override -> byte-identical dynamic segment,
    // different minutes -> different (proves the override drives the line).
    let root = try makeTempDir("clock")
    let store = ActiveToolsStore(dataRoot: root)
    let engine = makeEngine(store: store)
    let t0 = Date(timeIntervalSince1970: 1_786_650_000)
    let t1 = t0.addingTimeInterval(120)

    func dyn(_ now: Date) async throws -> String {
        let ctx = try await engine.buildTurnContext(
            surface: "telegram",
            userMessage: "hello there",
            personaOverride: nil,
            imageBlocks: [],
            clockNowOverride: now
        )
        return ctx.systemSegments?.dynamic ?? ctx.systemPrompt ?? ""
    }

    let a1 = try await dyn(t0)
    let a2 = try await dyn(t0)
    let b = try await dyn(t1)
    #expect(a1 == a2, "same turn instant must render byte-identical dynamics")
    #expect(a1 != b, "a different minute must change the clock line")
}

@Test func clockNowOverridePinsDynamicSegment_historyPathToo() async throws {
    // gpt-5.5 delta review (98c6094c1d9c) BLOCKING: the history-present path
    // has its OWN contextByAppendingCurrentTurnFacts call site
    // (SessionHistory :937) which shipped unpinned while the no-history
    // branch was pinned — this regression drives buildTurnContextWithHistory
    // with REAL session history so that exact site is the one under test.
    let root = try makeTempDir("clockhist")
    let store = ActiveToolsStore(dataRoot: root)
    let engine = makeEngine(store: store)
    let session = "clock-hist-s1"
    let msgsDir = root.appendingPathComponent("chat/messages", isDirectory: true)
    try FileManager.default.createDirectory(at: msgsDir, withIntermediateDirectories: true)
    let rows = [
        ["role": "user", "content": "remember the zephyr marker", "id": UUID().uuidString,
         "createdAt": "2026-08-13T20:00:00.000Z", "runId": "r1", "sessionId": session, "source": "chat"],
        ["role": "assistant", "content": "zephyr marker noted", "id": UUID().uuidString,
         "createdAt": "2026-08-13T20:00:01.000Z", "runId": "r1", "sessionId": session, "source": "chat"],
    ]
    let jsonl = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        .joined(separator: "\n") + "\n"
    try jsonl.write(to: msgsDir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)

    let t0 = Date(timeIntervalSince1970: 1_786_650_000)
    let t1 = t0.addingTimeInterval(120)
    func dyn(_ now: Date) async throws -> String {
        let ctx = try await engine.buildTurnContextWithHistory(
            surface: "telegram",
            userMessage: "hello again",
            sessionId: session,
            historyLimit: 10,
            historyReader: SessionHistoryReader(dataRoot: root),
            personaOverride: nil,
            excludeHistoryRunId: nil,
            clockNowOverride: now
        )
        // Prove the HISTORY path actually ran (the seeded turn is in the prompt).
        #expect(ctx.systemPrompt?.contains("zephyr marker") == true)
        return ctx.systemSegments?.dynamic ?? ctx.systemPrompt ?? ""
    }
    let a1 = try await dyn(t0)
    let a2 = try await dyn(t0)
    let b = try await dyn(t1)
    #expect(a1 == a2, "history path: same instant must render byte-identical dynamics")
    #expect(a1 != b, "history path: a different minute must change the clock line")
}
