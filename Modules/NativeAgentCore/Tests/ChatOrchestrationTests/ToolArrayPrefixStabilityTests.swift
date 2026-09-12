import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - The `tools` array is the cached prefix on routes with no defer lane
//
// Live session D53339E5 (2026-09-11, gpt-6-astra via openai_oauth_direct): all
// 18 session tool rows were route-preload PROMOTIONS, the advertised array
// moved 70 → 69 → 68 over three consecutive turns, and every turn's FIRST
// provider call read 0 cached tokens while every within-turn call hit ~27k.
//
// The first attempt at a fix (d136b9f9) gated the PROMOTION to the Anthropic
// defer lane. That was the wrong half: it cost every OpenAI route its
// first-call preload — a confidently routed GitHub/mail/calendar request had
// to spend a whole round on `tool_load` — and it did not actually stabilise
// the array, because the idle drop still moved it.
//
// What stabilises it is the APPEND-ONLY OFFER FLOOR: the promotion happens on
// every route, and on a route with no defer lane a name that has been declared
// once KEEPS its slot through idle turns and through route-prediction changes.
// Bounded at 40, LRU-evicted at a turn boundary only, and the eviction is
// recorded so a fingerprint move always has a reason next to it.

private func prefixSchema(_ name: String) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "test tool \(name)",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
}

/// One turn on a stable-array (no defer lane) route: the real turn-start pair,
/// then the real advertised array and its real `component.toolsSHA256`.
private struct PrefixTurnHarness {
    let store: ActiveToolsStore
    let session: String
    let catalog: [LLMToolSchema]

    @discardableResult
    func turn(
        promoting: Set<String> = [],
        stableToolArray: Bool = true
    ) async -> (advertised: [String], toolsSHA256: String, commit: ActiveToolsStore.TurnContractCommit) {
        await store.beginTurn(sessionId: session)
        let commit = await store.commitTurnStartContract(
            sessionId: session,
            promoting: promoting,
            catalog: catalog,
            stableToolArray: stableToolArray
        )!
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "gpt-6-astra",
            reasoningEffort: "high",
            toolsAvailable: catalog.map(\.name),
            systemPrompt: "sys",
            userMessage: "hi",
            toolSchemas: catalog
        )
        let filtered = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: ctx,
            activeTools: commit.state.activeTools,
            contract: commit.state.toolContract
        )
        let schemas = filtered?.toolSchemas ?? []
        return (
            schemas.map(\.name),
            SwiftNativeTurnEngine.toolSchemaFingerprint(schemas),
            commit
        )
    }
}

