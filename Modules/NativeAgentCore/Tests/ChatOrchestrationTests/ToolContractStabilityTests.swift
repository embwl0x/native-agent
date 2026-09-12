import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - Advertised tool contract: byte-stable across a session, append-only
//
// Measured before this change: 50-79 schemas per turn, the text catalog sorted
// alphabetically so one load or expiry shifted every later row, `context_expand`
// added or omitted per turn depending on whether the packet had pointers, and
// per-turn PREDICTED preloads inserted straight into the advertised set. Each
// of those rewrote the provider's cached prefix for a reason the model never
// asked about.
//
// Silent-failure class: wrong value with no error anywhere. A reshuffled
// catalog reads perfectly to a human and costs full-price uncached input on
// every turn. These tests are the proof that consecutive turns carry the same
// contract, not the assumption.

private func schema(_ name: String) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "test tool \(name)",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
}

private let coreA = "recall_memory"          // always-on floor
private let coreB = "commit_memory"          // always-on floor
private let lazyA = "workshop_submit"        // lazy built-in
private let lazyB = "task_ledger_post"       // lazy built-in
private let lazyC = "delegation_status"      // lazy built-in
private let mcpName = "mcp__server__do_thing"

private func context(_ names: [String]) -> TurnContext {
    let schemas = names.map(schema)
    return TurnContext(
        surface: "chat",
        personaDocs: [:],
        recalled: [],
        modelId: "m",
        reasoningEffort: "high",
        toolsAvailable: names,
        systemPrompt: "sys",
        userMessage: "hi",
        toolSchemas: schemas
    )
}

/// 2026-09-06: `declarationGeneration` now decides whether the contract's MCP
/// membership is authority. `applyLazyToolFilter` reads
/// `(contract?.declarationGeneration ?? 0) > 0 ? contract?.pinnedMCPNames : nil`
/// — a store-derived contract that has never taken a turn-start snapshot
/// carries an EMPTY mcp set, which means "not yet snapshotted", not "no MCP",
/// so generation 0 falls back to the no-contract arm and admits `mcp__*` by
/// prefix. Every contract these rows build stands for one a turn start pinned,
/// so the fixture says generation 1; that is also what makes pinned MCP members
/// sort ahead of the resident family and the load run, since they are then
/// excluded from the rank list and rank as unranked.
private func contract(
    order: [String],
    loaded: Set<String>,
    pinned: [String: PinnedToolSchema] = [:],
    declarationGeneration: Int = 1
) -> SessionToolContract {
    var descriptors = pinned
    for name in order where descriptors[name] == nil {
        descriptors[name] = PinnedToolSchema(schema(name))
    }
    return SessionToolContract(
        order: order,
        loaded: loaded,
        pinnedSchemas: descriptors,
        declarationGeneration: declarationGeneration
    )
}

private func advertised(
    _ names: [String],
    active: Set<String>,
    loadOrder: [String]?
) -> [String] {
    // MCP is admitted from the pinned snapshot now, so a test catalog's MCP
    // rows have to be in the contract order to be advertised at all.
    let resolved = loadOrder.map { order -> SessionToolContract in
        let mcp = names.filter { $0.hasPrefix("mcp__") && !order.contains($0) }
        return contract(order: mcp + order, loaded: active)
    }
    return SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: context(names),
        activeTools: active,
        contract: resolved
    )?.toolSchemas.map(\.name) ?? []
}

// MARK: - Fingerprint stability

@Test
func toolContract_fingerprintIsIdenticalAcrossTwoTurnsWithNoLoad() {
    let catalog = [lazyA, coreB, mcpName, coreA]
    let turnOne = SwiftToolDispatcher.canonicalToolOrder(catalog, loadOrder: [lazyA])
    let turnTwo = SwiftToolDispatcher.canonicalToolOrder(catalog, loadOrder: [lazyA])
    #expect(turnOne == turnTwo)
    #expect(turnOne.fingerprintSHA256 == turnTwo.fingerprintSHA256)
    // A catalog enumerated in a DIFFERENT walk order must still fingerprint
    // the same: registry/MCP iteration order is not a contract change.
    let shuffled = SwiftToolDispatcher.canonicalToolOrder(
        [coreA, coreB, lazyA, mcpName],
        loadOrder: [lazyA]
    )
    #expect(shuffled.floor == turnOne.floor)
}

