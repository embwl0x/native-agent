import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Mid-conversation tool changes, ORCHESTRATION layer (2026-09-02).
//
// The whole point of the lane is that the `tools` array — which sits FIRST in
// Anthropic's hashed prefix — stops moving. These tests pin that: the array is
// byte-identical across two turns with a `tool_load` between them, and the
// load shows up as an ADDITION BLOCK instead. The wire encoding of those
// blocks is pinned in ProviderRoutingTests/MidConversationToolChangesTests.
//
// Silent-failure class throughout: a plan that quietly re-churns the array
// still answers perfectly and pays full-price uncached input on every turn.

private func toolSchema(_ name: String) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "\(name) description",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
}

/// A catalog wide enough to have a floor, a loadable built-in run, and MCP.
private func catalogFixture() -> [LLMToolSchema] {
    [
        toolSchema("tool_catalog"),
        toolSchema("tool_load"),
        toolSchema("recall_memory"),
        toolSchema("time_now"),
        toolSchema("git_status"),
        toolSchema("grep"),
        toolSchema("write_file"),
        toolSchema("mcp__server__alpha"),
        toolSchema("mcp__server__beta"),
    ]
}

/// A session contract whose FROZEN DECLARATION is the whole catalog (what
/// `commitTurnStartContract` pins on the first turn) and whose `order`/`loaded`
/// are the moving, offered half.
private func contract(
    order: [String],
    loaded: Set<String>,
    declared: [String]? = nil
) -> SessionToolContract {
    var pinned: [String: PinnedToolSchema] = [:]
    for schema in catalogFixture() where order.contains(schema.name) {
        pinned[schema.name] = PinnedToolSchema(schema)
    }
    let declaredOrder = declared ?? catalogFixture().map(\.name)
    var declaredSchemas: [String: PinnedToolSchema] = [:]
    for schema in catalogFixture() where declaredOrder.contains(schema.name) {
        declaredSchemas[schema.name] = PinnedToolSchema(schema)
    }
    return SessionToolContract(
        order: order,
        loaded: loaded,
        pinnedSchemas: pinned,
        declaredOrder: declaredOrder,
        declaredSchemas: declaredSchemas,
        declarationGeneration: 1
    )
}

private func offeredFixture(_ names: [String]) -> [LLMToolSchema] {
    catalogFixture().filter { names.contains($0.name) }
}

/// The always-on floor names this catalog actually carries.
private var floorInCatalog: [String] {
    catalogFixture().map(\.name)
        .filter { SwiftToolDispatcher.alwaysOnCoreNames.contains($0) }
        .sorted()
}

private func plan(
    offered: [String],
    order: [String],
    loaded: Set<String>,
    declared: [String]? = nil,
    model: String = "claude-opus-5",
    providerId: String? = "anthropic"
) -> StructuredToolChangePlan? {
    SwiftNativeChatOrchestrationClient.makeToolChangePlan(
        offered: offeredFixture(offered),
        contract: contract(order: order, loaded: loaded, declared: declared),
        modelId: model,
        providerId: providerId
    )
}

@Suite struct MidConversationToolChangePlanTests {

    // MARK: - The array does not move

