import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle
import Context
import CognitiveSubstrate

/// Maps a persona SLOT id (ContextFlow/PersonaEngine vocabulary: "canonical"
/// or a custom persona subdirectory name) to the persona filter MemoryV2
/// understands (RECORD persona ids — agent names like
/// `MemoryV2Defaults.personaID`). Every ChatOrchestration site that feeds a
/// slot id into a MemoryV2 persona filter MUST route through this helper.
///
/// PRODUCT POLICY (User approved, 2026-07-24): **a persona slot id is
/// PRESENTATION-ONLY.** Every slot — resident *and* custom — reads the ONE
/// shared memory store, unfiltered. This function therefore always answers
/// "no persona filter". That is a deliberate, named mapping, not a value that
/// happens to match nothing. The reasoning, so nobody "restores" the old
/// behavior later:
///
///   * The live store's `personaId` vocabulary is ONLY configured agent names
///     (36 active rows) and "NativeAgent" (85 active). VERIFIED 2026-07-24. No
///     production writer ever stamps a persona SLOT id into `personaId`.
///   * So passing a custom slot id through was never isolation — it was an
///     id-vocabulary mismatch wearing isolation's clothes. A custom persona's
///     "own scope" is UNMINTABLE: no writer can put a record in it. It
///     protected an empty set forever while costing the entire memory feature
///     (zero context atoms AND zero recall hits) for every custom persona.
///   * NativeAgent is deliberately ONE agent (User, 2026-07-24) that may spawn
///     subagents but is NOT a multi-agent system. Persona docs change how she
///     SOUNDS, not who she IS; memory is the continuity. Sharding memory per
///     persona mask would be a quiet step toward a fleet and contradicts the
///     northstar's "one mind, no theater".
///   * If genuine compartmentalization is ever wanted (say a demo persona that
///     must not see personal memories), its home is the per-record DISCLOSURE
///     layer — `MemoryRecordDisclosurePolicy.classify(_:)` /
///     `.permits(surface:personaID:)`, already surface- and persona-aware —
///     NOT a storage-level persona filter. Add the rule there; do not
///     reintroduce a slot-id filter here.
func memoryRecallPersonaFilter(_ slotID: String?) -> String? {
    guard let slotID, slotID != ContextPersonaID.resident.rawValue else {
        // No slot in play, or the resident default slot: unfiltered.
        return nil
    }
    // CUSTOM PERSONA SLOT (a persona subdirectory name). Also unfiltered, by
    // the policy above: the mask changes the voice, not the memory store.
    return nil
}

// MARK: - Swift-native turn context engine
//
// This module wires together the Swift pieces needed to assemble a turn:
//   - PersonaEngine.listPersonaDocs()           — persona doc surface
//   - SwiftNativeMemoryRecaller.recall()        — embedding-backed recall
//   - ProviderRouting.checkedRoutingSnapshot()  — one per-turn route admission
//   - TrustCenter.autonomyForTool()             — autonomy resolution
//   - LLMClient                                 — the LLM call boundary
//   - ToolDispatchClient                        — the tool dispatch boundary
//
// This file owns the one-call context assembly primitive. Production chat is
// layered on top of it by Swift-native orchestration code: session history is
// threaded before context assembly, provider adapters can stream, and the
// tool-loop layer can dispatch model tool calls and feed compact results back
// into subsequent LLM calls.
//
// CARVES (intentional, documented):
//   * `executeTurn` remains a one-call primitive for tests and simple callers.
//     Multi-iteration tool use lives in ChatOrchestration+ToolLoop.swift and
//     ChatOrchestrationClient, not inside this primitive.
//   * Streaming lives in the native ChatOrchestrationClient/streaming facade.
//   * Session history threading lives in ChatOrchestration+SessionHistory.swift.
//   * Dispatch-time allow/approval/deny gating lives in AutonomyGate and the
//     app/core dispatch wrappers. This context builder records policy inputs;
//     it does not execute tools itself.
//   * Persona compilation here is intentionally compact. Surface-specific
//     persona/runtime assembly belongs to the production chat client path.
//
// Do not infer from this one-call primitive that NativeAgent lacks tool loops,
// streaming, or history threading. Those are live Swift-native layers around
// this context engine.

// MARK: - TurnEngineError

public enum TurnEngineError: Error, LocalizedError {
    case personaLoadFailed(underlying: Error)
    case emptyMessage
    /// A provider stream failed mid-turn. `partial` carries the visible prose the
    /// user already watched render so the orchestration layer can persist it
    /// instead of silently dropping it (audit #5, 2026-06-14).
    case streamInterrupted(partial: String, underlying: Error)
    /// 2026-07-21 audit fix: a USER STOP mid-stream. Same partial-carry as
    /// streamInterrupted but the orchestration layer persists it with
    /// cancelled:true and rethrows CancellationError (cancel is not a
    /// failure); previously the structured lanes discarded the visible
    /// partial entirely on cancel while text-compat persisted it.
    case streamCancelled(partial: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .personaLoadFailed(let e): return "persona load failed: \(e)"
        case .emptyMessage: return "userMessage was empty or whitespace-only"
        case .streamInterrupted(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        case .streamCancelled(_, let underlying):
            return (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        }
    }
}

// MARK: - MemoryRecalling

public protocol MemoryRecalling: Sendable {
    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit]
    func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit]
    /// Bump use_count/last_used_at for memory records served into a turn by
    /// Fluid Context (task #42). On active ContextFlow turns the legacy recall
    /// lane — whose recordRecallHits call is the only other access-bump path —
    /// is skipped entirely, so packet-served memories otherwise read as
    /// "unused" to hygiene/eviction, starving exactly the hot rows. Must be a
    /// protocol REQUIREMENT (not extension-only) so existential dispatch
    /// reaches the production adapter (same trap as `matchesTombstone`).
    /// Non-throwing: implementations log failures; a dropped bump self-heals
    /// on any later serve.
    func recordServedContextHits(ids: [String]) async
}

public extension MemoryRecalling {
    /// Backward-compatible default for legacy/test recallers that do not own
    /// disclosure metadata. Production MemoryV2 adapters override this method
    /// so failover recall uses the same persona/surface policy as Fluid Context
    /// projection and the explicit `recall_memory` tool.
    func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        try await recall(query, k: k)
    }

    /// Default no-op: legacy recallers and test fixtures track no access
    /// signals. The production V2 adapter overrides this with a real bump.
    func recordServedContextHits(ids: [String]) async {}
}

extension SwiftNativeMemoryRecaller: MemoryRecalling {}

// MARK: - MemoryPromoting
//
// After-turn hook for adaptive memory promotion. The real implementation
// (AdaptiveMemoryPromoter — sister worker m5) inspects the user/assistant
// pair and may stage a promotion proposal. Until m5 lands, the protocol is
// here so the chat path can call into a no-op default and the seam is
// already wired. Optional on SwiftNativeChatOrchestrationClient — nil ⇒
// skip the call entirely.
public protocol MemoryPromoting: Sendable {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async
}

public struct SharedAdaptiveMemoryPromoter: MemoryPromoting {
    public init() {}

    public func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        await AdaptiveMemoryPromoter.shared.observeTurn(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId
        )
    }
}

// MARK: - ToolDispatchClient

public protocol ToolDispatchClient: Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue
    func listAvailableTools() async throws -> [String]
    /// Tool-schema variant. Returns full JSON-Schema descriptors for the same
    /// tools `listAvailableTools()` exposes by name. Threaded through the
    /// LLMClient so the model can emit tool calls. Default implementation
    /// returns `[]` so dispatchers that only know names compile unchanged
    /// (the LLM then sees no tools — pre-tools behavior).
    func listAvailableToolSchemas() async throws -> [LLMToolSchema]
}

extension ToolDispatchClient {
    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

struct TurnContextSnapshot: Sendable {
    let providerPreferences: [String: SurfacePreference]
    let activeProviders: [String: String]
    let toolNames: [String]
    let toolSchemas: [LLMToolSchema]