@Test
func toolContract_aLoadAppendsExactlyItsRowsAndChangesTheFingerprintOnce() {
    let before = SwiftToolDispatcher.canonicalToolOrder(
        [coreA, coreB, mcpName, lazyA],
        loadOrder: [lazyA]
    )
    let after = SwiftToolDispatcher.canonicalToolOrder(
        [coreA, coreB, mcpName, lazyA, lazyB],
        loadOrder: [lazyA, lazyB]
    )
    // The floor did not move. This is the whole point: a load must not shift
    // a single row that precedes it.
    #expect(after.floor == before.floor)
    // The appended run GREW at the tail and kept its existing order.
    #expect(after.appended == before.appended + [lazyB])
    #expect(after.fingerprintSHA256 != before.fingerprintSHA256)
    // ...and once only. Re-deriving the same state is the same fingerprint.
    let again = SwiftToolDispatcher.canonicalToolOrder(
        [coreA, coreB, mcpName, lazyA, lazyB],
        loadOrder: [lazyA, lazyB]
    )
    #expect(again.fingerprintSHA256 == after.fingerprintSHA256)
}

@Test
func toolContract_mcpRowsSortAheadOfTheSessionLoadRunSoALoadOnlyAppends() {
    // MCP rows are present from a session's first turn. If a tool_load could
    // land BEFORE them, every MCP row would shift and the prefix would break
    // for a reason that has nothing to do with MCP.
    let ordering = SwiftToolDispatcher.canonicalToolOrder(
        ["mcp__b__two", "mcp__a__one", lazyA],
        loadOrder: [lazyA]
    )
    #expect(ordering.appended == ["mcp__b__two", "mcp__a__one", lazyA])
}

// MARK: - The floor

@Test
func toolContract_floorIsSortedByNameAndNeverTruncated() {
    let floorNames = SwiftToolDispatcher.alwaysOnCoreNames.sorted()
    let appendedNames = (0..<120).map { "mcp__flood__tool_\(String(format: "%03d", $0))" }
    let sections = SwiftNativeTurnEngine.textToolCatalogSections(
        schemas: (floorNames + appendedNames).map(schema),
        names: []
    )
    let floorRows = sections.floor.split(separator: "\n").map(String.init)
    #expect(floorRows.count == floorNames.count)
    #expect(floorRows.map { String($0.dropFirst(2).prefix(while: { $0 != "(" && $0 != ":" })) }
        == floorNames)
    // The bounded catalog cap belongs to the appended run alone.
    let appendedRows = sections.appended.split(separator: "\n").map(String.init)
    #expect(appendedRows.first == "Also loaded this session:")
    #expect(appendedRows.contains { $0.contains("40 more tools not listed") })
}

@Test
func toolContract_contextExpandIsAlwaysPresent() {
    // It is floor, not packet-scoped. A floor row that appears and disappears
    // with the turn's packet is a per-turn prefix rewrite wearing a floor's
    // name.
    #expect(SwiftToolDispatcher.alwaysOnCoreNames.contains("context_expand"))
    let seeded = TurnToolSchemaCatalogSeed(schemas: [schema("read_file"), schema(lazyA)])
    #expect(seeded.schemas.map(\.name) == ["read_file", "context_expand", lazyA])
    let ordering = SwiftToolDispatcher.canonicalToolOrder(seeded.schemas.map(\.name))
    #expect(ordering.floor.contains("context_expand"))
    #expect(!ordering.appended.contains("context_expand"))
}

// MARK: - Predicted preloads: promoted at turn start, then advertised

@Test
func toolContract_promotedPreloadIsAdvertisedInTheAppendedRun() {
    let catalog = [coreA, lazyA, lazyB, mcpName]
    // Turn start promoted lazyB into the session load order, so from here it
    // IS the contract — docs/ANATOMY_OF_A_TURN.md §3 promises the prepared
    // tools arrive with no discovery round, which needs their schemas in the
    // prefix the model is about to read.
    let rows = advertised(catalog, active: [lazyA, lazyB], loadOrder: [lazyA, lazyB])
    #expect(rows == [coreA, mcpName, lazyA, lazyB])

    // A name that was NOT promoted (no session row) is still dispatch-only:
    // the appended run is the load order, nothing else.
    let unpromoted = advertised(catalog, active: [lazyA, lazyB], loadOrder: [lazyA])
    #expect(unpromoted == [coreA, mcpName, lazyA])
    #expect(SwiftToolDispatcher.normalModelToolNames(activeTools: [lazyA, lazyB])
        .contains(lazyB))
    // No session load order (no session) keeps the legacy behavior.
    #expect(advertised(catalog, active: [lazyA, lazyB], loadOrder: nil).contains(lazyB))
}