    /// THE LOAD-BEARING TEST. Turn N offers the floor plus one pinned MCP
    /// member; turn N+1 has loaded `git_status`. The array must be
    /// byte-identical — that is the entire cache win.
    @Test func arrayIsByteIdenticalAcrossTwoTurnsWithALoadBetweenThem() throws {
        let turnN = try #require(plan(
            offered: floorInCatalog + ["mcp__server__alpha"],
            order: ["mcp__server__alpha"],
            loaded: []
        ))
        let turnN1 = try #require(plan(
            offered: floorInCatalog + ["mcp__server__alpha", "git_status"],
            order: ["mcp__server__alpha", "git_status"],
            loaded: ["git_status"]
        ))
        #expect(turnN.array.map(\.name) == turnN1.array.map(\.name))
        #expect(turnN.array == turnN1.array)
        #expect(
            SwiftNativeTurnEngine.toolSchemaFingerprint(turnN.array)
                == SwiftNativeTurnEngine.toolSchemaFingerprint(turnN1.array)
        )
    }

    /// The array's ORDER must not depend on the session's load order — that is
    /// exactly the input that changes when a tool is loaded or drops out.
    @Test func arrayOrderIsFloorThenNameSortedAndLoadIndependent() throws {
        let a = try #require(plan(
            offered: floorInCatalog,
            order: ["mcp__server__alpha", "git_status", "grep"],
            loaded: ["git_status", "grep"]
        ))
        let b = try #require(plan(
            offered: floorInCatalog,
            order: ["grep", "git_status", "mcp__server__alpha"],
            loaded: ["grep", "git_status"]
        ))
        #expect(a.array.map(\.name) == b.array.map(\.name))
        let names = a.array.map(\.name)
        let floorCount = floorInCatalog.count
        #expect(Array(names.prefix(floorCount)) == floorInCatalog)
        // Non-floor run is the DECLARATION append order — a re-pin appends at
        // the tail instead of reshuffling every row ahead of it.
        let declaredNonFloor = catalogFixture().map(\.name)
            .filter { !SwiftToolDispatcher.alwaysOnCoreNames.contains($0) }
        #expect(Array(names.dropFirst(floorCount)) == declaredNonFloor)
    }

    /// Only the floor is offered by the array itself; everything else waits
    /// for an addition block.
    @Test func everyNonFloorToolIsDeferred() throws {
        let p = try #require(plan(
            offered: floorInCatalog + ["git_status"],
            order: ["mcp__server__alpha", "git_status"],
            loaded: ["git_status"]
        ))
        for schema in p.array {
            let isFloor = SwiftToolDispatcher.alwaysOnCoreNames.contains(schema.name)
            #expect(schema.deferLoading == !isFloor)
        }
    }

    /// THE POLICY-FLAP TEST. The declaration is pinned in the session
    /// contract and `makeToolChangePlan` cannot even see the live catalog, so
    /// a policy flip (Full Mac off, activity capture toggled, a registry tool
    /// unready, an MCP server gone from the detached cache) reaches it only as
    /// a SMALLER OFFERED SET. The array must not move one byte.
    /// The store-side half — the catalog itself shrinking without unpinning —
    /// is `SessionToolDeclarationPinTests.aShrunkCatalogNeitherUnpinsNorRepins`.
    @Test func aShrunkCatalogCannotMoveTheDeclaredArray() throws {
        let full = try #require(plan(
            offered: floorInCatalog + ["git_status", "write_file"],
            order: ["git_status", "write_file"],
            loaded: ["git_status", "write_file"]
        ))
        // Full Mac off: the live catalog no longer serves the file surface,
        // and the lazy filter stops offering it. The DECLARATION is unchanged.
        let flapped = try #require(plan(
            offered: floorInCatalog,
            order: ["git_status", "write_file"],
            loaded: ["git_status", "write_file"]
        ))
        #expect(full.array == flapped.array)
        #expect(
            SwiftNativeTurnEngine.toolSchemaFingerprint(full.array)
                == SwiftNativeTurnEngine.toolSchemaFingerprint(flapped.array)
        )
        #expect(full.additions.contains("write_file"))
        #expect(!flapped.additions.contains("write_file"))
    }

    /// A declaration that grows is an EXPLICIT re-pin, and the only legitimate
    /// reason the array moved — reported through `declarationGeneration`.
    @Test func aNewlyDeclaredBuiltInIsAnAttributableArrayChange() throws {
        let before = try #require(plan(
            offered: floorInCatalog,
            order: [],
            loaded: [],
            declared: catalogFixture().map(\.name).filter { $0 != "write_file" }
        ))
        let after = try #require(plan(
            offered: floorInCatalog,
            order: [],
            loaded: []
        ))
        #expect(!before.array.map(\.name).contains("write_file"))
        #expect(after.array.map(\.name).contains("write_file"))
        // Appends at the TAIL of the non-floor run rather than reshuffling.
        #expect(after.array.map(\.name).dropLast() == before.array.map(\.name)[...])
        #expect(before.declarationGeneration == after.declarationGeneration)
    }

    // MARK: - The delta moves instead

    @Test func additionBlocksReflectTheLoad() throws {
        let before = try #require(plan(
            offered: floorInCatalog + ["mcp__server__alpha"],
            order: ["mcp__server__alpha"],
            loaded: []
        ))
        let after = try #require(plan(
            offered: floorInCatalog + ["mcp__server__alpha", "git_status"],
            order: ["mcp__server__alpha", "git_status"],
            loaded: ["git_status"]
        ))
        #expect(before.additions == ["mcp__server__alpha"])
        #expect(after.additions == ["git_status", "mcp__server__alpha"])
        #expect(before.removals.isEmpty)
        #expect(after.removals.isEmpty)
    }

    /// The delta is re-declared in FULL every turn (no ledger): history is
    /// rebuilt from the transcript, so an addition declared last turn is gone.
    @Test func everyOfferedNonFloorToolIsReDeclaredEveryTurn() throws {
        let p = try #require(plan(
            offered: floorInCatalog + ["mcp__server__alpha", "git_status", "grep"],
            order: ["mcp__server__alpha", "git_status", "grep"],
            loaded: ["git_status", "grep"]
        ))
        #expect(Set(p.additions) == ["mcp__server__alpha", "git_status", "grep"])
    }

    /// A floor tool withdrawn by policy this turn is the ONLY thing that needs
    /// a removal block — a deferred tool is withdrawn by omission.
    @Test func removalReflectsAPolicyWithdrawnFloorTool() throws {
        let withdrawn = floorInCatalog.first!
        let p = try #require(plan(
            offered: floorInCatalog.filter { $0 != withdrawn } + ["git_status"],
            order: ["git_status"],
            loaded: ["git_status"]
        ))
        #expect(p.removals == [withdrawn])
        #expect(!p.additions.contains(withdrawn))
        // The withdrawn tool is still DECLARED — a removal block that names an
        // undeclared tool is a 400.
        #expect(p.array.map(\.name).contains(withdrawn))
    }

    // MARK: - Validation

    /// Referencing a name that is not declared in `tools` is a 400. An offered
    /// name the array does not carry is dropped from the addition list, with a
    /// receipt, and never sent.
    @Test func unknownOfferedNameIsDroppedWithAReceiptAndNeverSent() throws {
        // A tool the advertising boundary offered that the session never
        // declared — e.g. an MCP server that arrived after the declaration pin.
        let stray = toolSchema("mcp__ghost__tool")
        let p = try #require(SwiftNativeChatOrchestrationClient.makeToolChangePlan(
            offered: offeredFixture(floorInCatalog + ["git_status"]) + [stray],
            contract: contract(order: ["git_status"], loaded: ["git_status"]),
            modelId: "claude-opus-5",
            providerId: "anthropic"
        ))
        #expect(p.droppedUnknown == ["mcp__ghost__tool"])
        #expect(!p.additions.contains("mcp__ghost__tool"))
        #expect(!p.offered.contains("mcp__ghost__tool"))
        #expect(!p.array.map(\.name).contains("mcp__ghost__tool"))
        // And the block builder cannot resurrect it: the provider-name map is
        // built from the ARRAY, so an undeclared name has no alias at all.
        let map = ProviderToolNameMap(p.array)
        #expect(map.providerName(forInternalName: "mcp__ghost__tool") == nil)
        #expect(map.providerName(forInternalName: "git_status") != nil)
    }

    // MARK: - Gates (everything else keeps today's shape byte for byte)

    @Test func planIsNilOffTheAnthropicAPIKeyStructuredLane() {
        for provider in ["anthropic_oauth_direct", "kimi-code", "openai", "codex", nil] {
            #expect(plan(
                offered: floorInCatalog + ["git_status"],
                order: ["git_status"],
                loaded: ["git_status"],
                providerId: provider
            ) == nil)
        }
    }

    @Test func planIsNilOnAModelWithoutTheCapability() {
        for model in ["claude-sonnet-5", "claude-opus-4-7", "not-a-model"] {
            #expect(plan(
                offered: floorInCatalog + ["git_status"],
                order: ["git_status"],
                loaded: ["git_status"],
                model: model
            ) == nil)
        }
    }

    @Test func planIsNilWithoutAFrozenDeclaration() {
        #expect(SwiftNativeChatOrchestrationClient.makeToolChangePlan(
            offered: offeredFixture(floorInCatalog),
            contract: nil,
            modelId: "claude-opus-5",
            providerId: "anthropic"
        ) == nil)
        // A contract that exists but has never been pinned falls back too —
        // never to an array derived from live, policy-gated catalog state.
        #expect(SwiftNativeChatOrchestrationClient.makeToolChangePlan(
            offered: offeredFixture(floorInCatalog),
            contract: SessionToolContract(order: [], loaded: [], pinnedSchemas: [:]),
            modelId: "claude-opus-5",
            providerId: "anthropic"
        ) == nil)
    }

    /// HIGH-severity regression guard. A floor-only turn has an EMPTY delta,
    /// but it must still produce a plan — otherwise that turn ships the
    /// lazy-filtered array and the next one ships the full deferred
    /// declaration, which is the array moving. The delta being empty shows up
    /// as a nil MESSAGE (and therefore no beta header), not a nil plan.
    @Test func floorOnlyTurnStillShipsTheSameArray() throws {
        let floorOnly = try #require(plan(offered: floorInCatalog, order: [], loaded: []))
        let withLoad = try #require(plan(
            offered: floorInCatalog + ["git_status"],
            order: ["git_status"],
            loaded: ["git_status"]
        ))
        #expect(floorOnly.array == withLoad.array)
        #expect(floorOnly.additions.isEmpty)
        #expect(floorOnly.removals.isEmpty)
        #expect(ConversationPrefixSeeding.toolChangeMessage(
            additions: floorOnly.additions, removals: floorOnly.removals
        ) == nil)
    }
}