    var toolSchemaParameterBytes: Int {
        toolSchemas.reduce(0) { $0 + $1.parametersJSON.count }
    }
}

/// One immutable provider-routing generation admitted before a chat facade
/// chooses its execution branch. This is execution context only; the
/// ProviderRouting store remains the sole authority and adapters still use a
/// checked reread to detect corrupt/revoked authority.
struct TurnRouteAdmission: Sendable, Equatable {
    let routingSurface: String
    let modelId: String
    let reasoningEffort: String
    let providerId: String?
    let serviceTier: String?
}

// MARK: - MockToolDispatchClient

/// Scripted-response mock. Tracks every dispatch behind an NSLock so it can be
/// shared across async tasks. Returns `.null` for any tool name not in the
/// scripted map. `listAvailableTools` returns the script keys in sorted order.
public final class MockToolDispatchClient: ToolDispatchClient, @unchecked Sendable {
    public struct Dispatch: Sendable, Equatable {
        public let tool: String
        public let input: [String: JSONValue]
        public let surface: String
    }

    private let scripted: [String: JSONValue]
    private let lock = NSLock()
    private var _dispatches: [Dispatch] = []

    public init(scripted: [String: JSONValue] = [:]) {
        self.scripted = scripted
    }

    public var dispatches: [Dispatch] {
        lock.lock(); defer { lock.unlock() }
        return _dispatches
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        recordDispatch(Dispatch(tool: tool, input: input, surface: surface))
        return scripted[tool] ?? .null
    }

    private func recordDispatch(_ d: Dispatch) {
        lock.lock(); defer { lock.unlock() }
        _dispatches.append(d)
    }

    public func listAvailableTools() async throws -> [String] {
        return scripted.keys.sorted()
    }
}

// MARK: - TurnContext

/// The fully-assembled context handed to the LLM for one turn.
public struct TurnContext: Sendable {
    public let surface: String
    /// Exact persona selected for this turn. This follows the turn into tool
    /// dispatch so explicit memory recall uses the same disclosure boundary
    /// as automatic Fluid Context projection.
    public let personaID: String?
    public let personaDocs: [String: String]
    public let recalled: [MemoryRecallHit]
    public let modelId: String
    public let reasoningEffort: String
    /// Immutable route admitted from one checked provider-routing snapshot.
    /// Adapters still reread canonical routing for corruption/revocation, but
    /// a valid mid-turn preference change cannot splice generations.
    public let providerId: String?
    public let serviceTier: String?
    public let toolsAvailable: [String]
    /// JSON-Schema descriptors for the same tools `toolsAvailable` lists by
    /// name. Threaded into `LLMClient.complete(...tools:)` so the model can
    /// emit tool calls. Empty when the dispatcher only knows names — the
    /// pre-W1 wire path (no tools embedded in the request body).
    public let toolSchemas: [LLMToolSchema]
    public let systemPrompt: String?
    public let userMessage: String
    /// U1 step 2b/3b (2026-06-10) — ADDITIVE stable/dynamic split of
    /// `systemPrompt` for provider prompt caching. When present:
    ///   INVARIANT: systemPrompt == systemSegments.combined
    ///              (== stable + "\n\n" + dynamic, empty segments collapse
    ///               the separator)
    /// `systemPrompt` stays the canonical model-visible content — every
    /// existing consumer keeps reading it unchanged. The segments are a
    /// layout hint the Anthropic adapters use to place the sys
    /// cache_control breakpoint at the end of the STABLE mass
    /// (persona + pins + the current lazy tool contract) instead of the end
    /// of the churning combined string.
    /// nil → legacy behavior everywhere.
    public let systemSegments: SystemPromptSegments?
    /// Per-turn DYNAMIC image content blocks for the CURRENT user message.
    /// CACHE INVARIANT: image blocks live ONLY on the in-flight user message —
    /// they MUST NEVER enter `systemPrompt`/`systemSegments` (would churn the
    /// cached prefix every turn) and MUST NOT be persisted/re-sent on later
    /// turns. Default `[]` keeps every existing TurnContext construction site
    /// byte-identical to pre-multimodal behavior.
    public let imageBlocks: [LLMContentBlock]
    /// Pins one immutable ContextFlow generation through the complete
    /// provider/tool loop. nil keeps the legacy/off path unchanged.
    public let fluidContextTurn: ContextPreparedTurn?
    /// The memory record identities behind THIS turn — legacy recall hits
    /// plus the ContextFlow packet's resolved provenance. On active turns
    /// memory arrives in the packet and `recalled` is empty, so without the
    /// provenance half the recalled-memory stamp (and therefore next-turn
    /// memoryActivation) never fires. Legacy hits keep their order; packet
    /// provenance (already sorted) appends after; deduped, capped 32 to match
    /// the stamping bound downstream.
    public var resolvedRecalledIds: [String] {
        var out: [String] = []
        var seen = Set<String>()
        for hit in recalled {
            if case .object(let obj)? = hit.extras,
               case .string(let id)? = obj["id"],
               seen.insert(id).inserted {
                out.append(id)
            }
        }
        for id in fluidContextTurn?.selectedMemoryRecordIDs ?? [] where seen.insert(id).inserted {
            out.append(id)
        }
        return Array(out.prefix(32))
    }

    public init(
        surface: String,
        personaID: String? = nil,
        personaDocs: [String: String],
        recalled: [MemoryRecallHit],
        modelId: String,
        reasoningEffort: String,
        providerId: String? = nil,
        serviceTier: String? = nil,
        toolsAvailable: [String],
        systemPrompt: String?,
        userMessage: String,
        toolSchemas: [LLMToolSchema] = [],
        systemSegments: SystemPromptSegments? = nil,
        imageBlocks: [LLMContentBlock] = [],
        fluidContextTurn: ContextPreparedTurn? = nil
    ) {
        self.surface = surface
        self.personaID = personaID
        self.personaDocs = personaDocs
        self.recalled = recalled
        self.modelId = modelId
        self.reasoningEffort = reasoningEffort
        self.providerId = providerId
        self.serviceTier = serviceTier
        self.toolsAvailable = toolsAvailable
        self.toolSchemas = toolSchemas
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.systemSegments = systemSegments
        self.imageBlocks = imageBlocks
        self.fluidContextTurn = fluidContextTurn
    }
}

// MARK: - TurnEngineResult

public struct TurnEngineResult: Sendable {
    public struct TerminalObservation: Sendable, Equatable {
        public let reasoningEffort: String
        public let toolSchemaCount: Int
        public let contextSource: String
        public let contextSelectedAtomCount: Int
        public let contextPacketCharacters: Int
        public let contextExpandablePointerCount: Int

        public init(
            reasoningEffort: String,
            toolSchemaCount: Int,
            contextSource: String,
            contextSelectedAtomCount: Int,
            contextPacketCharacters: Int,
            contextExpandablePointerCount: Int
        ) {
            self.reasoningEffort = reasoningEffort
            self.toolSchemaCount = max(0, toolSchemaCount)
            self.contextSource = contextSource
            self.contextSelectedAtomCount = max(0, contextSelectedAtomCount)
            self.contextPacketCharacters = max(0, contextPacketCharacters)
            self.contextExpandablePointerCount = max(0, contextExpandablePointerCount)
        }

        init(context: TurnContext) {
            self.init(
                reasoningEffort: context.reasoningEffort,
                toolSchemaCount: context.toolSchemas.count,
                contextSource: context.fluidContextTurn == nil ? "legacy" : "fluid_context",
                contextSelectedAtomCount: context.fluidContextTurn?.packet.selectedItems.count ?? 0,
                contextPacketCharacters: context.fluidContextTurn?.packet.characterCount ?? 0,
                contextExpandablePointerCount: context.fluidContextTurn?.packet.expandablePointers.count ?? 0
            )
        }
    }

    public struct ToolDispatchRecord: Sendable {
        /// Provider-issued tool-use identity when the transport supplied one.
        /// Outcome Tissue hashes this before persistence; nil remains an
        /// explicit sequence-only observation for legacy/direct dispatches.
        public let id: String?
        public let name: String
        public let input: [String: JSONValue]
        public let result: JSONValue

        public init(
            id: String? = nil,
            name: String,
            input: [String: JSONValue],
            result: JSONValue
        ) {
            self.id = id
            self.name = name
            self.input = input
            self.result = result
        }
    }

    public let reply: String
    public let modelUsed: String
    public let recalledIds: [String]
    public let toolDispatches: [ToolDispatchRecord]
    public let elapsedMs: Int
    public let rawLLMResponse: String
    /// Exact number of provider completions issued by this engine invocation.
    /// A default keeps non-loop/legacy construction source-compatible; owners
    /// that cannot prove the count leave it nil rather than inventing zero.
    public let providerCallCount: Int?
    /// Exact provider-bound context facts captured by the engine. This is
    /// needed by paths (notably Anthropic text compatibility) whose caller does
    /// not own the final iteration's rebuilt TurnContext.
    public let terminalObservation: TerminalObservation?