private func makeHarness(
    extraTools: [String],
    file: String = #filePath
) throws -> (PrefixTurnHarness, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("a3-prefix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let names = SwiftToolDispatcher.alwaysOnCoreNames.sorted() + extraTools
    return (
        PrefixTurnHarness(
            store: ActiveToolsStore(dataRoot: root),
            session: "11111111-2222-3333-4444-555555555555",
            catalog: names.map(prefixSchema)
        ),
        root
    )
}

// MARK: - (a) two ordinary turns, no tool use, identical toolsSHA256

@Test
func toolsFingerprint_isByteIdenticalAcrossTwoOrdinaryTurns() async throws {
    let (h, root) = try makeHarness(
        extraTools: ["github_read", "delegation_status", "task_ledger_post"]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    // A routed turn declares a family...
    _ = await h.turn(promoting: ["github_read"])
    // ...and then two ORDINARY turns: no prediction, no tool use, nothing
    // loaded. The array the model reads must not move by a byte, or the
    // ~27k-token prefix is re-read at full price on each first call.
    let first = await h.turn()
    let second = await h.turn()
    #expect(first.toolsSHA256 == second.toolsSHA256)
    #expect(first.advertised == second.advertised)
    // And it is not stable merely by being empty.
    #expect(second.advertised.contains("github_read"))
}

// MARK: - (b) a routed request gets its predicted tools on call 1

@Test
func routedRequest_getsItsPredictedToolsOnTheFirstCall() async throws {
    let (h, root) = try makeHarness(
        extraTools: ["github_read", "github_search", "delegation_status"]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    // This is the regression d136b9f9 introduced: on openai_oauth_direct the
    // promotion set was forced empty, so a confidently routed GitHub request
    // saw no GitHub schemas until `tool_load` bought them with a whole round.
    let routed = await h.turn(promoting: ["github_read", "github_search"])
    #expect(routed.commit.promoted.isSuperset(of: ["github_read", "github_search"]))
    #expect(routed.advertised.contains("github_read"))
    #expect(routed.advertised.contains("github_search"))
}

// MARK: - (c) a declared tool holds its slot through the idle WINDOW, then goes
//
// 2026-09-12, User: "a tool not called for two turns unloads" — from the offer
// floor too, not only the active set. The append-only floor of 2026-09-11
// restored every idle-dropped name for cache stability and silently overrode
// rule 2 of docs/TOOL_LOADING.md. The one missed cache read after a drop is the
// accepted price; within the window the array is still byte-stable.

@Test
func declaredTool_unloadsAfterTwoIdleTurns() async throws {
    let (h, root) = try makeHarness(
        extraTools: ["github_read", "mail_send", "calendar_list"]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    _ = await h.turn(promoting: ["github_read"])   // turn 1: joins the floor
    _ = await h.turn()                             // turn 2: idle
    // `idleTurnsBeforeDrop` is 2, counted from the turn it joined, so turn 3 is
    // the last turn inside the window: the array has not moved yet.
    let lastTurnInWindow = await h.turn()
    #expect(lastTurnInWindow.advertised.contains("github_read"))

    // Turn 4 is past the window with no gated call on it: it unloads.
    let afterTheDrop = await h.turn()
    #expect(!afterTheDrop.advertised.contains("github_read"))
    // Only the always-on core is exempt from the idle unload.
    #expect(Set(afterTheDrop.advertised) == SwiftToolDispatcher.alwaysOnCoreNames)

    // Evidence is a REAL call, and it is what keeps a name: a different route
    // declares mail_send, the session calls it, and the next turn still has it.
    let differentRoute = await h.turn(promoting: ["mail_send"])
    #expect(differentRoute.advertised.contains("mail_send"))
    await h.store.markUsed(sessionId: h.session, names: ["mail_send"])
    let afterACall = await h.turn()
    #expect(afterACall.advertised.contains("mail_send"))
    // Append-only within the window: every name the earlier turn advertised is
    // still advertised, in the same relative order.
    let kept = afterACall.advertised.filter { differentRoute.advertised.contains($0) }
    #expect(kept == differentRoute.advertised)
}

// MARK: - (d) the 41st distinct tool evicts the LRU one, at the turn boundary

@Test
func fortyFirstTool_evictsTheLeastRecentlyUsedAndRecordsIt() async throws {
    let names = (0..<41).map { String(format: "prefix_tool_%02d", $0) }
    let (h, root) = try makeHarness(extraTools: names)
    defer { try? FileManager.default.removeItem(at: root) }

    // Fill the floor exactly.
    let filled = await h.turn(promoting: Set(names.prefix(40)))
    #expect(filled.commit.state.offerFloor?.count == 40)
    #expect(filled.commit.state.lastOfferEvicted == nil)

    // Touch every one of them EXCEPT prefix_tool_07, so the LRU is unambiguous
    // rather than an alphabetical tie-break.
    _ = await h.turn()
    await h.store.markUsed(
        sessionId: h.session,
        names: Set(names.prefix(40)).subtracting(["prefix_tool_07"])
    )

    // The 41st distinct tool: one slot must come free, and only here, at the
    // turn boundary — never mid-turn, where it would shrink a live array.
    let overflowed = await h.turn(promoting: ["prefix_tool_40"])
    #expect(overflowed.commit.state.offerFloor?.count == 40)
    #expect(overflowed.commit.state.lastOfferEvicted == ["prefix_tool_07"])
    #expect(overflowed.commit.state.offerFloor?.contains("prefix_tool_40") == true)
    #expect(overflowed.commit.state.offerFloor?.contains("prefix_tool_07") == false)
    #expect(overflowed.advertised.contains("prefix_tool_40"))
    #expect(!overflowed.advertised.contains("prefix_tool_07"))
}

// MARK: - (e) the bound holds on EVERY path that grows the floor

@Test
func explicitToolLoad_cannotPushTheFloorPastItsBound() async throws {
    let names = (0..<42).map { String(format: "prefix_tool_%02d", $0) }
    let (h, root) = try makeHarness(extraTools: names)
    defer { try? FileManager.default.removeItem(at: root) }

    let filled = await h.turn(promoting: Set(names.prefix(40)))
    #expect(filled.commit.state.offerFloor?.count == 40)
    _ = await h.turn()
    await h.store.markUsed(
        sessionId: h.session,
        names: Set(names.prefix(40)).subtracting(["prefix_tool_07"])
    )

    // GPT-5.6 review 2026-09-11: an explicit `tool_load` protected BOTH the
    // floor and its own names from every bound, so the 41st load produced 41
    // advertised tools and each later load added another.
    let loaded = try await h.store.addLoaded(
        sessionId: h.session, names: ["prefix_tool_40"]
    )
    #expect(loaded.activeTools.contains("prefix_tool_40"))
    #expect(!loaded.activeTools.contains("prefix_tool_07"))

    let next = await h.turn()
    #expect(next.commit.state.offerFloor?.count == 40)
    #expect(next.commit.state.offerFloor?.contains("prefix_tool_40") == true)
    #expect(next.advertised.contains("prefix_tool_40"))
    #expect(!next.advertised.contains("prefix_tool_07"))
}

@Test
func explicitToolLoad_isRefusedWhenTheRequestItselfCannotFit() async throws {
    let names = (0..<82).map { String(format: "prefix_tool_%02d", $0) }
    let (h, root) = try makeHarness(extraTools: names)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = await h.turn(promoting: Set(names.prefix(40)))
    // 41 names in one load cannot fit under any eviction: refuse rather than
    // exceed the bound.
    await #expect(throws: (any Error).self) {
        _ = try await h.store.addLoaded(
            sessionId: h.session, names: Set(names[40..<81])
        )
    }
    let untouched = await h.store.load(sessionId: h.session)
    #expect(untouched.offerFloor?.count == 40)
    #expect(untouched.activeTools.count == 40)
}

// MARK: - (f) tool_unload actually unloads

@Test
func toolUnload_takesTheNameOutOfTheOfferFloor() async throws {
    let (h, root) = try makeHarness(extraTools: ["github_read", "mail_send"])
    defer { try? FileManager.default.removeItem(at: root) }

    _ = await h.turn(promoting: ["github_read", "mail_send"])
    // The floor restored every entry at the next turn start, so an unload —
    // including `all` — came back one turn later.
    _ = try await h.store.removeLoaded(sessionId: h.session, names: ["github_read"])
    let afterOne = await h.turn()
    #expect(!afterOne.advertised.contains("github_read"))
    #expect(afterOne.advertised.contains("mail_send"))

    _ = try await h.store.removeLoaded(sessionId: h.session, names: [], all: true)
    let afterAll = await h.turn()
    #expect(!afterAll.advertised.contains("mail_send"))
    #expect(afterAll.commit.state.offerFloor?.isEmpty == true)
}

// MARK: - (g) a floor entry the catalog no longer carries is never advertised

@Test
func floorEntryMissingFromTheCatalog_isDroppedNotRestoredFromAStaleSchema() async throws {
    let (h, root) = try makeHarness(extraTools: ["github_read", "mail_send"])
    defer { try? FileManager.default.removeItem(at: root) }

    _ = await h.turn(promoting: ["github_read", "mail_send"])
    // The catalog loses mail_send (policy flip, registry removal). Dispatch
    // reads the LIVE catalog, so advertising it from the pinned schema offers
    // a row nothing can execute.
    let shrunk = PrefixTurnHarness(
        store: h.store,
        session: h.session,
        catalog: h.catalog.filter { $0.name != "mail_send" }
    )
    let next = await shrunk.turn()
    #expect(next.commit.state.offerFloor?.contains("mail_send") == false)
    #expect(!next.advertised.contains("mail_send"))
    #expect(next.advertised.contains("github_read"))
}

// MARK: - the route gate still picks the defer lane

@Test
func routeGate_namesTheOnlyLaneThatCanDeclareWithoutOffering() {
    // These routes have NO defer lane, so they get the append-only offer floor
    // (`stableToolArray: true`) — not an empty promotion set.
    #expect(
        SwiftNativeChatOrchestrationClient.routeCanDeclareWithoutOffering(
            providerId: "openai_oauth_direct", modelId: "gpt-6-astra"
        ) == false
    )
    #expect(
        SwiftNativeChatOrchestrationClient.routeCanDeclareWithoutOffering(
            providerId: "openai", modelId: "gpt-5.6"
        ) == false
    )
    #expect(
        SwiftNativeChatOrchestrationClient.routeCanDeclareWithoutOffering(
            providerId: nil, modelId: "claude-opus-5"
        ) == false
    )
    // The defer lane: the frozen declaration is the array there, so the
    // offered set may move freely behind the cache breakpoint.
    #expect(
        SwiftNativeChatOrchestrationClient.routeCanDeclareWithoutOffering(
            providerId: "Anthropic", modelId: "claude-opus-5"
        ) == true
    )
}