// MARK: - Message assembly and placement

@Suite struct MidConversationToolChangeMessageTests {

    @Test func emptyDeltaProducesNoMessage() {
        #expect(ConversationPrefixSeeding.toolChangeMessage(
            additions: [], removals: []
        ) == nil)
    }

    @Test func messageIsSystemRolePlainAndNeverTurnScoped() throws {
        let message = try #require(ConversationPrefixSeeding.toolChangeMessage(
            additions: ["git_status"], removals: ["time_now"]
        ))
        #expect(message.role == .system)
        #expect(!message.turnScopedClearAtNextUserMessage)
        #expect(message.content.isEmpty)
        #expect(message.toolChanges == [
            .addition("git_status"),
            .removal("time_now"),
        ])
    }

    /// PLACEMENT: after the current user message, before the turn-scoped
    /// volatile block. A turn-scoped message is text-only and must END the
    /// array to render; consecutive system messages are judged as one group.
    @Test func seedPlacesToolChangesBeforeTheTurnScopedVolatileBlock() throws {
        let history: [LLMMessage] = [
            .user("earlier question"),
            .assistantText("earlier answer"),
        ]
        let segments = SystemPromptSegments(
            stable: "PERSONA stable bytes", dynamic: "volatile per-turn bytes"
        )
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "claude-fable-5-1",
            reasoningEffort: "medium",
            providerId: "anthropic",
            toolsAvailable: [],
            systemPrompt: segments.combined,
            userMessage: "the current question",
            systemSegments: segments,
            historyMessages: history
        )
        let changes = try #require(ConversationPrefixSeeding.toolChangeMessage(
            additions: ["git_status"], removals: []
        ))
        let seed = ConversationPrefixSeeding.seed(
            ctx, shape: .v2Prefix, toolChanges: changes
        )
        #expect(seed.shape == .v2Prefix)
        #expect(seed.delivery == .systemClearAt)
        let roles = seed.messages.map(\.role)
        #expect(roles.suffix(3) == [.user, .system, .system])
        // Tool changes first…
        let toolChangeIndex = seed.messages.count - 2
        #expect(!seed.messages[toolChangeIndex].toolChanges.isEmpty)
        #expect(!seed.messages[toolChangeIndex].turnScopedClearAtNextUserMessage)
        // …turn-scoped volatile block LAST, and still text-only.
        let volatileIndex = try #require(seed.volatileIndex)
        #expect(volatileIndex == seed.messages.count - 1)
        #expect(seed.messages[volatileIndex].turnScopedClearAtNextUserMessage)
        #expect(seed.messages[volatileIndex].toolChanges.isEmpty)
        // The current user message is still inside the replayable prefix
        // boundary calculation, i.e. the tool-change message did not displace it.
        #expect(seed.messages[seed.currentUserIndex].role == .user)
        #expect(seed.currentUserIndex == toolChangeIndex - 1)
    }

    /// V1 BYTE IDENTITY: with no plan (every text-compat turn, every
    /// non-Anthropic provider), the seeded array is exactly what it was.
    @Test func v1LegacyWithoutToolChangesIsUnchanged() {
        let segments = SystemPromptSegments(stable: "S", dynamic: "D")
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "claude-opus-5",
            reasoningEffort: "medium",
            providerId: "anthropic",
            toolsAvailable: [],
            systemPrompt: segments.combined,
            userMessage: "hello",
            systemSegments: segments,
            historyMessages: []
        )
        let seed = ConversationPrefixSeeding.seed(ctx, shape: .v2Prefix)
        #expect(seed.shape == .v1Legacy)
        #expect(seed.messages.count == 1)
        #expect(seed.messages[0].role == .user)
        #expect(seed.delivery == .none)
        #expect(seed.volatileIndex == nil)
    }

    /// A plan turn with no replayed history still falls back to the v1 message
    /// array — but the additions MUST survive, or the array's `defer_loading`
    /// leaves the model holding the floor alone.
    @Test func v1LegacyArmStillCarriesTheToolChangeMessage() throws {
        let segments = SystemPromptSegments(stable: "S", dynamic: "D")
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "claude-opus-5",
            reasoningEffort: "medium",
            providerId: "anthropic",
            toolsAvailable: [],
            systemPrompt: segments.combined,
            userMessage: "hello",
            systemSegments: segments,
            historyMessages: []
        )
        let changes = try #require(ConversationPrefixSeeding.toolChangeMessage(
            additions: ["git_status"], removals: []
        ))
        let seed = ConversationPrefixSeeding.seed(
            ctx, shape: .v2Prefix, toolChanges: changes
        )
        #expect(seed.shape == .v1Legacy)
        #expect(seed.messages.map(\.role) == [.user, .system])
        #expect(seed.messages[1].toolChanges == [.addition("git_status")])
    }
}