    public init(
        reply: String,
        modelUsed: String,
        recalledIds: [String],
        toolDispatches: [ToolDispatchRecord],
        elapsedMs: Int,
        rawLLMResponse: String,
        providerCallCount: Int? = nil,
        terminalObservation: TerminalObservation? = nil
    ) {
        self.reply = reply
        self.modelUsed = modelUsed
        self.recalledIds = recalledIds
        self.toolDispatches = toolDispatches
        self.elapsedMs = elapsedMs
        self.rawLLMResponse = rawLLMResponse
        self.providerCallCount = providerCallCount
        self.terminalObservation = terminalObservation
    }
}

// MARK: - SwiftNativeTurnEngine

public actor SwiftNativeTurnEngine {
    private let persona: any PersonaEngineProtocol
    private let memory: (any MemoryRecalling)?
    private let router: any ProviderRoutingProtocol
    private let trust: SwiftNativeTrustCenter
    private let llm: any LLMClient
    private let tools: any ToolDispatchClient
    let clock: @Sendable () -> Date
    private let memoryPromoter: (any MemoryPromoting)?
    let activeToolsStore: ActiveToolsStore
    let turnTraceBus: TurnTraceBus
    private let contextFlow: (any ContextTurnPreparing)?
    /// dataRoot used to locate rem_pins.json for the chat-turn injection
    /// of REM-approved persona drift. nil → no injection (legacy callers
    /// unaffected).
    private let remPinsDataRoot: URL?
    /// Mind-into-circulation (2026-07-10): a bounded, PURE read of what she is
    /// holding right now, folded into the ContextTurnRequest's dormant
    /// NeedSignal inputs. nil (the default / test path) leaves turn
    /// preparation byte-identical to the unwired behavior.
    private let cognitiveContextProvider: (any CognitiveContextProviding)?
    /// APP-SIDE translation of a MEMORY RECORD id → the ContextAtomID the
    /// memory projection assigns that record. Injected because the projection's
    /// owner string ("nativeagent.memory-v2") must never be hardcoded in a core
    /// module. nil → memory-keyed activation is dropped (terms/intent still
    /// flow); empty is the byte-identical default.
    private let memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)?

    /// Upper bound on the attention-signal read. A slow substrate must never
    /// stall the turn: on expiry we proceed with no signals and flag the trace.
    private static let attentionSignalsTimeoutNanos: UInt64 = 250_000_000

    public init(
        persona: any PersonaEngineProtocol,
        memory: (any MemoryRecalling)?,
        router: any ProviderRoutingProtocol,
        trust: SwiftNativeTrustCenter,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        clock: @escaping @Sendable () -> Date = { Date() },
        remPinsDataRoot: URL? = nil,
        memoryPromoter: (any MemoryPromoting)? = SharedAdaptiveMemoryPromoter(),
        activeToolsStore: ActiveToolsStore? = nil,
        turnTraceBus: TurnTraceBus = .shared,
        contextFlow: (any ContextTurnPreparing)? = nil,
        cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
        memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil
    ) {
        self.persona = persona
        self.memory = memory
        self.router = router
        self.trust = trust
        self.llm = llm
        self.tools = tools
        self.clock = clock
        self.memoryPromoter = memoryPromoter
        self.activeToolsStore = activeToolsStore
            ?? (tools as? any ActiveToolsStoreProviding)?.activeToolsStore
            ?? .shared
        self.turnTraceBus = turnTraceBus
        self.remPinsDataRoot = remPinsDataRoot
        self.contextFlow = contextFlow
        self.cognitiveContextProvider = cognitiveContextProvider
        self.memoryAtomTranslator = memoryAtomTranslator
    }

    func checkedActiveProviderID(for surface: String) async throws -> String? {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let routingSurface = canonicalRoutingSurface(normalized)
        return ProviderRoutingSurfaceLookup.value(
            try await router.checkedRoutingSnapshot().activeProviders, routingSurface
        )
    }