@Test
func toolContract_promotingAPreloadChangesTheFingerprintExactlyOnce() {
    let catalog = [coreA, coreB, mcpName, lazyA, lazyB]
    let beforePreload = SwiftToolDispatcher.canonicalToolOrder(
        [coreA, coreB, mcpName, lazyA],
        loadOrder: [lazyA]
    )
    // The turn a confident preload is promoted: one append, one new
    // fingerprint.
    let promoted = SwiftToolDispatcher.canonicalToolOrder(catalog, loadOrder: [lazyA, lazyB])
    #expect(promoted.floor == beforePreload.floor)
    #expect(promoted.appended == beforePreload.appended + [lazyB])
    #expect(promoted.fingerprintSHA256 != beforePreload.fingerprintSHA256)
    // Every later turn that keeps it loaded re-derives the SAME contract — a
    // preload must not re-append or re-sort on the turns after it lands.
    let nextTurn = SwiftToolDispatcher.canonicalToolOrder(catalog, loadOrder: [lazyA, lazyB])
    #expect(nextTurn.fingerprintSHA256 == promoted.fingerprintSHA256)
}

// 2026-09-12, User: there is no resident family. Full Mac membership put ~25
// schemas on every call, one-word turns included; the family now preloads on
// intent and unloads after two unused turns like everything else. So the
// contract's `order` is the ONLY way a non-core name is advertised — being
// merely ACTIVE leaves a tool dispatch-only.
@Test
func toolContract_fullMacFamilyIsNotResidentAndNeedsTheContractOrder() {
    #expect(ToolPreloadHeuristics.immediateFullMacTools(
        availableToolNames: ["shell", "bash", "read_file", "write_file", "git_status"]
    ).isEmpty)

    let catalog = [coreA, "shell", "bash", "read_file", lazyA, mcpName]
    let rows = advertised(catalog, active: ["shell", "bash", "read_file", lazyA], loadOrder: [lazyA])
    #expect(rows == [coreA, mcpName, lazyA])

    // Loading one more tool leaves every preceding row where it was.
    let grown = advertised(
        catalog + [lazyB],
        active: ["shell", "bash", "read_file", lazyA, lazyB],
        loadOrder: [lazyA, lazyB]
    )
    #expect(grown == rows + [lazyB])

    // The same three names, once a real load puts them in the order, are
    // advertised in load order and still sort behind the floor and pinned MCP.
    let loaded = advertised(
        catalog,
        active: ["shell", "bash", "read_file", lazyA],
        loadOrder: ["bash", "read_file", "shell", lazyA]
    )
    #expect(loaded == [coreA, mcpName, "bash", "read_file", "shell", lazyA])
}

@Test
func toolContract_structuredLaneAdvertisesInCanonicalOrder() {
    // The structured lane's `tools` array and the text lane's rendered catalog
    // both derive from THIS array, so the two lanes cannot disagree.
    let rows = advertised(
        [lazyB, coreB, mcpName, lazyA, coreA],
        active: [lazyA, lazyB],
        loadOrder: [lazyA, lazyB]
    )
    // The floor is sorted BY NAME (see
    // `toolContract_floorIsSortedByNameAndNeverTruncated`), not by the order
    // the constants happen to be declared in: commit_memory precedes
    // recall_memory.
    #expect(rows == [coreB, coreA, mcpName, lazyA, lazyB])
}

// MARK: - Rendered catalog

@Test
func toolContract_freshSessionRenderMatchesTheOldSingleSortedCatalog() {
    // The pre-2026-09-01 renderer emitted ONE "Available Swift tools:" block
    // holding every schema sorted by name. On a fresh session every advertised
    // tool is floor, so the new renderer must produce exactly that: the same
    // rows, the same order, one section, no suffix. (The surrounding protocol
    // prose is untouched by this change and shared by both paths, so equal
    // sections means equal bytes.)
    let floorNames = SwiftToolDispatcher.alwaysOnCoreNames.sorted()
    let sections = SwiftNativeTurnEngine.textToolCatalogSections(
        schemas: floorNames.shuffled().map(schema),
        names: []
    )
    #expect(sections.appended.isEmpty)
    let expectedRows = floorNames
        .map { "- \($0): test tool \($0)" }
        .joined(separator: "\n")
    #expect(sections.floor == expectedRows)

    let ctx = context(floorNames)
    let rendered = SwiftNativeTurnEngine.withTextToolCompatibilityInstructions(
        "PERSONA", context: ctx
    )
    #expect(rendered.contains("Available Swift tools:"))
    #expect(!rendered.contains("Also loaded this session:"))
    #expect(rendered.hasSuffix(expectedRows))
}