// MARK: - Telemetry receipts

@Suite struct MidConversationToolChangeTelemetryTests {

    /// The prefix fingerprint on a plan lane hashes the ARRAY, so it stays put
    /// across a load — while the offered set, which is supposed to move, does
    /// not feed it.
    @Test func arrayFingerprintSurvivesALoadThatMovesTheOfferedSet() throws {
        let before = try #require(plan(
            offered: floorInCatalog,
            order: [],
            loaded: []
        ))
        let after = try #require(plan(
            offered: floorInCatalog + ["mcp__server__alpha", "grep"],
            order: ["mcp__server__alpha", "grep"],
            loaded: ["grep"]
        ))
        let beforeFingerprint = SwiftNativeTurnEngine.toolSchemaFingerprint(before.array)
        let afterFingerprint = SwiftNativeTurnEngine.toolSchemaFingerprint(after.array)
        #expect(beforeFingerprint == afterFingerprint)
        #expect(before.additions != after.additions)
    }

    @Test func receiptsCountTheArrayTheOfferedSetAndBothDeltas() throws {
        let withdrawn = floorInCatalog.first!
        let p = try #require(plan(
            offered: floorInCatalog.filter { $0 != withdrawn } + ["grep"],
            order: ["grep"],
            loaded: ["grep"]
        ))
        let receipts = ConversationPrefixTelemetrySnapshot.ToolChangeReceipts(
            arrayFingerprintSHA256: SwiftNativeTurnEngine.toolSchemaFingerprint(p.array),
            offeredCount: p.offered.count,
            additionCount: p.additions.count,
            removalCount: p.removals.count,
            droppedUnknownCount: p.droppedUnknown.count,
            declarationGeneration: p.declarationGeneration
        )
        let payload = receipts.payload
        #expect(payload["tools.additionCount"] == .int(1))
        #expect(payload["tools.removalCount"] == .int(1))
        #expect(payload["tools.droppedUnknownCount"] == .int(0))
        #expect(payload["tools.declarationGeneration"] == .int(1))
        #expect(payload["tools.offeredCount"] == .int(Int64(p.offered.count)))
        // Digest only — never a tool name, never a schema byte.
        guard case .string(let digest)? = payload["tools.arrayFingerprintSHA256"] else {
            Issue.record("array fingerprint missing")
            return
        }
        #expect(digest.count == 64)
    }

    /// Absent on every lane that runs no plan, so those rows decode exactly as
    /// before.
    @Test func receiptsAreAbsentWithoutAPlan() {
        let snapshot = ConversationPrefixTelemetrySnapshot(
            shapeVersion: "v2Prefix",
            prefixFingerprintSHA256: "abc",
            historyMessageCount: 2,
            historyMessageChars: 10,
            volatileBlockChars: 5,
            volatileDelivery: "systemClearAt",
            windowCursorAdvanceCount: 0,
            windowSlid: false
        )
        #expect(snapshot.toolChanges == nil)
        #expect(snapshot.payload["tools.arrayFingerprintSHA256"] == nil)
        #expect(snapshot.payload["tools.additionCount"] == nil)
    }
}

