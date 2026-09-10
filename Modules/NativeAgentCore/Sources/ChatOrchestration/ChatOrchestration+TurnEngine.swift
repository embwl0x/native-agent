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
//   - MemoryRecalling.recall()                  — memory recall boundary
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

// MARK: - SwiftNativeTurnEngine

public actor SwiftNativeTurnEngine {
    private let persona: any PersonaEngineProtocol
    private let memory: (any MemoryRecalling)?
    private let router: any ProviderRoutingProtocol
    private let trust: SwiftNativeTrustCenter
    private let llm: any LLMClient
    private let tools: any ToolDispatchClient
    let clock: @Sendable () -> Date
    // 2026-09-06: injected wait for retry-ladder fixtures (4af32f79,
    // b593d8f2). Default timing, Retry-After and cancellation stay unchanged.
    let providerRecoverySleep: @Sendable (TimeInterval) async throws -> Void
    private let memoryPromoter: (any MemoryPromoting)?
    /// Per-session churn guard for the moments nudge line. Session-local,
    /// in-memory, and forgettable: a restart re-renders one line.
    var momentNudgeState: [String: (lastCount: Int, turnsSinceRender: Int)] = [:]
    let activeToolsStore: ActiveToolsStore
    let turnTraceBus: TurnTraceBus
    private let contextFlow: (any ContextTurnPreparing)?
    /// dataRoot used to locate rem_pins.json for the chat-turn injection
    /// of REM-approved persona drift. nil → no injection (legacy callers
    /// unaffected).
    // internal (was private): the structured tool loop archives each turn's
    // replayable mid-conversation messages under this same root, so the sidecar
    // it writes is the one `buildTurnContextWithHistory` reads back.
    let remPinsDataRoot: URL?
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
    /// One constructor seam disables both additions for an immediate rollback
    /// without changing persona docs or any durable runtime state.
    let naturalExpressionGuidanceEnabled: Bool
    /// Injected only for deterministic turn-boundary proof. Production reads
    /// the canonical preference file through `TurnQuietHoursWindow.read`.
    private let quietHoursReader: @Sendable (URL) -> TurnQuietHoursWindow?

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
        providerRecoverySleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        remPinsDataRoot: URL? = nil,
        memoryPromoter: (any MemoryPromoting)? = SharedAdaptiveMemoryPromoter(),
        activeToolsStore: ActiveToolsStore? = nil,
        turnTraceBus: TurnTraceBus = .shared,
        contextFlow: (any ContextTurnPreparing)? = nil,
        cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
        memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil,
        naturalExpressionGuidanceEnabled: Bool = true,
        quietHoursReader: @escaping @Sendable (URL) -> TurnQuietHoursWindow? = {
            TurnQuietHoursWindow.read(dataRoot: $0)
        }
    ) {
        self.persona = persona
        self.memory = memory
        self.router = router
        self.trust = trust
        self.llm = llm
        self.tools = tools
        self.providerRecoverySleep = providerRecoverySleep ?? {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
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
        self.naturalExpressionGuidanceEnabled = naturalExpressionGuidanceEnabled
        self.quietHoursReader = quietHoursReader
    }

    func readTurnQuietHours() -> TurnQuietHoursWindow? {
        remPinsDataRoot.flatMap(quietHoursReader)
    }

    public func captureTurnQuietHoursSnapshot() -> TurnQuietHoursSnapshot {
        TurnQuietHoursSnapshot(window: readTurnQuietHours())
    }

    func checkedActiveProviderID(for surface: String) async throws -> String? {
        if let choice = ProviderTurnChoice.current { return choice.provider }
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
        if let choice = ProviderTurnChoice.current {
            guard !choice.provider.isEmpty, !choice.model.isEmpty, !choice.reasoningEffort.isEmpty else {
                throw LLMError.providerError(message: "Choose a provider, model and Think level.")
            }
            return TurnRouteAdmission(routingSurface: routingSurface, modelId: choice.model,
                reasoningEffort: choice.reasoningEffort, providerId: choice.provider,
                serviceTier: choice.fast ? "priority" : "default")
        }
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
        recentTurns: [String] = [],
        // The raw user text for RELEVANCE consumers (selection queryText,
        // memory recall, query embedding) when `userMessage` carries
        // turn-scoped wire riders — e.g. the text-compat tool-routing hint,
        // which otherwise makes tool names query vocabulary on every turn.
        // nil → `userMessage` (byte-identical for callers without riders).
        // `userMessage` stays the wire/persona-visible turn text.
        queryUserMessage: String? = nil,
        // Turn-start instant for the clock line; a multi-iteration tool loop
        // passes the same value every iteration so the dynamic segment's
        // time line can't churn the cache mid-turn. nil = clock() per build.
        clockNowOverride: Date? = nil,
        // Optional successful schema walk already performed for this turn.
        // Reused unconditionally: the seed always carries context_expand, so
        // there is no longer a packet-eligibility condition to re-check.
        toolSchemaCatalogSeed: TurnToolSchemaCatalogSeed? = nil,
        // Text-compatible multi-iteration turns capture this once outside the
        // stream loop. nil means this call itself owns a fresh turn capture.
        quietHoursSnapshot: TurnQuietHoursSnapshot? = nil
    ) async throws -> TurnContext {
        let quietHoursWindow: TurnQuietHoursWindow?
        if let quietHoursSnapshot {
            quietHoursWindow = quietHoursSnapshot.window
        } else {
            quietHoursWindow = readTurnQuietHours()
        }
        return try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: personaOverride,
            imageBlocks: imageBlocks,
            recallQueryOverride: recallQueryOverride,
            includeClockContext: includeClockContext,
            sessionID: sessionID,
            recentTurns: recentTurns,
            queryUserMessage: queryUserMessage,
            clockNowOverride: clockNowOverride,
            toolSchemaCatalogSeed: toolSchemaCatalogSeed,
            quietHoursSnapshot: quietHoursWindow
        )
    }

    func buildTurnContext(
        surface: String,
        userMessage: String,
        personaOverride: String?,
        imageBlocks: [LLMContentBlock],
        recallQueryOverride: String?,
        includeClockContext: Bool,
        sessionID: String?,
        recentTurns: [String],
        queryUserMessage: String?,
        clockNowOverride: Date?,
        toolSchemaCatalogSeed: TurnToolSchemaCatalogSeed?,
        quietHoursSnapshot: TurnQuietHoursWindow?
    ) async throws -> TurnContext {
        // P2-3, one bridge for the whole turn: fold the surface ONCE here, so
        // every downstream comparison (routing, ContextSurface, autonomy,
        // telemetry, the surface handed to the provider) sees `workshop` and
        // nothing has to know two spellings exist. Only the Workshop spelling
        // is rewritten; other surfaces pass through byte-identical.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        try Task.checkCancellation()
        var trace = ContextStageTrace()
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageBlocks.isEmpty
        {
            throw TurnEngineError.emptyMessage
        }
        // The relevance-facing view of the turn text. A non-nil
        // queryUserMessage is AUTHORITATIVE even when blank: an
        // attachment-only turn has no text query, and falling back to the
        // wire message there would hand the tool-routing hint to the
        // relevance consumers — the exact pollution this seam removes
        // (gpt-5.5 review 2026-08-13, NEEDS-FIX #1). Blank relevance text is
        // safe: beginQueryEmbedding fail-closes on empty input and selection
        // rides attention terms/entities alone.
        let queryMessage = queryUserMessage ?? userMessage
        trace.setCount("contextFlow.queryMessageChars", queryMessage.count)
        // Start the existing MiniLM query lane before the bounded attention
        // read. The ticket is read after that already-required work, and the
        // read is bounded by `queryEmbeddingWarmupWaitNanos` — so semantic
        // recall can add at most that much turn wait, and only when the
        // embedder is still cold.
        let semanticQuery = SessionHistoryPromptRenderer.semanticRecallQuery(
            userMessage: queryMessage, recentTurns: recentTurns
        )
        trace.setCount("contextFlow.semanticQueryChars", semanticQuery.count)
        let queryEmbeddingTicket = await contextFlow?.beginQueryEmbedding(semanticQuery)

        // Mind-into-circulation: feed Fluid Context's dormant NeedSignal inputs
        // from her current attention BEFORE the request is built. The read is
        // bounded (attentionSignalsTimeoutNanos) so a slow substrate can never
        // stall the turn; nil/empty signals leave the request byte-identical to
        // the unwired path (all default args, no empty strings).
        let attentionStartNs = DispatchTime.now().uptimeNanoseconds
        let attention = await resolvedAttentionInputs(now: clock(), trace: &trace)
        trace.record(.contextFlowAttention, since: attentionStartNs)
        // M9 (2026-07-11): on the Workshop surface, ContextFlow reuses
        // `activeTask` as the execution prewarm-cache id (ContextFlowCoordinator
        // prewarmScopes), so intent must never collide there. Resident Desk
        // pursuit is also withheld from ordinary turns: work context remains
        // query-selectable through its adaptive projection, but does not color
        // unrelated conversation merely because a pursuit exists.
        //
        // P2-3: `missions` and `workshop` were two DISTINCT ContextSurfaces
        // until 2026-08-05, so the same surface suppressed or kept pursuit
        // intent depending only on how the caller spelled it — the prewarm
        // collision was live for anyone who wrote `workshop`. They are one
        // surface now, and the suppression follows the surface, not the
        // spelling.
        let suppressActiveIntent = ContextSurface(rawValue: surface) == .workshop
            || attention.residentWorkIntent
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
            providerID: LLMCallContext.providerId,
            dataRoot: remPinsDataRoot,
            surface: surface
        )
        trace.setFlag("budget.packetDerived", packetBudget.isDerived)
        // Settings ▸ "Remember across conversations". One fresh read per turn,
        // shared by the packet's memory lane and the legacy recall lane below.
        // The explicit `recall_memory` tool is deliberately NOT gated: this
        // switch is about AUTOMATIC recall, not about asking.
        let crossSessionRecall = MemoryPolicyGate.crossSessionRecallEnabled(
            dataRoot: remPinsDataRoot
        )
        trace.setFlag("memory.crossSessionRecall", crossSessionRecall)
        let contextFlowRequest = ContextTurnRequest(
            surface: ContextSurface(rawValue: surface),
            origin: Self.contextOrigin(for: surface),
            userMessage: queryMessage,
            personaIDHint: personaOverride,
            sessionID: sessionID,
            recentTurns: recentTurns,
            activeTask: suppressActiveIntent ? nil : attention.activeTask,
            unresolvedQuestion: attention.unresolvedQuestion,
            goal: suppressActiveIntent ? nil : attention.goal,
            predictedToolGroups: attention.predictedToolGroups,
            contextualTerms: attention.contextualTerms,
            cognitiveActivation: attention.cognitiveActivation,
            workingAtomIDs: attention.workingAtomIDs,
            queryEmbedding: readyQueryEmbedding?.values,
            alternateQueryEmbedding: readyQueryEmbedding?.alternateValues,
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
            postMandatoryCharacterReserve: packetBudget.packetPostMandatoryReserve,
            // The chat turn renders the persona's required documents into the
            // STABLE segment (see `stablePrefixRequiredDocuments`), so the
            // packet must not mirror them into the volatile block as well.
            stableSegmentCarriesRequiredDocuments: true,
            // The same number the renderer cuts at, so the selector publishes a
            // pointer for exactly the atoms that get cut.
            packetAtomExpandThresholdChars:
                ContextBudgetPolicy.packetAtomExpandThresholdChars,
            // ONE owner for the memory row count. `recallRowLimit` bounded only
            // the legacy recall lane, which is empty on ContextFlow turns; the
            // packet's memory lane now answers to the same number.
            //
            // Settings ▸ "Remember across conversations": off means that number
            // is zero, so no memory atom is admitted into the packet. Read
            // fresh per turn, so a flip lands on the next turn.
            memoryAtomRowLimit: crossSessionRecall ? packetBudget.recallRowLimit : 0
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
                try Task.checkCancellation()
                if let expansion = preparedContextTurn?.budgetExpansion {
                    trace.setFlag("contextFlow.budgetExpanded", true)
                    trace.setCount(
                        "contextFlow.requestedCharacterBudget",
                        expansion.requestedCharacterBudget
                    )
                    trace.setCount(
                        "contextFlow.effectiveCharacterBudget",
                        expansion.effectiveCharacterBudget
                    )
                    trace.setCount(
                        "contextFlow.maximumCharacterBudget",
                        expansion.maximumCharacterBudget
                    )
                    trace.setCount(
                        "contextFlow.grantedPostMandatoryReserve",
                        expansion.grantedPostMandatoryReserve
                    )
                }
                trace.record(.contextFlowPrepare, since: start)
            } catch {
                try Task.checkCancellation()
                trace.setFlag("contextFlow.fallback", true)
                trace.setLabel(
                    "contextFlow.fallbackError",
                    "\(String(reflecting: type(of: error))): \(String(describing: error))"
                )
                trace.record(.contextFlowPrepare, since: start)
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
            trace.setFlag("provider.admissionReused", true)
        } else {
            let prefsStartNs = DispatchTime.now().uptimeNanoseconds
            let routingSnapshot = try await router.checkedRoutingSnapshot()
            trace.record(.providerPreferences, since: prefsStartNs)
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
            trace.setFlag("provider.admissionReused", false)
        }

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
                // How many ranked memory rows the semantic floor refused. A
                // packet that is quiet because nothing was relevant and one
                // that is quiet because the embedder was cold look identical
                // downstream; this is the number that tells them apart.
                let memoryFloorDropped = preparedContextTurn.packet.receipt
                    .memoryFloorDroppedCount
                if memoryFloorDropped > 0 {
                    trace.setCount("contextFlow.memoryFloorDropped", memoryFloorDropped)
                }
                // Ambient corrections the per-turn correction cap held back.
                // Published only when it held something, so an untouched
                // turn's trace row is byte-identical to a pre-cap one.
                let correctionCapDropped = preparedContextTurn.packet.receipt
                    .correctionCapDropped
                if correctionCapDropped > 0 {
                    trace.setCount("contextFlow.correctionCapDropped", correctionCapDropped)
                }
                // Lead-and-pointer receipts. `truncatedAtoms` is how many bodies
                // became a rule plus a pointer, `leadChars` is what those leads
                // cost, and `expandableAfterTruncation` must equal
                // `truncatedAtoms` — any gap is a cut body the model cannot get
                // back, which is the one failure mode of this whole change.
                let truncation = Self.packetTruncationCounts(preparedContextTurn)
                trace.setCount("contextFlow.truncatedAtoms", truncation.truncatedAtoms)
                trace.setCount("contextFlow.leadChars", truncation.leadChars)
                trace.setCount(
                    "contextFlow.expandableAfterTruncation",
                    truncation.expandableAfterTruncation
                )
                // The persona's required documents ride the CACHED prefix on
                // this path, not the per-turn packet.
                let stableDocuments = Self.stablePrefixPersonaDocuments(preparedContextTurn)
                trace.setFlag("persona.inStablePrefix", true)
                trace.setCount("persona.stableDocs", stableDocuments.included.count)
                // A document that could not PROVE a surface permission is
                // withheld from the prefix AND refused by the packet, so it is
                // absent from the turn entirely. That is a wiring fault, never a
                // policy outcome, and it must never be silent: name the
                // documents so the trace says which identity went missing.
                if !stableDocuments.unprovenDocumentIDs.isEmpty {
                    trace.setCount(
                        "persona.stableDocsUnproven",
                        stableDocuments.unprovenDocumentIDs.count
                    )
                    trace.setLabel(
                        "persona.stable_doc_unproven",
                        stableDocuments.unprovenDocumentIDs
                            .map(\.rawValue)
                            .sorted()
                            .joined(separator: ",")
                    )
                }
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
            // Microsecond clock (A7): on the ContextFlow-active path the kernel
            // is already compiled in the arena, so this bracket's real work is
            // the mirror→document map — tens of microseconds, which truncated
            // to 0ms on every turn and read as a dark lane.
            trace.recordMicroseconds(.personaCompile, since: personaStartNs)
        } catch {
            trace.recordMicroseconds(.personaCompile, since: personaStartNs)
            try Task.checkCancellation()
            throw TurnEngineError.personaLoadFailed(underlying: error)
        }

        // 3. REM pins FIRST (fix 6 — pre-emptive, not appended).
        //    Load pins before memory recall so they can override recalls that
        //    share a topic. Pins are REM-approved overrides and take precedence.
        let remStartNs = DispatchTime.now().uptimeNanoseconds
        var remPins: [REMPin] = []
        // Personality-depth item 10: her sensibility rides the same read the
        // pins already do — one small file beside them, in the same stable
        // segment, and nil whenever she has never written one.
        var sensibilityBlock: String?
        if let dataRoot = remPinsDataRoot {
            let idx = REMPinsReader.read(dataRoot: dataRoot)
            remPins = REMPinsReader.latest(idx, latestN: 3)
            sensibilityBlock = await SwiftNativeStudioStore(dataRoot: dataRoot)
                .renderedSensibilityBlock()
        }
        trace.record(.remPinsRead, since: remStartNs)

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
        let turnBudget = ContextBudgetPolicy.resolve(
            model: modelId,
            providerID: LLMCallContext.providerId,
            dataRoot: remPinsDataRoot,
            surface: surface
        )
        trace.setCount("budget.windowTokens", turnBudget.windowTokens ?? 0)
        trace.setFlag("budget.derived", turnBudget.isDerived)
        trace.setCount("budget.recallRowLimit", turnBudget.recallRowLimit)
        trace.setCount("budget.memoryBlockChars", turnBudget.memoryBlockChars)
        try Task.checkCancellation()
        var recalled: [MemoryRecallHit] = []
        var servedContextMemoryIDs: [String] = []
        var contextFlowMemoryAtomCount: Int?
        if let preparedContextTurn {
            contextFlowMemoryAtomCount = preparedContextTurn.packet.selectedItems.reduce(into: 0) {
                if $1.pointer.kind == .memory || $1.pointer.kind == .correction { $0 += 1 }
            }
            // Selection alone is not a completed serve. Catalog/runtime
            // assembly below can still suspend and be cancelled.
            servedContextMemoryIDs = preparedContextTurn.selectedMemoryRecordIDs
        } else if let memory, crossSessionRecall {
            // Settings ▸ "Remember across conversations": off skips the
            // automatic root-wide recall entirely (see `crossSessionRecall`).
            let recallQuery = recallQueryOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveRecallQuery = (recallQuery?.isEmpty == false) ? recallQuery! : queryMessage
            do {
                recalled = try await memory.recall(
                    effectiveRecallQuery,
                    k: turnBudget.recallRowLimit,
                    persona: memoryRecallPersonaFilter(resolvedPersonaID),
                    surface: surface
                )
                trace.setMemoryRecallOutcome(.succeeded(hitCount: recalled.count))
            } catch {
                try Task.checkCancellation()
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
        // A7 (2026-08-28): on a ContextFlow-active turn the memory retrieval
        // does NOT happen in the bracket above — it happens inside the packet
        // selector during `contextFlow.prepare`, and the bracket only counts
        // already-selected atoms. Attribute the selector's own measured
        // latency to this lane so `memory.recall` reports the turn's real
        // retrieval cost instead of a structural zero. On a prepared turn the
        // bracket number is NEVER recorded: with no selector sample the lane
        // stays absent rather than laundering atom-serving time into a
        // fast-recall reading.
        if preparedContextTurn == nil {
            trace.recordMicroseconds(.memoryRecall, since: memoryStartNs)
        } else if let selectionMicros = preparedContextTurn?.packet.receipt
            .measuredSelectionMicroseconds {
            trace.setMicroseconds(.memoryRecall, microseconds: Int64(selectionMicros))
        }
        // Dedup: drop recalls whose text is superseded by a REM pin sharing
        // the same key or whose preview contains the pin's text verbatim.
        // This keeps the context tight — the pin IS the authoritative fact.
        if !remPins.isEmpty {
            recalled = recalled.filter { hit in
                !remPins.contains(where: { pin in
                    !hit.preview.isEmpty
                        && !pin.text.isEmpty
                        && (hit.preview.contains(pin.text) || pin.text.contains(hit.preview))
                })
            }
        }

        // 5. Available tools — surface names + JSON-Schema descriptors so the
        //    LLM can actually emit tool calls. Schema fetch is best-effort:
        //    a dispatcher that only knows names degrades to the pre-W1 wire
        //    path (no `tools` field in the request body).
        let catalog = await FluidContextToolScope.$current.withValue(preparedContextTurn) {
            // These walks are independent but both inherit the exact prepared
            // ContextFlow scope. Preserve each result's established ordering
            // and best-effort empty fallback while overlapping their policy,
            // registry, and MCP reads.
            async let namesResult: (value: [String], elapsedMs: Int64) = {
                let started = DispatchTime.now().uptimeNanoseconds
                let raw = (try? await tools.listAvailableTools()) ?? []
                // The raw inventory still carries the retired mac_* organs.
                // This list is rendered verbatim into the prompt's tool
                // catalog whenever the schema walk comes back empty — a
                // section that then tells the model to tool_load what it
                // names. tool_load resolves against this same set MINUS the
                // four-verb cutover boundary, so leaving them in advertised
                // `mac_look`/`mac_view` and answered `not_in_catalog`. Filter
                // (rather than set-convert) to keep the established ordering.
                let value = raw.filter {
                    !SwiftToolDispatcher.legacyMacModelToolNames.contains($0)
                }
                return (
                    value,
                    Int64((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
                )
            }()
            async let schemasResult: (value: [LLMToolSchema], elapsedMs: Int64, reused: Bool) = {
                let started = DispatchTime.now().uptimeNanoseconds
                if let toolSchemaCatalogSeed {
                    return (toolSchemaCatalogSeed.schemas, 0, true)
                }
                let value = (try? await tools.listAvailableToolSchemas()) ?? []
                return (
                    value,
                    Int64((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000),
                    false
                )
            }()
            return await (namesResult, schemasResult)
        }
        let toolNames = catalog.0.value
        let toolSchemas = catalog.1.value
        trace.setTiming(.toolsNames, milliseconds: catalog.0.elapsedMs)
        trace.setTiming(.toolsSchemas, milliseconds: catalog.1.elapsedMs)
        trace.setFlag("tools.schemasSeedReused", catalog.1.reused)
        // Tool-contract stability instrument (2026-09-01). The advertised
        // catalog is derived here from the same two inputs the lazy filter
        // uses — the turn's schema walk and the session's load order — so two
        // consecutive turns can be PROVEN to carry the same contract instead
        // of being assumed to. A fingerprint that changes without
        // appendedCount changing means something reordered the floor, which
        // is the exact regression this build exists to make visible.
        let contractSession = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contractLoadout = contractSession.isEmpty
            ? nil
            : await activeToolsStore.load(sessionId: contractSession)
        // Mirrors applyLazyToolFilter's admission and ordering, including the
        // catalog-derived Full-Mac resident family, so the instrument measures
        // the contract that actually ships rather than an approximation of it.
        let contractResident = ToolPreloadHeuristics.immediateFullMacTools(
            availableToolNames: Set(toolSchemas.map(\.name))
        ).subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
        let contractPinnedMCP = contractLoadout.map { Set($0.advertisedLoadOrder.filter { $0.hasPrefix("mcp__") }) }
        let advertisedNames = toolSchemas
            .map(\.name)
            .filter { name in
                if name.hasPrefix("mcp__") { return contractPinnedMCP?.contains(name) ?? true }
                if SwiftToolDispatcher.alwaysOnCoreNames.contains(name) { return true }
                if contractResident.contains(name) { return true }
                return contractLoadout?.activeTools.contains(name) ?? true
            }
        let contractLoadOrder = contractResident.sorted()
            + (contractLoadout?.advertisedLoadOrder ?? []).filter { !contractResident.contains($0) }
        let contract = SwiftToolDispatcher.canonicalToolOrder(
            advertisedNames,
            loadOrder: contractLoadOrder
        )
        trace.setCount("tools.floorCount", contract.floor.count)
        trace.setCount("tools.appendedCount", contract.appended.count)
        trace.setCount("tools.droppedCount", contractLoadout?.lastDropped.count ?? 0)
        trace.setLabel("tools.contractFingerprintSHA256", contract.fingerprintSHA256)
        let snapshot = TurnContextSnapshot(
            providerPreferences: prefs,
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
                budget: turnBudget,
                includeNaturalExpressionGuidance: naturalExpressionGuidanceEnabled,
                requiredDocuments: Self.stablePrefixRequiredDocuments(preparedContextTurn),
                sensibilityBlock: sensibilityBlock
            )
        } else {
            rawSegments = Self.renderSystemPromptSegments(
                personaDocs: personaMap,
                recalled: recalled,
                remPins: remPins,
                budget: turnBudget,
                includeNaturalExpressionGuidance: naturalExpressionGuidanceEnabled
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
            resolvedSegments = SystemPromptSegments(
                stable: rawSegments.stable,
                stableSuffix: rawSegments.stableSuffix,
                dynamic: dynamic
            )
        }
        trace.record(.promptRender, since: renderStartNs)
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
        // Pin one clock instant for both the dynamic clock line and the receipt
        // flag. The flag is the active semantic, not mere preference-file
        // availability: an outside-window turn must never look quiet merely
        // because a window happens to be configured.
        let currentTurnClock = clockNowOverride ?? clock()
        let quietHoursActive: Bool = {
            guard let quietHours = quietHoursSnapshot else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return quietHours.contains(hour: calendar.component(.hour, from: currentTurnClock))
        }()
        // The summary is emitted even when a history caller asks this base
        // builder to defer clock rendering, so stamp the same pinned semantic
        // before the branch. The history assembler then owns the one eventual
        // prompt rendering without leaving its base context receipt ambiguous.
        trace.setFlag(
            "clock.quietHoursActive",
            quietHoursActive
        )
        if includeClockContext {
            // Receipt truth: the dynamic prompt gets the quiet-hours marker
            // only on an active turn, and the summary carries that same pinned
            // active state for live-rate observation.
            let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
            finalContext = await contextByAppendingCurrentTurnFacts(
                baseContext,
                clockNowOverride: currentTurnClock,
                quietHours: quietHoursSnapshot,
                sessionID: sessionID
            )
            trace.record(ContextStageName.contextClockRuntime, since: runtimeStartNs)
        } else {
            finalContext = baseContext
        }
        try Task.checkCancellation()
        if contextFlowMode == .active {
            trace.setFlag("contextFlow.active", preparedContextTurn != nil)
        }
        if let contextFlowMemoryAtomCount {
            trace.setMemoryRecallOutcome(.contextFlow(hitCount: contextFlowMemoryAtomCount))
        }
        trace.setCount("snapshot.providerPrefs", snapshot.providerPreferences.count)
        trace.setCount("snapshot.toolNames", snapshot.toolNames.count)
        trace.setCount("snapshot.toolSchemas", snapshot.toolSchemas.count)
        trace.setCount("snapshot.toolSchemaParameterBytes", snapshot.toolSchemaParameterBytes)
        trace.setCount("persona.docCount", personaMap.count)
        trace.setCount("persona.docChars", personaMap.values.reduce(0) { $0 + $1.count })
        trace.setCount("remPins.count", remPins.count)
        // `memory.recallHits` = the memory record identities that actually went
        // INTO this turn: legacy recall hits ∪ ContextFlow packet provenance
        // (TurnContext.resolvedRecalledIds — the same union the recalled-memory
        // stamp and next-turn memoryActivation consume). On `.active` turns the
        // legacy lane is empty BY DESIGN (memory rides the packet), so counting
        // only `recalled` read 0 on 511/511 live turns (2026-08-21) while
        // contextFlow.memoryRecords averaged ~12 — a measurement lie, not a
        // recall outage. The legacy lane keeps its own honest name; on a
        // legacy (non-ContextFlow) turn both lanes read the same value.
        trace.setCount("memory.recallHits", baseContext.resolvedRecalledIds.count)
        trace.setCount("memory.recallHits.legacy", recalled.count)
        trace.setCount("system.stableChars", finalContext.systemSegments?.stable.count ?? 0)
        trace.setCount("system.dynamicChars", finalContext.systemSegments?.dynamic.count ?? 0)
        trace.setCount("system.combinedChars", finalContext.systemPrompt?.count ?? 0)
        trace.setCount("userMessageChars", userMessage.count)
        trace.setCount("imageBlockCount", imageBlocks.count)
        trace.setFlag("snapshot.requestScoped", true)
        trace.emit(kind: "context.summary", surface: surface)
        // Keep the existing asynchronous access writer, admitted only after
        // this context has completed assembly and passed cancellation.
        if !servedContextMemoryIDs.isEmpty, let memory {
            let servedIDs = servedContextMemoryIDs
            Task { await memory.recordServedContextHits(ids: servedIDs) }
        }
        // User, 2026-09-06: the legacy lane's usage credit, moved here from
        // inside recall. The adapter now retrieves WITHOUT crediting, so the
        // rows bumped are the ones this turn actually delivered — after REM-pin
        // dedup above and after the renderer's row limit and block bound. It
        // used to credit everything recall returned, which made a row the model
        // never saw look used, and use_count is what vetoes eviction.
        if !recalled.isEmpty, let memory {
            let deliveredIDs = Self.deliveredRecalledMemoryIDs(recalled, budget: turnBudget)
            if !deliveredIDs.isEmpty {
                Task { await memory.recordServedContextHits(ids: deliveredIDs) }
            }
        }
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
        var residentWorkIntent = false
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
        inputs.residentWorkIntent = signals.residentWorkIntent

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
        for (rawStage, milliseconds) in snapshot.stagesMilliseconds {
            guard let stage = CognitiveAttentionStage(rawValue: rawStage) else { continue }
            trace.setTiming(stage.contextStage, milliseconds: milliseconds)
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

    /// How ONE packet atom renders: whole, or lead + pointer.
    ///
    /// User's rule, and the reason this exists: give her the RULE, not the
    /// story. A 400-char atom IS the rule and ships whole. A 1,500-char
    /// correction is a rule wrapped in the incident that produced it, and the
    /// incident is one `context_expand` away instead of permanent prompt mass
    /// on every turn (NORTHSTAR clause 6 — reach, not weight).
    ///
    /// The lead is the atom's own `summary` (the `summary` column of
    /// `context_atom_versions`, carried on the packet item) when it has one,
    /// because that is the compiler's considered one-liner. Otherwise it is the
    /// atom's own first sentence(s) up to `packetAtomLeadChars`, cut at a
    /// sentence boundary — never mid-sentence, because a half-sentence rule
    /// reads as a whole one and is worse than no rule.
    ///
    /// Truncation is not loss: `ContextSelector.makePacket` publishes an
    /// expandable pointer for exactly the atoms this predicate truncates, so
    /// every cut body is retrievable for this turn and generation.
    ///
    /// `thresholdChars` comes from the TURN (`prepared.need`), not from a
    /// second reading of the policy: the selector used that exact number to
    /// decide which pointers to publish, so reading it anywhere else is how a
    /// renderer and a selector start disagreeing about what is reachable. `0`
    /// renders every atom whole — byte-identical to before this existed.
    ///
    /// A MEMORY atom additionally leads with how old it is and closes with where
    /// it came from (`ContextMemoryLead`): "(yesterday) … [told by Claude]".
    /// Render-lane only — the atom, its hash and the selector's decisions are
    /// untouched. The age comes from `clock`, which carries the TURN's frozen
    /// evaluation time and an explicit calendar; the default `.unstamped` clock
    /// renders no age at all, because a renderer with no turn behind it has no
    /// business reading a wall clock and calling the answer "yesterday".
    nonisolated static func renderPacketAtom(
        _ item: ContextPacketItem,
        thresholdChars: Int,
        clock: ContextRenderClock = .unstamped
    ) -> String {
        let kind = item.pointer.kind.rawValue
        let text = item.text
        /// `- [kind] (age) body [provenance] <expand marker>`
        func line(_ body: String, marker: String? = nil) -> String {
            let decorated = ContextMemoryLead.decorate(body, item: item, clock: clock)
            guard let marker else { return "- [\(kind)] \(decorated)" }
            return decorated.isEmpty
                ? "- [\(kind)] \(marker)"
                : "- [\(kind)] \(decorated) \(marker)"
        }
        guard thresholdChars > 0, text.count > thresholdChars else {
            return line(text)
        }
        let lead = packetAtomLead(item)
        // A "lead" that saved nothing is not a lead. Fall back to the whole
        // body rather than paying for a pointer that buys no room.
        guard lead.count < text.count else { return line(text) }
        // Nothing safe to say (one unbroken token). The pointer alone is honest;
        // a truncated URL is not.
        guard !lead.isEmpty else {
            return line(
                "",
                marker: "[context_expand \(item.pointer.atomID.rawValue) — \(text.count) chars]"
            )
        }
        return line(
            "\(lead) …",
            marker: "[context_expand \(item.pointer.atomID.rawValue) — "
                + "\(text.count - lead.count) more chars]"
        )
    }

    /// The lead half of `renderPacketAtom`. Deterministic: same item, same
    /// bytes, every turn and every surface.
    ///
    /// The summary is a PREFERRED source for the lead, not an exemption from
    /// its bound. `deterministicSummary` is compiler output with its own
    /// (byte-based) cap, so a summary can exceed `packetAtomLeadChars` — and a
    /// lead that quietly ran long made `contextFlow.leadChars` a number that
    /// under-reported the prompt it was measuring. Both sources go through one
    /// bounding routine, so the trace count means what it says.
    nonisolated static func packetAtomLead(_ item: ContextPacketItem) -> String {
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (summary?.isEmpty == false) ? summary! : item.text
        return firstSentences(
            of: source,
            upTo: ContextBudgetPolicy.packetAtomLeadChars
        )
    }

    /// First sentence(s) of `text` that fit in `limit` characters, cut at a
    /// SAFE sentence boundary.
    ///
    /// "Safe" rules out the two cuts that produce text meaning something other
    /// than the original said:
    ///
    ///   - inside an inline code span — cutting between backticks leaves the
    ///     span unclosed, so the rest of the packet reads as code;
    ///   - inside a URL — `https://ex.com/a. b` has a terminator followed by a
    ///     space, and cutting there hands the model a link that resolves
    ///     somewhere else, or nowhere.
    ///
    /// Fallback order is first safe sentence(s) → first safe whole words → no
    /// lead at all. The last case is deliberate: when the opening `limit`
    /// characters are one unbroken token (a long URL, a base64 blob) there is
    /// nothing honest to lead with, and `renderPacketAtom` emits the pointer
    /// alone rather than a mangled prefix.
    nonisolated static func firstSentences(of text: String, upTo limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        guard trimmed.count > limit else { return trimmed }
        let window = String(trimmed.prefix(limit))

        var lastSentenceBoundary: String.Index?
        var lastSafeWhitespace: String.Index?
        var insideCodeSpan = false
        var tokenStart = window.startIndex
        var index = window.startIndex
        while index < window.endIndex {
            let character = window[index]
            let next = window.index(after: index)
            if character == "`" {
                insideCodeSpan.toggle()
            } else if character.isWhitespace {
                if !insideCodeSpan { lastSafeWhitespace = index }
                tokenStart = next
            } else if character == "." || character == "!" || character == "?" {
                let endsToken = next == window.endIndex || window[next].isWhitespace
                // A scheme anywhere in the token this terminator closes means
                // the terminator is punctuation the URL may own.
                let tokenIsURL = window[tokenStart..<next].contains("://")
                if endsToken, !insideCodeSpan, !tokenIsURL {
                    lastSentenceBoundary = next
                }
            }
            index = next
        }

        if let lastSentenceBoundary {
            let sentence = String(window[window.startIndex..<lastSentenceBoundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { return sentence }
        }
        if let lastSafeWhitespace {
            let words = String(window[window.startIndex..<lastSafeWhitespace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { return words }
        }
        return ""
    }

    /// Packet-truncation receipt counts, computed from the packet the model
    /// actually received. `expandableAfterTruncation` is the honest one: it
    /// counts truncated atoms that DO carry a published pointer, so a
    /// truncation that lost its way to `context_expand` reads as a gap rather
    /// than disappearing into the truncated count.
    nonisolated static func packetTruncationCounts(
        _ prepared: ContextPreparedTurn
    ) -> (truncatedAtoms: Int, leadChars: Int, expandableAfterTruncation: Int) {
        let packet = prepared.packet
        let thresholdChars = prepared.need.packetAtomExpandThresholdChars
        guard thresholdChars > 0 else { return (0, 0, 0) }
        let pointerIDs = Set(packet.expandablePointers.map(\.atomID))
        var truncatedAtoms = 0
        var leadChars = 0
        var expandable = 0
        for item in packet.selectedItems where item.text.count > thresholdChars {
            let lead = packetAtomLead(item)
            guard lead.count < item.text.count else { continue }
            truncatedAtoms += 1
            leadChars += lead.count
            if pointerIDs.contains(item.pointer.atomID) { expandable += 1 }
        }
        return (truncatedAtoms, leadChars, expandable)
    }

    nonisolated public static func renderContextPacket(_ prepared: ContextPreparedTurn) -> String {
        var sections: [String] = []
        if !prepared.packet.selectedItems.isEmpty {
            let thresholdChars = prepared.need.packetAtomExpandThresholdChars
            // ONE clock for the whole packet: the turn's own frozen evaluation
            // time, in the user's local zone captured once here. Two memories
            // rendered either side of local midnight must agree on "yesterday".
            let clock = ContextRenderClock.turn(prepared.need)
            let items = prepared.packet.selectedItems
                .map { renderPacketAtom($0, thresholdChars: thresholdChars, clock: clock) }
                .joined(separator: "\n")
            sections.append(
                """
                # Relevant context (derived from canonical local sources)
                These records preserve evidence from when they were written; they are not automatically live readings. Recheck changing status, counts, health, availability, and claims labeled current/latest/live/present with their canonical owner before repeating them as current.
                \(items)
                """
            )
        }
        // A truncated atom already carries its own `[context_expand <id> — N
        // more chars]` marker on the line the model is reading, so re-listing
        // it here would spend a second line to say the same thing. This section
        // stays what it was: the atoms that are NOT in the packet at all.
        let selectedIDs = Set(prepared.packet.selectedItems.map(\.pointer.atomID))
        let lazyPointers = prepared.packet.expandablePointers.filter {
            !selectedIDs.contains($0.atomID)
        }
        if !lazyPointers.isEmpty {
            let pointerLines: String = lazyPointers.map { pointer in
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
        toolDispatches: [TurnEngineResult.ToolDispatchRecord] = [],
        sessionId: String?,
        surface: String = "chat"
    ) async {
        let startNs = DispatchTime.now().uptimeNanoseconds
        guard let memoryPromoter else {
            ContextStageTrace.emitStage(
                name: .memoryPromotion,
                elapsedMs: Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
                surface: surface,
                counts: [
                    "userMessageChars": Int64(userMessage.count),
                    "assistantMessageChars": Int64(assistantMessage.count),
                    "stagedProposalCount": 0,
                ],
                flags: [
                    "configured": false,
                    "outcomeReported": false,
                ]
            )
            return
        }
        let toolEvidence = TurnToolEvidenceProjection.project(toolDispatches)
        let promotionTelemetry: MemoryPromotionTelemetry?
        if let reportingPromoter = memoryPromoter as? any MemoryPromotionTelemetryReporting {
            promotionTelemetry = await reportingPromoter.observeTurnWithTelemetry(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                toolEvidence: toolEvidence,
                sessionId: sessionId ?? "swift-turn-engine",
                surface: surface
            )
        } else {
            await memoryPromoter.observeTurn(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                toolEvidence: toolEvidence,
                sessionId: sessionId ?? "swift-turn-engine"
            )
            promotionTelemetry = nil
        }
        ContextStageTrace.emitStage(
            name: .memoryPromotion,
            elapsedMs: Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            surface: surface,
            counts: [
                "userMessageChars": Int64(userMessage.count),
                "assistantMessageChars": Int64(assistantMessage.count),
                "stagedProposalCount": promotionTelemetry?.stagedProposalCount ?? 0,
                "extractedCandidateCount": promotionTelemetry?.candidateCount ?? 0,
                "semanticCandidateCount": promotionTelemetry?.semanticCandidateCount ?? 0,
                "toolEvidenceLineCount": Int64(toolEvidence.count),
                "toolDispatchCount": Int64(toolDispatches.count),
            ],
            flags: [
                "configured": true,
                "outcomeReported": promotionTelemetry != nil,
            ],
            labels: [
                "semanticExtraction": promotionTelemetry?.semanticStatus.rawValue ?? "unreported",
                "momentOutcome": promotionTelemetry?.momentOutcome ?? "unreported",
            ]
        )
    }

    func contextByAppendingCurrentTurnFacts(
        _ context: TurnContext,
        clockNowOverride: Date? = nil,
        quietHours: TurnQuietHoursWindow?,
        sessionID: String? = nil
    ) async -> TurnContext {
        // clockNowOverride (turn-context-iteration-cache follow-up,
        // 2026-08-13): the clock line renders into the DYNAMIC system
        // segment, and a multi-iteration tool turn that crosses a minute
        // boundary re-renders it differently mid-turn — byte-diff-proven
        // prompt-cache bust (run2 body3→4: "5:59 PM"→"6:00 PM" was the ONLY
        // changed byte). A tool loop passes its turn-start instant on every
        // iteration so the turn reads as one moment; nil = per-build clock()
        // (single-shot turns, unchanged).
        let withClock = Self.contextByAppendingClockContext(
            context, now: clockNowOverride ?? clock(), quietHours: quietHours)
        let withMoments = await contextByAppendingMomentNudge(
            withClock,
            sessionID: sessionID
        )
        guard let runtimeContext = await renderRuntimeContext(
            surface: withMoments.surface,
            modelId: withMoments.modelId,
            providerId: withMoments.providerId
        ) else {
            return withMoments
        }
        return Self.contextByAppendingRuntimeContext(withMoments, runtimeContext: runtimeContext)
    }

    // MARK: - The moments nudge (2026-09-02)
    //
    // ONE line, and only when moments are actually waiting:
    //
    //     Moments waiting for your review: 3 — memory_moments_pending
    //
    // It rides the DYNAMIC segment, which `splittingVolatileBlock()` lifts out
    // of the system prompt into the turn-scoped message — never the cached
    // prefix. A count that changes is a cache bust wherever it sits, so the
    // line is re-rendered only when the number MOVED since this session's last
    // turn, or once every `momentNudgeRefreshTurns` turns as a floor (so a
    // steady queue is still visible after a long stretch). Between those, the
    // line is simply absent, which is the cheapest thing it can be.
    //
    // The read is a count over her own pending proposals — no moment text
    // enters the prompt here, ever. She pulls the rows herself.

    /// Re-assert an unchanged count at most this rarely.
    static let momentNudgeRefreshTurns = 10
    /// Bound on the per-session churn map. Two Ints per session is nothing, but
    /// an unbounded map keyed by session id is still a leak; the oldest keys are
    /// dropped and their next turn simply renders the line once.
    static let momentNudgeSessionCap = 64

    func contextByAppendingMomentNudge(
        _ context: TurnContext,
        sessionID: String?
    ) async -> TurnContext {
        guard let reporter = memoryPromoter as? any MomentReviewQueueReporting else {
            return context
        }
        let count = await reporter.pendingMomentCount()
        let key = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = (key?.isEmpty == false) ? key! : "swift-turn-engine"
        var state = momentNudgeState[sessionKey] ?? (lastCount: -1, turnsSinceRender: Self.momentNudgeRefreshTurns)
        let changed = state.lastCount != count
        let due = state.turnsSinceRender >= Self.momentNudgeRefreshTurns
        state.lastCount = count
        state.turnsSinceRender = (changed || due) ? 0 : state.turnsSinceRender + 1
        momentNudgeState[sessionKey] = state
        if momentNudgeState.count > Self.momentNudgeSessionCap {
            for key in momentNudgeState.keys.sorted().prefix(
                momentNudgeState.count - Self.momentNudgeSessionCap
            ) where key != sessionKey {
                momentNudgeState.removeValue(forKey: key)
            }
        }
        guard count > 0, changed || due else { return context }
        return Self.contextByAppendingRuntimeContext(
            context,
            runtimeContext: "Moments waiting for your review: \(count) — memory_moments_pending"
        )
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
    /// The recalled rows this block ACTUALLY carries into the prompt, each with
    /// the line it renders as.
    ///
    /// User, 2026-09-06: split out of the renderer, unchanged, so the turn engine
    /// can credit `use_count` for exactly what was delivered. The legacy lane
    /// used to credit everything recall RETURNED — before REM-pin dedup and
    /// before this trim — so rows the model never saw looked used, and use_count
    /// is the signal that vetoes eviction.
    nonisolated static func deliveredRecalledMemoryRows(
        _ recalled: [MemoryRecallHit],
        budget: ContextBudgetPolicy.Resolved? = nil
    ) -> [(hit: MemoryRecallHit, line: String)] {
        guard !recalled.isEmpty else { return [] }
        let resolved = budget ?? ContextBudgetPolicy.resolve(
            windowTokens: nil, surface: "chat"
        )
        var used = 0
        var rows: [(hit: MemoryRecallHit, line: String)] = []
        // B11: filter empties BEFORE taking the row limit. A hit with no text
        // used to occupy one of the (few) recall slots inside the prefix window
        // and then render nothing, silently costing a real memory its place.
        let renderable = recalled.lazy.filter {
            !($0.content ?? $0.preview)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for hit in renderable.prefix(resolved.recallRowLimit) {
            let full = (hit.content ?? hit.preview)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
            if resolved.isDerived, !rows.isEmpty,
               used + line.count > resolved.memoryBlockChars { break }
            used += line.count
            rows.append((hit: hit, line: line))
        }
        return rows
    }

    /// The memory record ids behind `deliveredRecalledMemoryRows`. Hits carry
    /// their record id under `extras.id` (see MemoryV2+Wiring's recall).
    nonisolated static func deliveredRecalledMemoryIDs(
        _ recalled: [MemoryRecallHit],
        budget: ContextBudgetPolicy.Resolved? = nil
    ) -> [String] {
        deliveredRecalledMemoryRows(recalled, budget: budget).compactMap { row in
            guard case .object(let extras)? = row.hit.extras,
                  case .string(let id)? = extras["id"] else { return nil }
            return id
        }
    }

    nonisolated static func renderRecalledMemoryBlock(
        _ recalled: [MemoryRecallHit],
        budget: ContextBudgetPolicy.Resolved? = nil
    ) -> String? {
        let rows = deliveredRecalledMemoryRows(recalled, budget: budget)
        var relatedNames: [String] = []
        // B4: collect the graph neighbours of the rows we ACTUALLY render.
        // Gathering them here rather than from `recalled` keeps the line
        // honest — a memory dropped by the row limit or the block bound
        // contributes no entities either.
        for row in rows {
            if case .object(let extras)? = row.hit.extras,
               case .array(let names)? = extras["kg_related"] {
                for value in names {
                    guard case .string(let name) = value else { continue }
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !relatedNames.contains(trimmed) else { continue }
                    relatedNames.append(trimmed)
                }
            }
        }
        guard !rows.isEmpty else { return nil }
        let block = "Relevant memory:\n" + rows.map(\.line).joined(separator: "\n")
        guard let related = renderRelatedEntitiesLine(relatedNames) else { return block }
        return block + "\n" + related
    }

    /// Hard ceiling on the `related:` line. One line, one turn, 400 characters —
    /// the whole point of the feature is a cheap hint about what the recalled
    /// memories connect to, and a hint that can grow without bound is just an
    /// unbudgeted second memory block.
    nonisolated static let relatedEntitiesLineChars = 400

    /// Render the single `related:` line, or nil when there is nothing to say.
    ///
    /// Names are appended whole: a truncated entity name is worse than a missing
    /// one, because the model cannot tell "Agent" from "Agent's Telegram bridge"
    /// cut at the apostrophe. The loop therefore stops at the last name that
    /// fits rather than clipping mid-name. Inputs arrive recency-first, so what
    /// survives the cap is the freshest end of the list.
    nonisolated static func renderRelatedEntitiesLine(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let prefix = "related: "
        var line = prefix
        for name in names {
            let separator = line == prefix ? "" : ", "
            guard line.count + separator.count + name.count <= relatedEntitiesLineChars
            else { break }
            line += separator + name
        }
        return line == prefix ? nil : line
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
        budget: ContextBudgetPolicy.Resolved? = nil,
        includeNaturalExpressionGuidance: Bool = true
    ) -> SystemPromptSegments {
        var stableLines: [String] = []
        if !personaDocs.isEmpty {
            let ids = personaDocs.keys.sorted()
            let concatenated = ids
                .map { "## \($0)\n\(personaDocs[$0] ?? "")" }
                .joined(separator: "\n\n")
            stableLines.append("You are the persona described by these documents:\n\(concatenated)")
        } else {
            stableLines.append("You are a helpful assistant.")
        }
        if includeNaturalExpressionGuidance {
            stableLines.append(NaturalExpressionGuidance.baseline)
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
            stable: stableLines.joined(separator: "\n\n"),
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
    /// The persona's required documents that belong in the STABLE prefix but
    /// are NOT already inside the compiled kernel.
    ///
    /// In `.active` ContextFlow the kernel is SOUL + VOICE + surface guidance
    /// (~4.6 KB); USER/GROWTH/MEMORY/AGENTS (~17 KB more) were left to the
    /// ranked packet, which re-sent them in the VOLATILE block on every turn —
    /// full price, no prompt cache, on bytes that had not changed in weeks.
    /// They are identity, not relevance: their home is the cached prefix.
    ///
    /// SURFACE PERMISSION IS THE GATE, and this is an ALLOW map, not a deny
    /// list. A document reaches the cached stable prefix only when it proves
    /// two things about itself: it knows which context source it came from, and
    /// that source permits THIS turn's surface. Everything else — unknown
    /// provenance, a source that denies the surface — is absent.
    ///
    /// Why the direction matters. The earlier shape subtracted documents whose
    /// source could be found AND was found to deny the surface, which meant a
    /// missing source or a drifted locator convention read as "no denial
    /// observed" and the document shipped. That is a permission check that
    /// fails OPEN: the one direction a permission check must never fail. Now a
    /// document with no provenance is simply unavailable to the prefix. It is
    /// not lost — it falls back to the packet, which applies the same surface
    /// rule (`ContextSelection.eligibilityReason` → `.surfaceDenied`) — but
    /// when the packet refuses it too, the document is genuinely absent from
    /// the turn, and that MUST be loud. `unprovenDocumentIDs` names every such
    /// document so the trace can say which one and why.
    ///
    /// Deterministic by construction: `mirror.documents` is stored in canonical
    /// order and the `.active` kernel's included set is the same on every
    /// surface, so the rendered bytes are identical across turns, and identical
    /// across surfaces EXCEPT where a document's own source is
    /// surface-restricted. That exception is the only legitimate reason two
    /// surfaces' stable prefixes may differ; anything else diverging is a
    /// caching bug.
    struct StablePrefixPersonaDocuments {
        let included: [RequiredDocument]
        /// Documents withheld because they could not PROVE a surface
        /// permission, as distinct from documents whose source answered "no".
        /// A non-empty value is a build/wiring fault, not a policy outcome.
        let unprovenDocumentIDs: [RequiredDocumentID]
    }

    nonisolated static func stablePrefixPersonaDocuments(
        _ prepared: ContextPreparedTurn?
    ) -> StablePrefixPersonaDocuments {
        guard let prepared else { return .init(included: [], unprovenDocumentIDs: []) }
        let inKernel = Set(prepared.kernel.includedDocumentIDs)
        let surface = prepared.need.surface
        var included: [RequiredDocument] = []
        var unproven: [RequiredDocumentID] = []
        for document in prepared.mirror.documents where !inKernel.contains(document.id) {
            guard document.hasSurfaceProvenance else {
                unproven.append(document.id)
                continue
            }
            guard document.permitsStablePrefix(on: surface) else { continue }
            included.append(document)
        }
        return .init(included: included, unprovenDocumentIDs: unproven)
    }

    nonisolated static func stablePrefixRequiredDocuments(
        _ prepared: ContextPreparedTurn?
    ) -> [RequiredDocument] {
        stablePrefixPersonaDocuments(prepared).included
    }

    /// Render the required-document mirrors for the stable prefix.
    ///
    /// The heading form is the kernel's own (`# SOUL\n<text>`), so the persona
    /// reads as one continuous document set rather than two conventions
    /// stitched together. Byte-stability is the whole point: nothing turn-,
    /// clock- or surface-derived may enter this string.
    nonisolated static func renderRequiredDocumentBlock(
        _ documents: [RequiredDocument]
    ) -> String? {
        guard !documents.isEmpty else { return nil }
        return documents
            .map { "# \(String($0.id.rawValue.dropLast(3)))\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    nonisolated static func renderSystemPromptSegments(
        compiledPersonaPrompt: String,
        recalled: [MemoryRecallHit],
        remPins: [REMPin],
        budget: ContextBudgetPolicy.Resolved? = nil,
        includeNaturalExpressionGuidance: Bool = true,
        requiredDocuments: [RequiredDocument] = [],
        sensibilityBlock: String? = nil
    ) -> SystemPromptSegments {
        var stableLines: [String] = []
        let body = compiledPersonaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            stableLines.append(body)
        } else {
            stableLines.append("You are a helpful assistant.")
        }
        // Immediately after the kernel: the rest of the persona is persona, and
        // the cache boundary belongs after ALL of it.
        if let documentBlock = renderRequiredDocumentBlock(requiredDocuments) {
            stableLines.append(documentBlock)
        }
        if includeNaturalExpressionGuidance {
            stableLines.append(NaturalExpressionGuidance.baseline)
        }
        // Fix 6: pins rendered FIRST, under a dedicated authority header.
        if !remPins.isEmpty {
            let bullets = remPins.map { "- \($0.text)" }.joined(separator: "\n")
            stableLines.append("# Pinned facts (REM-approved overrides)\n\(bullets)")
        }
        // Personality-depth item 10 — SENSIBILITY, after the pins.
        //
        // Two or three lines she wrote herself about what she has come to care
        // about in work, from `data/studio/canon/sensibility.md`. It belongs in
        // the STABLE segment and nowhere else: it changes only when the canon
        // moves and she decides to restate it, which is weeks or months apart,
        // so it is cached prefix bytes rather than per-turn cost.
        //
        // Byte-stable by construction — the block carries no stamp, no count and
        // no work names, and is bounded at 400 characters on a line boundary by
        // `StudioSensibility.renderStableBlock`. Absent when empty, which is the
        // ordinary state before she has ever written one.
        if let sensibility = sensibilityBlock?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sensibility.isEmpty {
            stableLines.append(sensibility)
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
        localTimeZone: TimeZone = .current,
        quietHours: TurnQuietHoursWindow? = nil
    ) -> SystemPromptSegments {
        let clockContext = renderClockContext(
            now: now, localTimeZone: localTimeZone, quietHours: quietHours)
        guard !clockContext.isEmpty else { return segments }
        let dynamic = segments.dynamic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? clockContext
            : segments.dynamic + "\n\n" + clockContext
        return SystemPromptSegments(
            stable: segments.stable, stableSuffix: segments.stableSuffix, dynamic: dynamic
        )
    }

    nonisolated static func contextByAppendingClockContext(
        _ context: TurnContext,
        now: Date,
        localTimeZone: TimeZone = .current,
        quietHours: TurnQuietHoursWindow? = nil
    ) -> TurnContext {
        let clockContext = renderClockContext(
            now: now, localTimeZone: localTimeZone, quietHours: quietHours)
        guard !clockContext.isEmpty else { return context }

        let segments: SystemPromptSegments?
        let systemPrompt: String?
        if let existingSegments = context.systemSegments {
            segments = segmentsByAppendingClockContext(
                existingSegments,
                now: now,
                localTimeZone: localTimeZone,
                quietHours: quietHours
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
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: context.naturalExpressionCue,
            historyMessages: context.historyMessages,
            turnVolatileBlock: context.turnVolatileBlock,
            historyWindowReceipt: context.historyWindowReceipt
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
            segments = SystemPromptSegments(
                stable: existingSegments.stable,
                stableSuffix: existingSegments.stableSuffix,
                dynamic: dynamic
            )
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
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: context.naturalExpressionCue,
            historyMessages: context.historyMessages,
            turnVolatileBlock: context.turnVolatileBlock,
            historyWindowReceipt: context.historyWindowReceipt
        )
    }

    /// ONE line, human wall-clock, in the DYNAMIC segment (it changes every
    /// turn — putting it in the stable segment would churn the cache prefix).
    ///
    /// W5 L1#6 "time as a fact": the old rendering was machine-shaped
    /// (`Wed 2026-06-17 04:31 PDT`) and the model kept mis-reading it —
    /// calling 9:29 AM "afternoon", inferring sleep from a bare number.
    /// Weekday name + 12-hour clock with AM/PM is the format a human states
    /// time in, and the quiet-hours window (when configured) replaces the
    /// sleep INFERENCE with a stated fact.
    nonisolated static func renderClockContext(
        now: Date,
        localTimeZone: TimeZone = .current,
        centralTimeZone: TimeZone = TimeZone(identifier: "America/Chicago") ?? TimeZone(secondsFromGMT: -6 * 60 * 60)!,
        quietHours: TurnQuietHoursWindow? = nil
    ) -> String {
        let local = formatClockDate(now, timeZone: localTimeZone)
        var line = "Local time: \(local) (\(localTimeZone.identifier))."
        if localTimeZone.identifier != centralTimeZone.identifier {
            let central = formatClockDate(now, timeZone: centralTimeZone)
            line += " Central: \(central) (\(centralTimeZone.identifier))."
        }
        if let quietHours {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = localTimeZone
            let hour = calendar.component(.hour, from: now)
            if quietHours.contains(hour: hour) {
                line += " Quiet hours: \(formatHour(quietHours.startHour))–\(formatHour(quietHours.endHour)) local."
            }
        }
        return line
    }

    nonisolated static func renderRuntimeContext(
        surface: String,
        provider: String,
        model: String
    ) -> String {
        "Current runtime: surface=\(surface); provider=\(provider); model=\(model). If asked what model or provider you are using, answer from Current runtime; do not guess."
    }

    /// "Tuesday, August 11, 2026 at 9:29 AM CDT" — weekday and AM/PM spelled
    /// out so the time-of-day word never has to be inferred from a 24h number.
    private nonisolated static func formatClockDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return formatter.string(from: date)
    }

    private nonisolated static func formatHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        let suffix = normalized < 12 ? "AM" : "PM"
        let display = normalized % 12 == 0 ? 12 : normalized % 12
        return "\(display):00 \(suffix)"
    }
}