@Test
func toolContract_sessionLoadedToolsRenderInTheirOwnAppendedSection() {
    let sections = SwiftNativeTurnEngine.textToolCatalogSections(
        schemas: [coreA, coreB, lazyA, lazyB].map(schema),
        names: []
    )
    #expect(sections.floor.split(separator: "\n").count == 2)
    #expect(sections.appended == """
        Also loaded this session:
        - \(lazyA): test tool \(lazyA)
        - \(lazyB): test tool \(lazyB)
        """)
}

@Test
func toolContract_v1LayoutPutsTheAppendedCatalogInStableSuffixAndReassembles() {
    let ctx = context([coreA, coreB, lazyA])
    let segments = SystemPromptSegments(stable: "PERSONA", dynamic: "RECALL")
    let (system, out) = SwiftNativeTurnEngine.textToolCompatibilityLayout(
        baseSystem: segments.combined,
        segments: segments,
        context: ctx
    )
    guard let out else {
        Issue.record("layout dropped the segments")
        return
    }
    // The floor rides in `stable` (cacheable for the session's life); the
    // session-loaded run rides in the append-only `stableSuffix` so growing it
    // cannot move a byte of `stable`.
    #expect(out.stable.hasPrefix("PERSONA\n\n"))
    #expect(out.stable.contains("Available Swift tools:"))
    #expect(!out.stable.contains("Also loaded this session:"))
    #expect(out.stableSuffix.hasPrefix("Also loaded this session:"))
    #expect(out.stableSuffix.contains(lazyA))
    #expect(out.dynamic == "RECALL")
    // The split is a caching hint, never a content change.
    #expect(out.reassembles(into: system))

    // Loading one more tool must leave `stable` byte-identical.
    let grown = context([coreA, coreB, lazyA, lazyB])
    let (_, after) = SwiftNativeTurnEngine.textToolCompatibilityLayout(
        baseSystem: segments.combined,
        segments: segments,
        context: grown
    )
    #expect(after?.stable == out.stable)
    #expect(after?.stableSuffix.hasPrefix(out.stableSuffix) == true)
}

/// The measured failure (c83a39b8, claude-fable-5-1): turn 1 created 19,142
/// cache tokens; turn 2 read ZERO and re-created 19,737 because a promoted
/// preload grew the contract 65 → 66 and the appended rows lived in
/// `stableSuffix` — inside the cached prefix, ahead of the replayed messages.
/// On v2 the run leaves the prefix entirely.
@Test
func toolContract_v2LayoutKeepsTheAppendedCatalogOutOfTheCachedPrefix() {
    ConversationPrefixShape.$override.withValue(.v2Prefix) {
        let ctx = context([coreA, coreB, lazyA])
        let segments = SystemPromptSegments(stable: "PERSONA", dynamic: "RECALL")
        let (system, out) = SwiftNativeTurnEngine.textToolCompatibilityLayout(
            baseSystem: segments.combined,
            segments: segments,
            context: ctx
        )
        guard let out else {
            Issue.record("layout dropped the segments")
            return
        }
        // The floor is still cached prose; the session-loaded run is gone from
        // the prefix (ConversationPrefixSeeding.seed delivers it in the
        // per-turn volatile block instead).
        #expect(out.stable.contains("Available Swift tools:"))
        #expect(out.stable.contains(coreA))
        #expect(out.stableSuffix.isEmpty)
        #expect(!system.contains("Also loaded this session:"))
        #expect(!system.contains(lazyA))
        #expect(out.dynamic == "RECALL")
        #expect(out.reassembles(into: system))

        // THE fix: loading one more tool moves NOTHING in the cached prefix.
        let grown = context([coreA, coreB, lazyA, lazyB])
        let (_, after) = SwiftNativeTurnEngine.textToolCompatibilityLayout(
            baseSystem: segments.combined,
            segments: segments,
            context: grown
        )
        #expect(after?.stable == out.stable)
        #expect(after?.stableSuffix == out.stableSuffix)
    }
}

/// …and the rows are not lost: the seed hands them to the model as the
/// trailing section of the volatile block, after the capsule.
@Test
func toolContract_v2DeliversTheAppendedCatalogInTheVolatileBlockAfterTheCapsule() {
    let ctx = context([coreA, coreB, lazyA])
    let capsule = "[CognitiveSubstrate]\nfelt: steady"
    let segments = SystemPromptSegments(stable: "PERSONA", dynamic: "RECALL\n\n" + capsule)
    let seeded = TurnContext(
        surface: "chat", personaDocs: [:], recalled: [],
        modelId: "claude-fable-5-1", reasoningEffort: "high",
        providerId: "anthropic_oauth_direct",
        toolsAvailable: ctx.toolsAvailable,
        systemPrompt: segments.combined, userMessage: "hi",
        toolSchemas: ctx.toolSchemas,
        systemSegments: segments,
        historyMessages: [.user("earlier"), .assistantText("earlier reply")]
    )
    let appendix = SwiftNativeTurnEngine.textToolCatalogSections(
        schemas: ctx.toolSchemas, names: ctx.toolsAvailable
    ).appended
    let seed = ConversationPrefixSeeding.seed(
        seeded, shape: .v2Prefix, textToolCatalogAppendix: appendix
    )
    let block = seed.context.turnVolatileBlock ?? ""
    #expect(block.hasPrefix("RECALL"))
    #expect(block.contains(capsule))
    #expect(block.hasSuffix(appendix))
    #expect(block.contains(lazyA))
    // Its own trailing section, after the capsule — not spliced into it.
    #expect(block.range(of: capsule)!.upperBound
        <= block.range(of: "Also loaded this session:")!.lowerBound)
    #expect(seed.context.systemSegments?.stableSuffix.isEmpty == true)
    #expect(seed.textToolCatalogRidesVolatileBlock)

    // And the prefix fingerprint — the instrument that caught the miss — no
    // longer moves when the appended run grows.
    let grownAppendix = SwiftNativeTurnEngine.textToolCatalogSections(
        schemas: [coreA, coreB, lazyA, lazyB].map(schema),
        names: [coreA, coreB, lazyA, lazyB]
    ).appended
    let grownSeed = ConversationPrefixSeeding.seed(
        seeded, shape: .v2Prefix, textToolCatalogAppendix: grownAppendix
    )
    #expect(grownAppendix != appendix)
    #expect(
        ConversationPrefixSeeding.telemetry(
            seed, shape: .v2Prefix, toolSchemaFingerprint: "tools-65"
        ).prefixFingerprintSHA256
        == ConversationPrefixSeeding.telemetry(
            grownSeed, shape: .v2Prefix, toolSchemaFingerprint: "tools-66"
        ).prefixFingerprintSHA256
    )
}

/// The structured/native lane is untouched — it has no prose catalog to move,
/// its contract is the provider's `tools` array, and a contract change there
/// still reports a moved prefix. (Anthropic's mid-conversation `tool_addition`
/// content blocks are that lane's equivalent fix — follow-up.)
@Test
func toolContract_structuredLanePrefixFingerprintStillMovesWithTheToolsArray() {
    let segments = SystemPromptSegments(stable: "PERSONA", dynamic: "RECALL")
    let structured = TurnContext(
        surface: "chat", personaDocs: [:], recalled: [],
        modelId: "claude-fable-5-1", reasoningEffort: "high",
        providerId: "anthropic_oauth_direct",
        toolsAvailable: [coreA, lazyA],
        systemPrompt: segments.combined, userMessage: "hi",
        toolSchemas: [coreA, lazyA].map(schema),
        systemSegments: segments,
        historyMessages: [.user("earlier"), .assistantText("earlier reply")]
    )
    let seed = ConversationPrefixSeeding.seed(structured, shape: .v2Prefix)
    #expect(!seed.textToolCatalogRidesVolatileBlock)
    #expect(seed.context.turnVolatileBlock == "RECALL")
    #expect(
        ConversationPrefixSeeding.telemetry(
            seed, shape: .v2Prefix, toolSchemaFingerprint: "tools-65"
        ).prefixFingerprintSHA256
        != ConversationPrefixSeeding.telemetry(
            seed, shape: .v2Prefix, toolSchemaFingerprint: "tools-66"
        ).prefixFingerprintSHA256
    )
}

/// v1Legacy is byte-identical: no relocation, no gate, the exact pre-change
/// system prompt.
@Test
func toolContract_v1LegacyLayoutIsByteIdenticalUnderEveryBinding() {
    let ctx = context([coreA, coreB, lazyA])
    let segments = SystemPromptSegments(stable: "PERSONA", dynamic: "RECALL")
    func layout() -> String {
        SwiftNativeTurnEngine.textToolCompatibilityLayout(
            baseSystem: segments.combined, segments: segments, context: ctx
        ).system
    }
    let unbound = layout()
    let v1 = ConversationPrefixShape.$override.withValue(.v1Legacy) { layout() }
    #expect(v1 == unbound)
    #expect(v1.contains("Also loaded this session:"))
    // And the no-segments fallback arm renders the same bytes it always did.
    #expect(
        ConversationPrefixShape.$override.withValue(.v1Legacy) {
            SwiftNativeTurnEngine.textToolCompatibilityLayout(
                baseSystem: "PERSONA", segments: nil, context: ctx
            ).system
        }
        == SwiftNativeTurnEngine.withTextToolCompatibilityInstructions("PERSONA", context: ctx)
    )
}

// MARK: - Usage-based unload

private func makeStore() -> (ActiveToolsStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tool-contract-\(UUID().uuidString)", isDirectory: true)
    return (ActiveToolsStore(dataRoot: root), root)
}

@Test
func activeTools_unusedToolIsDroppedAfterTwoIdleTurnsAndNeverMidTurn() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-idle-session"

    await store.beginTurn(sessionId: session)                       // turn 1
    _ = try await store.addLoaded(sessionId: session, names: [lazyA])
    #expect(await store.load(sessionId: session).activeTools.contains(lazyA))

    // Turn 2 and turn 3 pass without the tool being called.
    let turnTwo = await store.beginTurn(sessionId: session)
    #expect(turnTwo.activeTools.contains(lazyA))
    let turnThree = await store.beginTurn(sessionId: session)
    #expect(turnThree.activeTools.contains(lazyA))

    // MID-TURN reads must never drop: a contract that changes inside a turn is
    // exactly the prefix kill this design exists to stop.
    for _ in 0..<3 {
        #expect(await store.load(sessionId: session).activeTools.contains(lazyA))
    }

    // Turn 4 starts: two completed idle turns is the limit.
    let turnFour = await store.beginTurn(sessionId: session)
    #expect(!turnFour.activeTools.contains(lazyA))
    #expect(turnFour.lastDropped == [lazyA])
    #expect(turnFour.loadOrder.isEmpty)
}

@Test
func activeTools_callingAToolKeepsItLoaded() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-used-session"

    await store.beginTurn(sessionId: session)
    _ = try await store.addLoaded(sessionId: session, names: [lazyA, lazyB])
    for _ in 0..<5 {
        await store.beginTurn(sessionId: session)
        // lazyA is being CALLED every turn; lazyB never is.
        await store.markUsed(sessionId: session, names: [lazyA])
    }
    let state = await store.load(sessionId: session)
    #expect(state.activeTools.contains(lazyA))
    #expect(!state.activeTools.contains(lazyB))
}

@Test
func activeTools_dropsAreBatchedAtTurnStart() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-batch-session"

    await store.beginTurn(sessionId: session)
    _ = try await store.addLoaded(sessionId: session, names: [lazyA, lazyB, lazyC])
    await store.beginTurn(sessionId: session)
    await store.beginTurn(sessionId: session)
    let dropTurn = await store.beginTurn(sessionId: session)
    // All three expire together, in one turn-start batch — not one per turn,
    // which would rewrite the prefix three times instead of once.
    #expect(dropTurn.lastDropped == [lazyC, lazyB, lazyA].sorted())
    #expect(dropTurn.activeTools.isEmpty)
}

@Test
func activeTools_promotedPreloadJoinsTheLoadOrderAndRetiresWhenUnused() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-preload-session"

    await store.beginTurn(sessionId: session)
    _ = try await store.addLoaded(sessionId: session, names: [lazyA])
    // Turn start promotes a confident route prediction exactly as a tool_load
    // would: appended at the tail, never ahead of what is already there.
    let commit = await store.commitTurnStartContract(
        sessionId: session,
        promoting: [lazyB],
        catalog: [schema(lazyA), schema(lazyB)]
    )
    #expect(commit?.promoted == [lazyB])
    #expect(commit?.state.advertisedLoadOrder == [lazyA, lazyB])

    // The preload is never called. The same 2-idle-turn rule retires it.
    await store.beginTurn(sessionId: session)
    await store.markUsed(sessionId: session, names: [lazyA])
    await store.beginTurn(sessionId: session)
    await store.markUsed(sessionId: session, names: [lazyA])
    let dropTurn = await store.beginTurn(sessionId: session)
    #expect(dropTurn.lastDropped == [lazyB])
    #expect(dropTurn.advertisedLoadOrder == [lazyA])
}

@Test
func activeTools_promotionNeverEvictsAnExplicitLoad() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-headroom-session"

    // Fill the persisted budget with explicit loads.
    let explicit = Set((0..<ActiveToolsStore.maxPersistedTools).map { "explicit_tool_\($0)" })
    await store.beginTurn(sessionId: session)
    // A load carries its schemas, as tool_load does live: a row with no body
    // is released at the next contract commit by design, which is not the
    // eviction this pin is about.
    _ = try await store.addLoaded(
        sessionId: session,
        names: explicit,
        descriptors: Dictionary(uniqueKeysWithValues: explicit.map { ($0, PinnedToolSchema(schema($0))) })
    )
    #expect(await store.load(sessionId: session).activeTools == explicit)

    // A preload is a GUESS. With no headroom it is skipped entirely rather
    // than evicting something the model actually asked for — and the caller is
    // told, so the name stays discovery-only instead of being reported loaded.
    let commit = await store.commitTurnStartContract(
        sessionId: session,
        promoting: [lazyA],
        catalog: [schema(lazyA)]
    )
    #expect(commit?.promoted.isEmpty == true)
    let state = await store.load(sessionId: session)
    #expect(state.activeTools == explicit)
    #expect(!state.activeTools.contains(lazyA))
}

@Test
func activeTools_promotionSkipsAlwaysOnNames() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-floor-session"

    await store.beginTurn(sessionId: session)
    // A floor tool has no session row; promoting one would drop it into the
    // appended run and shift every row behind it.
    let commit = await store.commitTurnStartContract(
        sessionId: session,
        promoting: [coreA],
        catalog: [schema(coreA)]
    )
    #expect(commit?.promoted.isEmpty == true)
    #expect(await store.load(sessionId: session).advertisedLoadOrder.isEmpty)
}

@Test
func activeTools_loadOrderIsAppendOnlyAndSurvivesReload() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-order-session"

    await store.beginTurn(sessionId: session)
    _ = try await store.addLoaded(sessionId: session, names: [lazyB])
    _ = try await store.addLoaded(sessionId: session, names: [lazyA])
    #expect(await store.load(sessionId: session).advertisedLoadOrder == [lazyB, lazyA])

    // tool_unload still works sooner than the idle drop, and a re-load appends
    // at the tail rather than reclaiming the old slot.
    _ = try await store.removeLoaded(sessionId: session, names: [lazyB])
    _ = try await store.addLoaded(sessionId: session, names: [lazyB])
    #expect(await store.load(sessionId: session).advertisedLoadOrder == [lazyA, lazyB])
}

@Test
func activeTools_wallClockTTLNoLongerEmptiesALiveLoadout() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-stale-session"
    let dir = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // A loadout whose stamps are two days old. Under the previous rule the
    // very next read silently emptied it — session tool amnesia on a live
    // session that simply had a long gap. Decay is measured in TURNS now;
    // wall-clock survives only as the orphan sweep over abandoned FILES.
    let ancient = "2020-01-01T00:00:00.000Z"
    let body = """
    {"sessionId":"\(session)","activeTools":["\(lazyA)"],\
    "loadedAt":{"\(lazyA)":"\(ancient)"},"loadOrder":["\(lazyA)"],\
    "lastUsedTurn":{"\(lazyA)":3},"turnCount":3,"lastDropped":[],\
    "updatedAt":"\(ancient)"}
    """
    try body.write(
        to: dir.appendingPathComponent("\(session).json"),
        atomically: true,
        encoding: .utf8
    )

    let state = await store.load(sessionId: session)
    #expect(state.activeTools.contains(lazyA))
    #expect(state.advertisedLoadOrder == [lazyA])
}

// MARK: - Reviewer findings 2-5: the contract cannot move underneath a turn

@Test
func toolContract_unloadDoesNotShrinkTheAdvertisedRunMidTurn() {
    // A pinned lane advertises the TURN-START contract on every iteration.
    // Before this, iteration N+1 re-read the store, so tool_unload(A) in
    // iteration N shortened the catalog inside the cache-breakpointed stable
    // segment and killed the prefix for the rest of the turn.
    let catalog = [coreA, lazyA, lazyB, mcpName]
    let turnStart = contract(order: [mcpName, lazyA, lazyB], loaded: [lazyA, lazyB])

    let iterationOne = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: context(catalog), activeTools: [lazyA, lazyB], contract: turnStart
    )?.toolSchemas.map(\.name)
    // lazyA was unloaded mid-turn: the store no longer has its row, but the
    // pinned contract is what the lane advertises, so nothing moves.
    let iterationTwo = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: context(catalog), activeTools: [lazyA, lazyB], contract: turnStart
    )?.toolSchemas.map(\.name)
    #expect(iterationOne == [coreA, mcpName, lazyA, lazyB])
    #expect(iterationTwo == iterationOne)
}

@Test
func toolContract_mcpIsAdvertisedFromThePinnedSnapshotNotTheLiveCache() {
    // The MCP schema set is served from a detached-refresh disk cache, so a
    // live prefix rule let membership change between two turns that loaded
    // nothing. Only the snapshot is advertised.
    let arrived = "mcp__server__arrived_midsession"
    let catalog = [coreA, mcpName, arrived]
    let pinned = contract(order: [mcpName], loaded: [])

    let rows = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: context(catalog), activeTools: [], contract: pinned
    )?.toolSchemas.map(\.name)
    #expect(rows == [coreA, mcpName])
    #expect(rows?.contains(arrived) == false)

    // It joins at the next turn START, appended at the tail.
    let resnapshotted = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: context(catalog), activeTools: [], contract: contract(order: [mcpName, arrived], loaded: [])
    )?.toolSchemas.map(\.name)
    #expect(resnapshotted == [coreA, mcpName, arrived])
}

@Test
func toolContract_pinnedDescriptorSurvivesASchemaReadinessFlap() {
    // A loaded registry/custom tool whose readiness flaps vanished from the
    // catalog walk and therefore from the contract. The pin keeps the row.
    let registryTool = "custom_registry_tool"
    let pinnedBody = PinnedToolSchema(
        description: "pinned at load time",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
    let pinned = contract(
        order: [lazyA, registryTool],
        loaded: [lazyA, registryTool],
        pinned: [registryTool: pinnedBody]
    )
    // THIS turn's catalog walk no longer returns the registry tool at all.
    let flapped = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
        to: context([coreA, lazyA]),
        activeTools: [lazyA, registryTool],
        contract: pinned
    )
    #expect(flapped?.toolSchemas.map(\.name) == [coreA, lazyA, registryTool])
    // Re-materialized from the descriptor it was loaded with, not invented.
    #expect(flapped?.toolSchemas.last?.description == "pinned at load time")
}

@Test
func activeTools_mcpSnapshotRefreshesOnlyAtTurnStartAndCountsAsADrop() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-mcp-session"
    let mcpA = "mcp__srv__alpha"
    let mcpB = "mcp__srv__beta"

    await store.beginTurn(sessionId: session)
    let first = await store.commitTurnStartContract(
        sessionId: session,
        promoting: [],
        catalog: [schema(mcpA), schema(mcpB)]
    )
    #expect(first?.state.advertisedLoadOrder == [mcpA, mcpB])

    // Server B disappears from the cache. The next turn-start snapshot frees
    // its slot and reports it as a drop, batched with any idle drops.
    await store.beginTurn(sessionId: session)
    let second = await store.commitTurnStartContract(
        sessionId: session,
        promoting: [],
        catalog: [schema(mcpA)]
    )
    #expect(second?.state.advertisedLoadOrder == [mcpA])
    #expect(second?.state.lastDropped.contains(mcpB) == true)
    #expect(second?.state.pinnedSchemas[mcpB] == nil)
}

@Test
func activeTools_pinnedDescriptorIsCapturedAtLoadAndReleasedOnUnload() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-pin-session"

    await store.beginTurn(sessionId: session)
    _ = try await store.addLoaded(
        sessionId: session,
        names: [lazyA],
        descriptors: [lazyA: PinnedToolSchema(schema(lazyA))]
    )
    let loaded = await store.load(sessionId: session)
    #expect(loaded.pinnedSchemas[lazyA]?.description == "test tool \(lazyA)")
    // The pin survives a reload from disk — it is the contract's memory.
    #expect(loaded.toolContract.pinnedSchemas[lazyA] != nil)

    _ = try await store.removeLoaded(sessionId: session, names: [lazyA])
    #expect(await store.load(sessionId: session).pinnedSchemas[lazyA] == nil)
}

@Test
func activeTools_unloadAllKeepsPinnedMCPMembership() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "contract-unloadall-session"
    let mcpA = "mcp__srv__alpha"

    await store.beginTurn(sessionId: session)
    _ = await store.commitTurnStartContract(
        sessionId: session,
        promoting: [],
        catalog: [schema(mcpA), schema(lazyA)]
    )
    _ = try await store.addLoaded(sessionId: session, names: [lazyA])

    // tool_unload(all:) drops the session's LOADS. MCP membership is not a
    // load, and unadvertising the whole MCP surface is not what was asked.
    _ = try await store.removeLoaded(sessionId: session, names: [], all: true)
    let state = await store.load(sessionId: session)
    #expect(state.activeTools.isEmpty)
    #expect(state.advertisedLoadOrder == [mcpA])
}