// MARK: - Dispatch authorization: offered != declared

/// Scripted-routing stub for the dispatch harness below.
private final class ToolChangeStubRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider {
        throw ProviderRoutingError.providerNotFound
    }
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

/// Never called by these tests — `dispatchIterationCalls` is exercised
/// directly — but the engine requires an LLM to construct.
private final class ToolChangeStubLLM: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String { "" }
}

private func toolChangeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolchange-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct MidConversationToolChangeDispatchAuthorizationTests {

    /// HIGH-severity regression guard. On this lane the provider `tools` array
    /// DECLARES the whole session catalog, so `ProviderToolNameMap` — which
    /// exists to translate wire aliases — resolves names the model was never
    /// offered. A `tool_use` for one of those must never reach a dispatch.
    @Test func aDeclaredButNotOfferedToolIsRefusedNotDispatched() async throws {
        let dir = try toolChangeTempDir("not-offered")
        let persona = hermeticPersona(root: dir)
        let tools = MockToolDispatchClient(scripted: [
            "recall_memory": .string("ok"),
            "write_file": .string("wrote"),
        ])
        let engine = SwiftNativeTurnEngine(
            persona: persona,
            memory: nil,
            router: ToolChangeStubRouting(),
            trust: hermeticTrust(),
            llm: ToolChangeStubLLM(),
            tools: tools
        )
        // The map is built from the ARRAY, so both names resolve…
        let map = ProviderToolNameMap([toolSchema("recall_memory"), toolSchema("write_file")])
        // …but only one of them is OFFERED this turn.
        let (blocks, records) = await engine.dispatchIterationCalls(
            providerCalls: [
                ParsedToolCall(id: "t1", name: "recall_memory", input: [:]),
                ParsedToolCall(id: "t2", name: "write_file", input: [:]),
            ],
            pairedIds: ["t1", "t2"],
            providerTools: map,
            modelId: "test-model",
            surface: "chat",
            sessionId: nil,
            tools: tools,
            progress: nil,
            offeredToolNames: ["recall_memory"]
        )
        // NEVER a dispatch for the un-offered name.
        #expect(tools.dispatches.map(\.tool) == ["recall_memory"])
        // Still PAIRED on the wire: one tool_result per tool_use, in order.
        #expect(records.map(\.name) == ["recall_memory", "write_file"])
        #expect(blocks.count == 2)
        guard case .toolResult(let id0, _, let err0) = blocks[0],
              case .toolResult(let id1, let content1, let err1) = blocks[1] else {
            Issue.record("expected two tool_result blocks")
            return
        }
        #expect(id0 == "t1")
        #expect(!err0)
        #expect(id1 == "t2")
        #expect(err1)
        #expect(content1.contains("not currently offered"))
        #expect(content1.contains("tool_load"))
    }

    /// nil means "no narrowing" — every other lane keeps today's behavior.
    @Test func nilOfferedSetLeavesDispatchUnchanged() async throws {
        let dir = try toolChangeTempDir("no-narrowing")
        let persona = hermeticPersona(root: dir)
        let tools = MockToolDispatchClient(scripted: ["write_file": .string("wrote")])
        let engine = SwiftNativeTurnEngine(
            persona: persona,
            memory: nil,
            router: ToolChangeStubRouting(),
            trust: hermeticTrust(),
            llm: ToolChangeStubLLM(),
            tools: tools
        )
        let (blocks, records) = await engine.dispatchIterationCalls(
            providerCalls: [ParsedToolCall(id: "t1", name: "write_file", input: [:])],
            pairedIds: ["t1"],
            providerTools: ProviderToolNameMap([toolSchema("write_file")]),
            modelId: "test-model",
            surface: "chat",
            sessionId: nil,
            tools: tools,
            progress: nil
        )
        #expect(tools.dispatches.map(\.tool) == ["write_file"])
        #expect(records.count == 1)
        #expect(blocks.count == 1)
    }

    /// The refusal is shaped like a dispatch error so the loop, the
    /// no-progress guard and the transcript treat it as one.
    @Test func refusalResultIsAnOrdinaryErrorObject() {
        let result = SwiftNativeTurnEngine.notOfferedToolResult("write_file")
        guard case .object(let fields) = result else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["not_offered"] == .bool(true))
        guard case .string(let message)? = fields["error"] else {
            Issue.record("expected an error string")
            return
        }
        #expect(message.contains("write_file"))
    }
}