    func checkedRouteAdmission(
        for surface: String,
        requestedModel: String? = nil,
        requestedReasoningEffort: String? = nil
    ) async throws -> TurnRouteAdmission {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let routingSurface = canonicalRoutingSurface(normalized)
        let snapshot = try await router.checkedRoutingSnapshot()
        let preference = ProviderRoutingSurfaceLookup.value(snapshot.preferences, routingSurface)
            ?? snapshot.preferences["chat"]
        let configuredModel = preference?.model
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requested = requestedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An explicit active transport is canonical and its checked snapshot
        // has already reconciled stale cross-provider model picks. Without an
        // active transport, the request-scoped model remains a supported
        // override (Mac/test callers rely on this API contract).
        let admittedModel: String
        if ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, routingSurface) != nil {
            admittedModel = configuredModel.isEmpty ? PRIMARY_MODEL : configuredModel
        } else if !requested.isEmpty {
            admittedModel = requested
        } else {
            admittedModel = configuredModel.isEmpty ? PRIMARY_MODEL : configuredModel
        }
        let requestedEffort = requestedReasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TurnRouteAdmission(
            routingSurface: routingSurface,
            modelId: admittedModel,
            reasoningEffort: requestedEffort.isEmpty
                ? (preference?.reasoningEffort ?? DEFAULT_REASONING_EFFORT)
                : requestedEffort,
            providerId: ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, routingSurface)
                ?? router.inferProviderForModel(admittedModel),
            serviceTier: preference?.serviceTier ?? "default"
        )
    }

    /// Build the per-turn context WITHOUT firing the LLM — for inspection
    /// and for tests that want to verify the assembled prompt shape.
    public func buildTurnContext(
        surface: String,
        userMessage: String
    ) async throws -> TurnContext {
        return try await buildTurnContext(
            surface: surface, userMessage: userMessage, personaOverride: nil
        )
    }

    /// Same as `buildTurnContext(surface:userMessage:)` but with a per-turn
    /// persona override (Mac UI `UserDefaults["chatPersona"]`). The override
    /// is forwarded to `PersonaCompiler.compile(surface:personaOverride:)`
    /// so the SOUL/USER/VOICE/GROWTH/AGENTS pack reflects the picked persona,
    /// not just the persisted `metadata.persona` tag on the assistant turn.
    public func buildTurnContext(
        surface: String,
        userMessage: String,
        personaOverride: String?
    ) async throws -> TurnContext {
        return try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: personaOverride,
            imageBlocks: [],
            recallQueryOverride: nil
        )
    }

    /// Build the per-turn context, optionally carrying per-turn DYNAMIC image
    /// content blocks attached to the CURRENT user message. The image blocks
    /// NEVER enter systemPrompt/systemSegments (cache invariant) — they sit on
    /// `TurnContext.imageBlocks` and are consumed when the first user message
    /// of the conversation is built (ToolLoop/Streaming/Text-compat).
    public func buildTurnContext(
        surface: String,
        userMessage: String,
        personaOverride: String?,
        imageBlocks: [LLMContentBlock],
        recallQueryOverride: String? = nil,
        includeClockContext: Bool = true,
        sessionID: String? = nil,
        recentTurns: [String] = []
    ) async throws -> TurnContext {
        // P2-3, one bridge for the whole turn: fold the surface ONCE here, so
        // every downstream comparison (routing, ContextSurface, autonomy,
        // telemetry, the surface handed to the provider) sees `workshop` and
        // nothing has to know two spellings exist. Only the Workshop spelling
        // is rewritten; other surfaces pass through byte-identical.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        var trace = ContextStageTrace()
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageBlocks.isEmpty
        {
            throw TurnEngineError.emptyMessage
        }
        // Start the existing MiniLM query lane before the bounded attention
        // read. The ticket is read after that already-required work, and the
        // read is bounded by `queryEmbeddingWarmupWaitNanos` — so semantic
        // recall can add at most that much turn wait, and only when the
        // embedder is still cold.
        let queryEmbeddingTicket = await contextFlow?.beginQueryEmbedding(userMessage)

        // Mind-into-circulation: feed Fluid Context's dormant NeedSignal inputs
        // from her current attention BEFORE the request is built. The read is
        // bounded (attentionSignalsTimeoutNanos) so a slow substrate can never
        // stall the turn; nil/empty signals leave the request byte-identical to
        // the unwired path (all default args, no empty strings).
        let attentionStartNs = DispatchTime.now().uptimeNanoseconds
        let attention = await resolvedAttentionInputs(now: clock(), trace: &trace)
        trace.record("contextFlow.attention", since: attentionStartNs)
        // M9 (2026-07-11): on the Workshop surface, ContextFlow reuses
        // `activeTask` as the execution prewarm-cache id (ContextFlowCoordinator
        // prewarmScopes). Her pursuit intent now populates activeTask/goal, so
        // it would collide there — suppress it on that ONE surface. Every other
        // surface (chat/telegram/bridge) keeps the pursuit intent, which is the
        // whole point: her active pursuit colors her context.
        //
        // P2-3: `missions` and `workshop` were two DISTINCT ContextSurfaces
        // until 2026-08-05, so the same surface suppressed or kept pursuit
        // intent depending only on how the caller spelled it — the prewarm
        // collision was live for anyone who wrote `workshop`. They are one
        // surface now, and the suppression follows the surface, not the
        // spelling.
        let suppressPursuitIntent = ContextSurface(rawValue: surface) == .workshop
        // Sweep R4 A5: this used to be a bare `valueIfReady` — a pure sample,
        // never awaited. On the FIRST message after launch MiniLM is still
        // warming, so the sample came back nil and the 1.2-weighted semantic
        // term was zeroed for the whole turn: turn 1 was reliably dumber than
        // turn 2. Wait a bounded interval instead. On timeout we land exactly
        // where the old code landed (nil → lexical-only scoring), so the turn
        // can never block indefinitely; when the embedder warms inside the
        // window, turn 1 gets real semantic scoring. Skipped entirely when
        // ContextFlow is off, where the vector has no consumer.
        let contextFlowMode = await contextFlow?.contextFlowMode() ?? .off
        let readyQueryEmbedding: ContextQueryEmbeddingValue?
        if contextFlowMode == .off {
            readyQueryEmbedding = queryEmbeddingTicket?.valueIfReady
        } else {
            readyQueryEmbedding = await queryEmbeddingTicket?.value(
                waitingUpTo: Self.queryEmbeddingWarmupWaitNanos
            )
        }
        trace.setFlag("contextFlow.semanticQueryReady", readyQueryEmbedding != nil)
        let packetBudget = ContextBudgetPolicy.resolve(
            model: LLMCallContext.admittedModel,
            surface: surface
        )
        trace.setFlag("budget.packetDerived", packetBudget.isDerived)
        let contextFlowRequest = ContextTurnRequest(
            surface: ContextSurface(rawValue: surface),
            origin: Self.contextOrigin(for: surface),
            userMessage: userMessage,
            personaIDHint: personaOverride,
            sessionID: sessionID,
            recentTurns: recentTurns,
            activeTask: suppressPursuitIntent ? nil : attention.activeTask,
            unresolvedQuestion: attention.unresolvedQuestion,
            goal: suppressPursuitIntent ? nil : attention.goal,
            predictedToolGroups: attention.predictedToolGroups,
            contextualTerms: attention.contextualTerms,
            cognitiveActivation: attention.cognitiveActivation,
            workingAtomIDs: attention.workingAtomIDs,
            queryEmbedding: readyQueryEmbedding?.values,
            queryEmbeddingModelFingerprint: readyQueryEmbedding?.modelFingerprint,
            // Authoritative mandatory context (especially accumulated explicit
            // corrections) may grow beyond the ordinary 6k ranked packet. Keep
            // the common case byte-identical, but allow one bounded retry with
            // enough room for mandatory truth plus useful memory/task context
            // instead of falling back to the much larger legacy prompt.
            //
            // Sweep R4 W3: sized from the window when one is known. The packet
            // is assembled BEFORE the router resolves this turn's model, so the
            // only model available here is the one the chat facade already
            // admitted and bound into `LLMCallContext` (the live chat path).
            // Direct callers that skip admission get nil → the 6k/24k/4k
            // floors, byte-identical to before.
            characterBudget: packetBudget.packetChars,
            maximumCharacterBudget: packetBudget.packetExpandedChars,
            postMandatoryCharacterReserve: packetBudget.packetPostMandatoryReserve
        )
        var preparedContextTurn: ContextPreparedTurn?
        switch contextFlowMode {
        case .off:
            trace.setFlag("contextFlow.enabled", false)
        case .shadow:
            trace.setFlag("contextFlow.enabled", true)
            trace.setFlag("contextFlow.shadow", true)
            if let contextFlow {
                Task.detached(priority: .utility) {
                    _ = try? await contextFlow.prepareContextTurn(contextFlowRequest)
                }
            }
        case .active:
            trace.setFlag("contextFlow.enabled", true)
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                preparedContextTurn = try await contextFlow?.prepareContextTurn(contextFlowRequest)
                trace.setFlag("contextFlow.active", preparedContextTurn != nil)
                if let effectiveBudget = preparedContextTurn?.need.characterBudget,
                   effectiveBudget > contextFlowRequest.characterBudget {
                    trace.setFlag("contextFlow.budgetExpanded", true)
                    trace.setCount(
                        "contextFlow.requestedCharacterBudget",
                        contextFlowRequest.characterBudget
                    )
                    trace.setCount(
                        "contextFlow.effectiveCharacterBudget",
                        effectiveBudget
                    )
                }
                trace.record("contextFlow.prepare", since: start)
            } catch {
                trace.setFlag("contextFlow.fallback", true)
                trace.setLabel(
                    "contextFlow.fallbackError",
                    "\(String(reflecting: type(of: error))): \(String(describing: error))"
                )
                trace.record("contextFlow.prepare", since: start)
            }
        }
        // 1. Reuse the facade's already-checked route when present. Direct
        //    context callers still admit here. This avoids adding a second
        //    provider-store read to ordinary chat; the shared adapter performs
        //    its existing checked reread immediately before transport, so
        //    corrupt/revoked authority still fails closed without allowing a
        //    newer valid generation to splice into this turn.
        let routingSurface = canonicalRoutingSurface(surface)
        let boundModel = LLMCallContext.admittedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundEffort = LLMCallContext.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefs: [String: SurfacePreference]
        let modelId: String
        let effort: String
        let admittedProvider: String?
        let admittedServiceTier: String?
        var activeProviders: [String: String] = [:]
        if let boundModel, !boundModel.isEmpty,
           let boundEffort, !boundEffort.isEmpty {
            modelId = boundModel
            effort = boundEffort
            admittedProvider = LLMCallContext.providerId
                ?? router.inferProviderForModel(boundModel)
            admittedServiceTier = LLMCallContext.serviceTier
            prefs = [routingSurface: SurfacePreference(
                surface: routingSurface,
                model: modelId,
                reasoningEffort: effort,
                serviceTier: admittedServiceTier ?? "default"
            )]
            if includeClockContext, let admittedProvider {
                activeProviders[routingSurface] = admittedProvider
            }
            trace.setFlag("provider.admissionReused", true)
        } else {
            let prefsStartNs = DispatchTime.now().uptimeNanoseconds
            let routingSnapshot = try await router.checkedRoutingSnapshot()
            trace.record("provider.preferences", since: prefsStartNs)
            prefs = routingSnapshot.preferences
            // Bridged, not subscripted (P2-3): a snapshot still keyed
            // `missions` must not fall through to the CHAT model here.
            let pick = ProviderRoutingSurfaceLookup.value(prefs, routingSurface) ?? prefs["chat"]
            modelId = pick?.model ?? PRIMARY_MODEL
            effort = pick?.reasoningEffort ?? DEFAULT_REASONING_EFFORT
            admittedProvider = ProviderRoutingSurfaceLookup
                .value(routingSnapshot.activeProviders, routingSurface)
                ?? router.inferProviderForModel(modelId)
            admittedServiceTier = pick?.serviceTier
            if includeClockContext {
                activeProviders = routingSnapshot.activeProviders
                if let admittedProvider {
                    activeProviders[routingSurface] = admittedProvider
                }
            }
            trace.setFlag("provider.admissionReused", false)
        }
        trace.setFlag("snapshot.activeProviders.loaded", includeClockContext)

        // 2. Compile the Agent/Custom persona packet for THIS surface. This
        //    replaces the legacy `persona.listPersonaDocs()` dir-scan path
        //    which (a) returned stray *.md files like DREAMS.md, (b) had no
        //    canonical ordering, and (c) ignored per-turn persona overrides.
        //    PersonaCompiler bakes SOUL/VOICE/USER/GROWTH/AGENTS + the
        //    surface guidance in the daemon's canonical order, applies the
        //    Mac UI chatPersona override when supplied, and produces a
        //    persona-kind-aware fingerprint.
        let personaMap: [String: String]
        let resolvedPersonaID: String?
        let compiledPersonaPrompt: String?
        let personaStartNs = DispatchTime.now().uptimeNanoseconds
        do {
            if let preparedContextTurn {
                resolvedPersonaID = preparedContextTurn.mirror.personaID.rawValue
                personaMap = Dictionary(uniqueKeysWithValues: preparedContextTurn.mirror.documents.map {
                    (String($0.id.rawValue.dropLast(3)), $0.text)
                })
                compiledPersonaPrompt = preparedContextTurn.kernel.renderedPrompt
                trace.setCount(
                    "contextFlow.selectedAtoms",
                    preparedContextTurn.packet.selectedItems.count
                )
                trace.setCount(
                    "contextFlow.packetChars",
                    preparedContextTurn.packet.characterCount
                )
                trace.setCount(
                    "contextFlow.memoryRecords",
                    preparedContextTurn.selectedMemoryRecordIDs.count
                )
            } else if let swiftPersona = persona as? SwiftNativePersonaEngine {
                let compiler = PersonaCompiler(engine: swiftPersona)
                let packet = try await compiler.compile(
                    surface: surface, personaOverride: personaOverride
                )
                resolvedPersonaID = packet.personaId
                personaMap = packet.activeDocs
                compiledPersonaPrompt = packet.compiledSystemPrompt
            } else {
                resolvedPersonaID = personaOverride
                let docs = try await persona.listPersonaDocs()
                personaMap = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0.content) })
                compiledPersonaPrompt = nil
            }
            trace.record("persona.compile", since: personaStartNs)
        } catch {
            trace.record("persona.compile", since: personaStartNs)
            throw TurnEngineError.personaLoadFailed(underlying: error)
        }

        // 3. REM pins FIRST (fix 6 — pre-emptive, not appended).
        //    Load pins before memory recall so they can override recalls that
        //    share a topic. Pins are REM-approved overrides and take precedence.
        let remStartNs = DispatchTime.now().uptimeNanoseconds
        var remPins: [REMPin] = []
        if let dataRoot = remPinsDataRoot {
            let idx = REMPinsReader.read(dataRoot: dataRoot)
            remPins = REMPinsReader.latest(idx, latestN: 3)
        }
        trace.record("rem_pins.read", since: remStartNs)

        // 4. Recall memory if configured. Session-backed chat can provide a
        //    compact deterministic expansion of the current user message with
        //    recent continuity anchors; one-shot/no-history turns use the raw
        //    user message exactly as before. Recalls that share a topic/key
        //    with a REM pin are REPLACED by the pin (fix 6 dedup pass below).
        let memoryStartNs = DispatchTime.now().uptimeNanoseconds
        // Sweep R4 W3: `modelId` is resolved above, so recall breadth and the
        // memory block's character bound are now a function of the window
        // instead of the hardcoded k=5 / 5×1,200. Floor regime (small or
        // unknown model) reproduces both exactly.
        let turnBudget = ContextBudgetPolicy.resolve(model: modelId, surface: surface)
        trace.setCount("budget.windowTokens", turnBudget.windowTokens ?? 0)
        trace.setFlag("budget.derived", turnBudget.isDerived)
        trace.setCount("budget.recallRowLimit", turnBudget.recallRowLimit)
        trace.setCount("budget.memoryBlockChars", turnBudget.memoryBlockChars)
        var recalled: [MemoryRecallHit] = []
        if let preparedContextTurn {
            let memoryAtomCount = preparedContextTurn.packet.selectedItems.reduce(into: 0) {
                if $1.pointer.kind == .memory || $1.pointer.kind == .correction { $0 += 1 }
            }
            trace.setMemoryRecallOutcome(.contextFlow(hitCount: memoryAtomCount))
            // Task #42: these records are being SERVED into the live turn, and
            // the legacy recall lane (the only other use_count bump) is skipped
            // on this branch. Fire-and-forget after the outcome is traced —
            // zero read latency, mirroring the recall lane's own bump. Only
            // reachable in .active mode inside a real turn: shadow prepares
            // detached and discards, and the frozen/eval lane never runs this
            // engine, so neither can pollute access signals.
            let servedIds = preparedContextTurn.selectedMemoryRecordIDs
            if !servedIds.isEmpty, let memory {
                Task { await memory.recordServedContextHits(ids: servedIds) }
            }
        } else if let memory {
            let recallQuery = recallQueryOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveRecallQuery = (recallQuery?.isEmpty == false) ? recallQuery! : userMessage
            do {
                recalled = try await memory.recall(
                    effectiveRecallQuery,
                    k: turnBudget.recallRowLimit,
                    persona: memoryRecallPersonaFilter(resolvedPersonaID),
                    surface: surface
                )
                trace.setMemoryRecallOutcome(.succeeded(hitCount: recalled.count))
            } catch {
                // FC0 preserves the established empty-recall degradation but
                // stops presenting an error as a healthy zero-hit result.
                recalled = []
                trace.setMemoryRecallOutcome(.failed(
                    errorType: String(reflecting: type(of: error))
                ))
            }
        } else {
            trace.setMemoryRecallOutcome(.notConfigured)
        }
        trace.record("memory.recall", since: memoryStartNs)
        // Dedup: drop recalls whose text is superseded by a REM pin sharing
        // the same key or whose preview contains the pin's text verbatim.
        // This keeps the context tight — the pin IS the authoritative fact.
        if !remPins.isEmpty {
            recalled = recalled.filter { hit in
                !remPins.contains(where: { pin in
                    hit.preview.contains(pin.text) || pin.text.contains(hit.preview)
                })
            }
        }

        // 5. Available tools — surface names + JSON-Schema descriptors so the
        //    LLM can actually emit tool calls. Schema fetch is best-effort:
        //    a dispatcher that only knows names degrades to the pre-W1 wire
        //    path (no `tools` field in the request body).
        let toolNamesStartNs = DispatchTime.now().uptimeNanoseconds
        let toolNames = await FluidContextToolScope.$current.withValue(preparedContextTurn) {
            (try? await tools.listAvailableTools()) ?? []
        }
        trace.record("tools.names", since: toolNamesStartNs)
        let toolSchemasStartNs = DispatchTime.now().uptimeNanoseconds
        let toolSchemas = await FluidContextToolScope.$current.withValue(preparedContextTurn) {
            (try? await tools.listAvailableToolSchemas()) ?? []
        }
        trace.record("tools.schemas", since: toolSchemasStartNs)
        let snapshot = TurnContextSnapshot(
            providerPreferences: prefs,
            activeProviders: activeProviders,
            toolNames: toolNames,
            toolSchemas: toolSchemas
        )

        // 6. Assembled system prompt: compiled persona packet (canonical
        //    order, surface guidance baked in) + recall + REM pins rendered
        //    INLINE under a dedicated header (fix 6 — pins pre-emptive).
        //    U1 step 2b/3b: rendered as STABLE (persona+pins) / DYNAMIC
        //    (recall) segments; the combined systemPrompt is derived from
        //    the segments so `systemPrompt == segments.combined` holds by
        //    construction (the caching-contract invariant the Anthropic
        //    adapters verify before splitting system blocks).
        let renderStartNs = DispatchTime.now().uptimeNanoseconds
        let rawSegments: SystemPromptSegments
        if let compiledPersonaPrompt {
            rawSegments = Self.renderSystemPromptSegments(
                compiledPersonaPrompt: compiledPersonaPrompt,
                recalled: recalled,
                remPins: remPins,
                budget: turnBudget
            )
        } else {
            rawSegments = Self.renderSystemPromptSegments(
                personaDocs: personaMap,
                recalled: recalled,
                remPins: remPins,
                budget: turnBudget
            )
        }
        let packetDynamic = preparedContextTurn.map(Self.renderContextPacket) ?? ""
        let resolvedSegments: SystemPromptSegments
        if packetDynamic.isEmpty {
            resolvedSegments = rawSegments
        } else {
            let dynamic = rawSegments.dynamic.isEmpty
                ? packetDynamic
                : packetDynamic + "\n\n" + rawSegments.dynamic
            resolvedSegments = SystemPromptSegments(stable: rawSegments.stable, dynamic: dynamic)
        }
        trace.record("prompt.render", since: renderStartNs)
        let baseContext = TurnContext(
            surface: surface,
            personaID: resolvedPersonaID,
            personaDocs: personaMap,
            recalled: recalled,
            modelId: modelId,
            reasoningEffort: effort,
            providerId: admittedProvider,
            serviceTier: admittedServiceTier,
            toolsAvailable: snapshot.toolNames,
            systemPrompt: resolvedSegments.combined,
            userMessage: userMessage,
            toolSchemas: snapshot.toolSchemas,
            systemSegments: resolvedSegments,
            imageBlocks: imageBlocks,
            fluidContextTurn: preparedContextTurn
        )
        let finalContext: TurnContext
        if includeClockContext {
            let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
            finalContext = await contextByAppendingCurrentTurnFacts(
                baseContext
            )
            trace.record("context.clock_runtime", since: runtimeStartNs)
        } else {
            finalContext = baseContext
        }
        trace.setCount("snapshot.providerPrefs", snapshot.providerPreferences.count)
        trace.setCount("snapshot.activeProviders", snapshot.activeProviders.count)
        trace.setCount("snapshot.toolNames", snapshot.toolNames.count)
        trace.setCount("snapshot.toolSchemas", snapshot.toolSchemas.count)
        trace.setCount("snapshot.toolSchemaParameterBytes", snapshot.toolSchemaParameterBytes)
        trace.setCount("persona.docCount", personaMap.count)
        trace.setCount("persona.docChars", personaMap.values.reduce(0) { $0 + $1.count })
        trace.setCount("remPins.count", remPins.count)
        trace.setCount("memory.recallHits", recalled.count)
        trace.setCount("system.stableChars", finalContext.systemSegments?.stable.count ?? 0)
        trace.setCount("system.dynamicChars", finalContext.systemSegments?.dynamic.count ?? 0)
        trace.setCount("system.combinedChars", finalContext.systemPrompt?.count ?? 0)
        trace.setCount("userMessageChars", userMessage.count)
        trace.setCount("imageBlockCount", imageBlocks.count)
        trace.setFlag("snapshot.requestScoped", true)
        trace.emit(kind: "context.summary", surface: surface)
        return finalContext
    }

    // MARK: - Mind-into-circulation attention inputs

    /// The subset of ContextTurnRequest fields derived from her current
    /// attention. All-default = byte-identical to the unwired request.
    private struct AttentionInputs {
        var contextualTerms: Set<String> = []
        var unresolvedQuestion: String?
        var activeTask: String?
        var goal: String?
        var predictedToolGroups: Set<String> = []
        var cognitiveActivation: [ContextAtomID: Double] = [:]
        var workingAtomIDs: Set<ContextAtomID> = []
    }

    private enum AttentionRaceOutcome: Sendable {
        case signals(CognitiveAttentionSignals?, CognitiveAttentionTraceRecorder.Snapshot)
        case timedOut(CognitiveAttentionTraceRecorder.Snapshot)
    }

    /// Bounded, pure read of the cognitive provider's attention signals,
    /// translated into ContextTurnRequest inputs. Records per-input trace
    /// counts + a timeout flag. Returns all-default inputs when no provider is
    /// wired, the provider returns nil/empty, or the read exceeds the deadline.
    private func resolvedAttentionInputs(
        now: Date,
        trace: inout ContextStageTrace
    ) async -> AttentionInputs {
        guard let cognitiveContextProvider else { return AttentionInputs() }

        // ABANDON, don't await (gpt-5.5 HIGH, 2026-07-10): a task group's
        // scope waits for its children even after cancelAll(), so a wedged or
        // non-cooperative provider read would still hold the turn past the
        // deadline. House latch pattern instead (ResumeGuard, same as the
        // subprocess watchdog): whichever side fires first resumes the
        // continuation; the loser is abandoned outright. Abandoning the read
        // is safe — it is a pure peek that mutates nothing.
        let latch = SwiftToolDispatcher.ResumeGuard()
        let attentionTrace = CognitiveAttentionTraceRecorder()
        let outcome: AttentionRaceOutcome = await withCheckedContinuation { continuation in
            let readTask = Task {
                let signals = await CognitiveAttentionTraceContext.$recorder.withValue(attentionTrace) {
                    await cognitiveContextProvider.attentionSignals(at: now)
                }
                attentionTrace.markCompleted()
                let snapshot = attentionTrace.snapshot()
                if latch.tryResume() {
                    continuation.resume(returning: .signals(signals, snapshot))
                } else {
                    // The outer turn already continued. Record one bounded,
                    // exceptional completion receipt so abandoned work can be
                    // distinguished from a cooperative cancellation without
                    // adding a normal-path trace row.
                    let stages = snapshot.stagesMilliseconds.mapValues(JSONValue.int)
                    TurnTraceBus.fireFromContext(
                        kind: "context.attention.late-completion",
                        payload: .object([
                            "schema": .string("context.attention.late-completion.v1"),
                            "totalMs": .int(snapshot.totalMilliseconds),
                            "cancellationObserved": .bool(snapshot.cancellationObserved),
                            "stageMs": .object(stages),
                        ])
                    )
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: Self.attentionSignalsTimeoutNanos)
                if latch.tryResume() {
                    readTask.cancel()   // best effort; the turn no longer waits
                    continuation.resume(returning: .timedOut(attentionTrace.snapshot()))
                }
            }
        }

        let signals: CognitiveAttentionSignals?
        switch outcome {
        case .timedOut(let snapshot):
            recordAttentionTrace(snapshot, into: &trace)
            trace.setFlag("contextFlow.attentionTimedOut", true)
            return AttentionInputs()
        case .signals(let value, let snapshot):
            recordAttentionTrace(snapshot, into: &trace)
            signals = value
        }

        guard let signals, !signals.isEmpty else {
            trace.setFlag("contextFlow.attentionPresent", false)
            return AttentionInputs()
        }
        trace.setFlag("contextFlow.attentionPresent", true)

        var inputs = AttentionInputs()
        // Terms carry weights across the seam but fold into queryText lexically —
        // only the keys are needed here (empties dropped: never pass empty text).
        inputs.contextualTerms = Set(signals.terms.keys.filter { !$0.isEmpty })
        inputs.predictedToolGroups = signals.predictedToolGroups
        inputs.unresolvedQuestion = Self.nonEmpty(signals.unresolvedQuestion)
        inputs.activeTask = Self.nonEmpty(signals.activeTask)
        inputs.goal = Self.nonEmpty(signals.goal)

        // Memory RECORD ids → ContextAtomID is app-owned (owner string lives
        // app-side). Without a translator, memory-keyed activation is dropped;
        // terms/intent still flow.
        if let memoryAtomTranslator {
            for (recordID, weight) in signals.memoryActivation {
                guard let atomID = memoryAtomTranslator(recordID) else { continue }
                inputs.cognitiveActivation[atomID] = max(
                    inputs.cognitiveActivation[atomID] ?? 0, weight
                )
            }
            for recordID in signals.workingMemoryRecordIDs {
                if let atomID = memoryAtomTranslator(recordID) {
                    inputs.workingAtomIDs.insert(atomID)
                }
            }
        }

        trace.setCount("contextFlow.attentionTerms", inputs.contextualTerms.count)
        trace.setCount("contextFlow.attentionToolGroups", inputs.predictedToolGroups.count)
        trace.setCount("contextFlow.attentionActivation", inputs.cognitiveActivation.count)
        trace.setCount("contextFlow.attentionWorkingAtoms", inputs.workingAtomIDs.count)
        return inputs
    }

    private func recordAttentionTrace(
        _ snapshot: CognitiveAttentionTraceRecorder.Snapshot,
        into trace: inout ContextStageTrace
    ) {
        for (stage, milliseconds) in snapshot.stagesMilliseconds {
            trace.setTiming("contextFlow.attention.\(stage)", milliseconds: milliseconds)
        }
        trace.setFlag("contextFlow.attentionCompleted", snapshot.completed)
        trace.setFlag("contextFlow.attentionCancellationObserved", snapshot.cancellationObserved)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    nonisolated private static func contextOrigin(for surface: String) -> ContextOriginClass {
        switch ContextSurface(rawValue: surface) {
        case .telegram, .ios, .slack:
            .remoteAuthenticated
        default:
            .localAuthenticated
        }
    }

    nonisolated private static func renderContextPacket(_ prepared: ContextPreparedTurn) -> String {
        var sections: [String] = []
        if !prepared.packet.selectedItems.isEmpty {
            let items = prepared.packet.selectedItems.map { item in
                "- [\(item.pointer.kind.rawValue)] \(item.text)"
            }.joined(separator: "\n")
            sections.append("# Relevant context (derived from canonical local sources)\n\(items)")
        }
        if !prepared.packet.expandablePointers.isEmpty {
            let pointerLines: String = prepared.packet.expandablePointers.map { pointer in
                let heading = pointer.headingPath.isEmpty
                    ? pointer.kind.rawValue
                    : pointer.headingPath.joined(separator: " > ")
                return "- \(pointer.atomID.rawValue): \(heading)"
            }.joined(separator: "\n")
            sections.append(
                "# Deeper context available on demand\n"
                + "Use context_expand with one of these atom ids only when the deeper section is needed.\n"
                + pointerLines
            )
        }
        return sections.joined(separator: "\n\n")
    }

    /// Execute one turn: assemble context → ONE LLM call → return.
    ///
    /// Phase B carve: no tool-call parse + dispatch loop yet. `toolDispatches`
    /// in the result is therefore always empty in this commit (tests pin it).
    public func executeTurn(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil
    ) async throws -> TurnEngineResult {
        // Pre-flight: empty / whitespace-only messages never reach the
        // router, persona, memory, or LLM.
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TurnEngineError.emptyMessage
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let ctx = try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: nil,
            imageBlocks: [],
            sessionID: sessionId
        )

        let raw = try await llm.complete(
            prompt: ctx.userMessage,
            system: ctx.systemPrompt,
            model: ctx.modelId,
            tools: ctx.toolSchemas.isEmpty ? nil : ctx.toolSchemas
        )
        await ctx.fluidContextTurn?.recordOutcome(.completed)

        // Realtime memory-promotion side channel. Fully best-effort — staging
        // errors must never poison the turn return path.
        await observeMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: raw,
            sessionId: sessionId,
            surface: surface
        )

        let recalledIds = ctx.resolvedRecalledIds

        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: raw,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: [],
            elapsedMs: elapsedMs,
            rawLLMResponse: raw
        )
    }

    // MARK: helpers

    func observeMemoryPromotion(
        userMessage: String,
        assistantMessage: String,
        sessionId: String?,
        surface: String = "chat"
    ) async {
        let startNs = DispatchTime.now().uptimeNanoseconds
        guard let memoryPromoter else {
            ContextStageTrace.emitStage(
                name: "memory.promotion",
                elapsedMs: Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
                surface: surface,
                counts: [
                    "userMessageChars": Int64(userMessage.count),
                    "assistantMessageChars": Int64(assistantMessage.count),
                ],
                flags: ["configured": false]
            )
            return
        }
        await memoryPromoter.observeTurn(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId ?? "swift-turn-engine"
        )
        ContextStageTrace.emitStage(
            name: "memory.promotion",
            elapsedMs: Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            surface: surface,
            counts: [
                "userMessageChars": Int64(userMessage.count),
                "assistantMessageChars": Int64(assistantMessage.count),
            ],
            flags: ["configured": true]
        )
    }

    func contextByAppendingCurrentTurnFacts(
        _ context: TurnContext
    ) async -> TurnContext {
        let withClock = Self.contextByAppendingClockContext(context, now: clock())
        guard let runtimeContext = await renderRuntimeContext(
            surface: withClock.surface,
            modelId: withClock.modelId,
            providerId: withClock.providerId
        ) else {
            return withClock
        }
        return Self.contextByAppendingRuntimeContext(withClock, runtimeContext: runtimeContext)
    }

    private func renderRuntimeContext(
        surface: String,
        modelId: String,
        providerId: String?
    ) async -> String? {
        let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceName = normalizedSurface.isEmpty ? "chat" : normalizedSurface
        let provider = providerId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerName = (provider?.isEmpty == false)
            ? provider!
            : (router.inferProviderForModel(model) ?? "unknown")
        return Self.renderRuntimeContext(
            surface: surfaceName,
            provider: providerName,
            model: model
        )
    }

    nonisolated static func renderSystemPrompt(
        personaDocs: [String: String],
        recalled: [MemoryRecallHit]
    ) -> String {
        renderSystemPrompt(personaDocs: personaDocs, recalled: recalled, remPins: [])
    }

    nonisolated static func renderSystemPrompt(
        personaDocs: [String: String],
        recalled: [MemoryRecallHit],
        remPins: [REMPin]
    ) -> String {
        // Legacy concatenation kept for direct test callers. The chat-turn
        // path now calls the compiled-prompt overload below.
        renderSystemPromptSegments(
            personaDocs: personaDocs, recalled: recalled, remPins: remPins
        ).combined
    }

    /// Bounded wait for a cold MiniLM to publish the query embedding (sweep R4
    /// A5). Sized to cover a first-turn model load without being felt as
    /// latency; on expiry the turn proceeds with no semantic term, exactly as
    /// it did before this wait existed.
    nonisolated static let queryEmbeddingWarmupWaitNanos: UInt64 = 700_000_000

    // MARK: - Recalled-memory prompt block (sweep R4, finding A4)

    /// Per-row character bound and row count for recalled memories rendered
    /// into the system prompt moved to `ContextBudgetPolicy` in sweep R4 W3
    /// (`floorMemoryRowChars` / `floorRecallRowLimit`, and their window-scaled
    /// forms `memoryRowChars` / `recallRowLimit`). They are deliberately NOT
    /// mirrored back here: two sources of truth for a budget is exactly the
    /// shape this wave retired.
    ///
    /// Why 1,200 is the floor, retained from A4: `MemoryRecallHit.content`
    /// carries the (sentence-safe capped) FULL memory text and exists precisely
    /// so prompt render sites stop showing the 200-char `preview` (see the
    /// field's doc comment in MemoryV2.swift). 1,200 keeps a long memory whole
    /// in the common case while still bounding a pathological row.
    ///
    /// Renders the recall block for BOTH system-prompt lanes (legacy persona
    /// docs and compiled persona packet), which previously duplicated a
    /// `- \(hit.preview)` bullet list under a `Recent memory:` header. Three
    /// things were wrong with that: it showed a 200-char preview when the full
    /// text was already in hand, it carried no timestamp or authority so the
    /// model could not tell a 2024 fact from yesterday's correction, and the
    /// header claimed RECENCY for rows that are RELEVANCE-ranked.
    /// Sweep R4 W3: row count, per-row cap and the block's aggregate bound all
    /// come from `ContextBudgetPolicy` now. `budget == nil` resolves the floor
    /// regime, whose values are the former `recalledMemoryRowLimit` /
    /// `recalledMemoryRowCharCap` literals — so every existing caller and test
    /// renders byte-identical output. The aggregate bound is what stops a
    /// doubled row count on a wide window from multiplying the block without
    /// limit; it never binds in the floor regime (5 × 1,200 == 6,000).
    nonisolated static func renderRecalledMemoryBlock(
        _ recalled: [MemoryRecallHit],
        budget: ContextBudgetPolicy.Resolved? = nil
    ) -> String? {
        guard !recalled.isEmpty else { return nil }
        let resolved = budget ?? ContextBudgetPolicy.resolve(
            windowTokens: nil, surface: "chat"
        )
        var used = 0
        var bullets: [String] = []
        for hit in recalled.prefix(resolved.recallRowLimit) {
            let full = (hit.content ?? hit.preview)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !full.isEmpty else { continue }
            let bounded = full.count > resolved.memoryRowChars
                ? String(full.prefix(resolved.memoryRowChars)) + "…"
                : full
            let marker = recalledMemoryMarker(hit)
            let line = marker.isEmpty ? "- \(bounded)" : "- \(bounded) \(marker)"
            // The aggregate bound is a DERIVED-regime instrument only. In the
            // floor regime the pre-policy renderer emitted all 5 rows with no
            // block-level check, and the provenance markers push 5 full rows a
            // few hundred chars past 5×1,200 — applying the bound there would
            // silently drop the last row. Byte-identity wins.
            // First derived row always renders (a single oversized memory beats
            // an empty block); later rows must fit the bound.
            if resolved.isDerived, !bullets.isEmpty,
               used + line.count > resolved.memoryBlockChars { break }
            used += line.count
            bullets.append(line)
        }
        guard !bullets.isEmpty else { return nil }
        return "Relevant memory:\n" + bullets.joined(separator: "\n")
    }

    /// Compact `[2026-07-14, preference]` provenance marker. Either half may be
    /// absent (KG-fallback rows carry no timestamp; legacy rows carry no kind),
    /// and an entirely empty marker is omitted rather than rendered as `[]`.
    nonisolated static func recalledMemoryMarker(_ hit: MemoryRecallHit) -> String {
        var parts: [String] = []
        if let day = recalledMemoryDay(hit.ts) { parts.append(day) }
        if let kind = recalledMemoryKind(hit) { parts.append(kind) }
        guard !parts.isEmpty else { return "" }
        return "[\(parts.joined(separator: ", "))]"
    }

    /// `YYYY-MM-DD` prefix of an ISO-8601 stamp, or nil when the stamp is
    /// missing or not actually ISO-shaped (never guess a date at the model).
    private nonisolated static func recalledMemoryDay(_ ts: String?) -> String? {
        guard let ts else { return nil }
        let trimmed = ts.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let day = String(trimmed.prefix(10))
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        return day
    }

    /// Memory kind ("preference", "fact", …). The SQLite recall lane stamps it
    /// into the hit's free-form `extras` bag; older/other producers only carry
    /// `role`. No new struct field, so no wire-shape change.
    private nonisolated static func recalledMemoryKind(_ hit: MemoryRecallHit) -> String? {
        if case .object(let extras)? = hit.extras,
           case .string(let kind)? = extras["kind"] {
            let trimmed = kind.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let role = hit.role?.trimmingCharacters(in: .whitespacesAndNewlines),
           !role.isEmpty {
            return role
        }
        return nil
    }

    /// Segment-producing core for the legacy (non-compiled) persona path.
    /// Stable = persona block only. The legacy render order puts recall
    /// BEFORE pins, so pins land in the dynamic segment here — the byte
    /// layout of `combined` is unchanged from the pre-segments rendering
    /// (`systemPrompt == combined` is the invariant; we never reorder).
    nonisolated static func renderSystemPromptSegments(
        personaDocs: [String: String],
        recalled: [MemoryRecallHit],
        remPins: [REMPin],
        budget: ContextBudgetPolicy.Resolved? = nil
    ) -> SystemPromptSegments {
        let stable: String
        if !personaDocs.isEmpty {
            let ids = personaDocs.keys.sorted()
            let concatenated = ids
                .map { "## \($0)\n\(personaDocs[$0] ?? "")" }
                .joined(separator: "\n\n")
            stable = "You are the persona described by these documents:\n\(concatenated)"
        } else {
            stable = "You are a helpful assistant."
        }
        var dynamicLines: [String] = []
        if let memoryBlock = renderRecalledMemoryBlock(recalled, budget: budget) {
            dynamicLines.append(memoryBlock)
        }
        if !remPins.isEmpty {
            let bullets = remPins.map { "- \($0.text)" }.joined(separator: "\n")
            dynamicLines.append("Recent REM-approved persona drift:\n\(bullets)")
        }
        return SystemPromptSegments(
            stable: stable,
            dynamic: dynamicLines.joined(separator: "\n\n")
        )
    }

    /// Render path used by the chat turn after the cutover to
    /// `PersonaCompiler.compile(surface:personaOverride:)`. Takes the
    /// already-baked compiledSystemPrompt (SOUL/VOICE/USER/GROWTH/MEMORY/AGENTS +
    /// surface guidance) and layers on recall + REM pins. The compiled
    /// prompt is treated as the persona body verbatim — we do NOT re-sort,
    /// re-concatenate, or strip docs (the compiler already enforces order
    /// and the canonical doc set).
    ///
    /// Fix 6: REM pins are rendered INLINE under the header
    /// `# Pinned facts (REM-approved overrides)` BEFORE recall hits.
    /// Pins are pre-emptive overrides; recall is contextual evidence.
    /// The `{id, text, createdAt}` shape is preserved in the pin objects.
    nonisolated static func renderSystemPrompt(
        compiledPersonaPrompt: String,
        recalled: [MemoryRecallHit],
        remPins: [REMPin]
    ) -> String {
        renderSystemPromptSegments(
            compiledPersonaPrompt: compiledPersonaPrompt,
            recalled: recalled,
            remPins: remPins
        ).combined
    }

    /// Segment-producing core for the compiled-persona chat path (U1 2b/3b).
    /// STABLE = compiled persona packet + REM pins (rarely change within a
    /// session). DYNAMIC = memory recall (keyed per user message — churns
    /// every turn). `combined` is byte-identical to the pre-segments
    /// rendering; the split only marks where the provider cache breakpoint
    /// may safely land.
    nonisolated static func renderSystemPromptSegments(
        compiledPersonaPrompt: String,
        recalled: [MemoryRecallHit],
        remPins: [REMPin],
        budget: ContextBudgetPolicy.Resolved? = nil
    ) -> SystemPromptSegments {
        var stableLines: [String] = []
        let body = compiledPersonaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            stableLines.append(body)
        } else {
            stableLines.append("You are a helpful assistant.")
        }
        // Fix 6: pins rendered FIRST, under a dedicated authority header.
        if !remPins.isEmpty {
            let bullets = remPins.map { "- \($0.text)" }.joined(separator: "\n")
            stableLines.append("# Pinned facts (REM-approved overrides)\n\(bullets)")
        }
        var dynamicLines: [String] = []
        if let memoryBlock = renderRecalledMemoryBlock(recalled, budget: budget) {
            dynamicLines.append(memoryBlock)
        }
        return SystemPromptSegments(
            stable: stableLines.joined(separator: "\n\n"),
            dynamic: dynamicLines.joined(separator: "\n\n")
        )
    }

    nonisolated static func segmentsByAppendingClockContext(
        _ segments: SystemPromptSegments,
        now: Date,
        localTimeZone: TimeZone = .current
    ) -> SystemPromptSegments {
        let clockContext = renderClockContext(now: now, localTimeZone: localTimeZone)
        guard !clockContext.isEmpty else { return segments }
        let dynamic = segments.dynamic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? clockContext
            : segments.dynamic + "\n\n" + clockContext
        return SystemPromptSegments(stable: segments.stable, dynamic: dynamic)
    }

    nonisolated static func contextByAppendingClockContext(
        _ context: TurnContext,
        now: Date,
        localTimeZone: TimeZone = .current
    ) -> TurnContext {
        let clockContext = renderClockContext(now: now, localTimeZone: localTimeZone)
        guard !clockContext.isEmpty else { return context }

        let segments: SystemPromptSegments?
        let systemPrompt: String?
        if let existingSegments = context.systemSegments {
            segments = segmentsByAppendingClockContext(
                existingSegments,
                now: now,
                localTimeZone: localTimeZone
            )
            systemPrompt = segments?.combined
        } else {
            segments = nil
            let existing = context.systemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            systemPrompt = existing.isEmpty
                ? clockContext
                : existing + "\n\n" + clockContext
        }

        return TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            recalled: context.recalled,
            modelId: context.modelId,
            reasoningEffort: context.reasoningEffort,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: segments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn
        )
    }

    nonisolated static func contextByAppendingRuntimeContext(
        _ context: TurnContext,
        runtimeContext: String
    ) -> TurnContext {
        let trimmed = runtimeContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return context }

        let segments: SystemPromptSegments?
        let systemPrompt: String?
        if let existingSegments = context.systemSegments {
            let dynamic = existingSegments.dynamic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? trimmed
                : existingSegments.dynamic + "\n\n" + trimmed
            segments = SystemPromptSegments(stable: existingSegments.stable, dynamic: dynamic)
            systemPrompt = segments?.combined
        } else {
            segments = nil
            let existing = context.systemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            systemPrompt = existing.isEmpty
                ? trimmed
                : existing + "\n\n" + trimmed
        }

        return TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            recalled: context.recalled,
            modelId: context.modelId,
            reasoningEffort: context.reasoningEffort,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: segments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn
        )
    }

    nonisolated static func renderClockContext(
        now: Date,
        localTimeZone: TimeZone = .current,
        centralTimeZone: TimeZone = TimeZone(identifier: "America/Chicago") ?? TimeZone(secondsFromGMT: -6 * 60 * 60)!
    ) -> String {
        let local = formatClockDate(now, timeZone: localTimeZone)
        let central = formatClockDate(now, timeZone: centralTimeZone)
        return "Current time: \(local) (\(localTimeZone.identifier)); Central: \(central) (America/Chicago)."
    }

    nonisolated static func renderRuntimeContext(
        surface: String,
        provider: String,
        model: String
    ) -> String {
        "Current runtime: surface=\(surface); provider=\(provider); model=\(model). If asked what model or provider you are using, answer from Current runtime; do not guess."
    }

    private nonisolated static func formatClockDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }
}