// MARK: - The declaration is pinned in the session contract

@Suite struct SessionToolDeclarationPinTests {

    private func store() throws -> (ActiveToolsStore, String) {
        let root = try toolChangeTempDir("declaration")
        return (ActiveToolsStore(dataRoot: root), UUID().uuidString)
    }

    /// FIRST DECLARATION pins every model-visible name with its descriptor.
    @Test func firstTurnPinsTheWholeModelVisibleCatalog() async throws {
        let (store, session) = try store()
        let commit = try #require(await store.commitTurnStartContract(
            sessionId: session, promoting: [], catalog: catalogFixture()
        ))
        #expect(commit.declarationRepinned)
        let contract = commit.state.toolContract
        #expect(Set(contract.declaredOrder) == Set(catalogFixture().map(\.name)))
        #expect(contract.declarationGeneration == 1)
        for name in contract.declaredOrder {
            #expect(contract.declaredSchemas[name] != nil)
        }
    }

    /// A CATALOG FLAP — Full Mac off, a registry tool unready, an MCP server
    /// gone — must not remove a declared name or bump the generation.
    @Test func aShrunkCatalogNeitherUnpinsNorRepins() async throws {
        let (store, session) = try store()
        _ = await store.commitTurnStartContract(
            sessionId: session, promoting: [], catalog: catalogFixture()
        )
        let shrunk = catalogFixture().filter {
            !["write_file", "git_status", "mcp__server__beta"].contains($0.name)
        }
        let second = try #require(await store.commitTurnStartContract(
            sessionId: session, promoting: [], catalog: shrunk
        ))
        #expect(!second.declarationRepinned)
        let contract = second.state.toolContract
        #expect(Set(contract.declaredOrder) == Set(catalogFixture().map(\.name)))
        #expect(contract.declarationGeneration == 1)
        // The pinned descriptor survives, so the array still declares a body.
        #expect(contract.declaredSchemas["write_file"] != nil)
        #expect(contract.declaredToolSchemas.count == catalogFixture().count)
    }

    /// A GENUINELY NEW built-in is an explicit re-pin: it appends at the tail
    /// and bumps the generation, so the array change is attributable.
    @Test func aNewCatalogNameAppendsAndBumpsTheGeneration() async throws {
        let (store, session) = try store()
        _ = await store.commitTurnStartContract(
            sessionId: session, promoting: [], catalog: catalogFixture()
        )
        let grown = catalogFixture() + [toolSchema("swift_build")]
        let second = try #require(await store.commitTurnStartContract(
            sessionId: session, promoting: [], catalog: grown
        ))
        #expect(second.declarationRepinned)
        let contract = second.state.toolContract
        #expect(contract.declaredOrder.last == "swift_build")
        #expect(contract.declarationGeneration == 2)
    }

    /// An idle drop retires what is OFFERED, never what is DECLARED.
    @Test func anIdleDropLeavesTheDeclarationAlone() async throws {
        let (store, session) = try store()
        _ = await store.commitTurnStartContract(
            sessionId: session, promoting: ["git_status"], catalog: catalogFixture()
        )
        for _ in 0..<5 { _ = await store.beginTurn(sessionId: session) }
        let after = await store.load(sessionId: session)
        #expect(!after.activeTools.contains("git_status"))
        #expect(after.toolContract.declaredOrder.contains("git_status"))
        #expect(after.toolContract.declaredSchemas["git_status"] != nil)
    }
}
