import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter

// MARK: - Phase B: streaming turn engine
//
// CARVES (intentional, documented):
//   * This low-level engine only streams one provider turn and is text-only.
//     Providers that safely support structured streaming use
//     ChatOrchestrationClient.chatStream's structured tool loop instead.
//     Anthropic OAuth Mac chat keeps this path as a compatibility transport
//     because sending provider `tools[]` changes Claude subscription billing
//     behavior.
//   * Session-history threading is prompt-context only.

// MARK: - TurnStreamEvent

public enum TurnStreamEvent: Sendable {
    case delta(String)
    case toolUse(name: String, input: JSONValue)
    case toolResult(name: String, output: JSONValue)
    /// In-turn user-visible status line (2026-06-09, the user: "if she freezes like
    /// that it should let me know not just hang"). Emitted mid-dispatch by
    /// long-running tools (invoke_claude start/heartbeat/timeout) via
    /// ToolNoticeBus. Surfaces render it as a live status; it is NEVER part
    /// of the durable reply. Consumers that don't care can ignore it.
    case notice(kind: String, text: String)
    case final(TurnEngineResult)
    case error(String)
}

/// Task-local bridge that lets a deep tool implementation (e.g. the
/// invoke_claude subprocess handler) push user-visible progress notices into
/// the CURRENT turn's stream without threading a callback through every
/// dispatcher wrapper (security gate, file gate, bridge deny, ...). The tool
/// loop binds `emit` to the turn's `progress` callback around each dispatch;
/// the value propagates down the structured-concurrency task tree. Emission is
/// best-effort by construction — when unset (background loops, tests) it's nil
/// and tools just don't emit.
public enum ToolNoticeBus {
    @TaskLocal public static var emit: (@Sendable (String, String) async -> Void)?
}

// MARK: - StreamingLLMClient
//
// Protocol moved to NativeAgentCore alongside LLMClient so the real
// ProviderRouting.SwiftNativeLLMClient can declare conformance without
// inverting the dep chain. This file keeps the higher-level surfaces
// (TurnStreamEvent, MockStreamingLLMClient, streamTurn) that consume it.

// MARK: - MessagesStreamingLLMClient (U1 item 9)
//
// Capability marker for streaming clients that can ALSO stream a structured
// [LLMMessage] conversation (live SSE deltas over a messages-shaped body).
// The Anthropic text-compat loop uses this to send an APPEND-ONLY
// conversation per iteration instead of one ever-growing user message — the
// signature matches LLMClient.streamMessages exactly, so the production
// client conforms with an empty extension. Mocks that stay prompt-only
// (MockStreamingLLMClient) intentionally do NOT conform: callers must treat
// absence as "legacy prompt transport only".
public protocol MessagesStreamingLLMClient: StreamingLLMClient {
    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>
}

// SwiftNativeLLMClient already implements the exact method via LLMClient;
// the conformance just surfaces the capability to ChatOrchestration.
extension SwiftNativeLLMClient: MessagesStreamingLLMClient {}

// MARK: - MockStreamingLLMClient

/// Scripted-chunk mock. Yields `chunks` in order. If `errorAfter` is non-nil,
/// after that many chunks have been yielded the stream throws `scripted`.
public final class MockStreamingLLMClient: StreamingLLMClient, @unchecked Sendable {
    public enum MockStreamError: Error, Equatable { case scripted }

    private let chunks: [String]
    private let errorAfter: Int?
    private let lock = NSLock()
    private var _callCount: Int = 0
    private var _lastPrompt: String?
    private var _lastSystem: String?
    private var _lastModel: String?

    public init(chunks: [String], errorAfter: Int? = nil) {
        self.chunks = chunks
        self.errorAfter = errorAfter
    }

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    public var lastPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastPrompt
    }

    public var lastModel: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastModel
    }

    public var lastSystem: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastSystem
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        _callCount += 1
        _lastPrompt = prompt
        _lastSystem = system
        _lastModel = model
        lock.unlock()

        let chunks = self.chunks
        let errorAfter = self.errorAfter
        return AsyncThrowingStream { continuation in
            Task {
                for (i, c) in chunks.enumerated() {
                    if let ea = errorAfter, i >= ea {
                        continuation.finish(throwing: MockStreamError.scripted)
                        return
                    }
                    continuation.yield(c)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - SwiftNativeTurnEngine.streamTurn

extension SwiftNativeTurnEngine {
    /// Tripwire row for the streaming legacy prompt lane: image attachments hit
    /// a transport with no image channel and were dropped. Mirrors the
    /// `vision.attachment_unsupported` shape emitted at the default-flatten
    /// chokepoint (LLMClient+Real.swift). Non-fatal: stderr on failure.
    static func emitVisionUnsupportedTrace(
        imageCount: Int,
        surface: String,
        model: String,
        turnTraceBus: TurnTraceBus
    ) async {
        TurnTraceBus.fireFromContext(
            kind: "vision.attachment_unsupported",
            surface: surface,
            payload: .object([
                "model": .string(model),
                "transport": .string("stream_prompt"),
                "imageCount": .int(Int64(imageCount)),
            ]),
            on: turnTraceBus
        )
    }

    /// Stream a single turn. Yields .delta as chunks arrive from `streamingLLM`,
    /// accumulates them into the full reply, and ends with a single .final
    /// (or a single .error followed by stream completion).
    ///
    /// Tool-marker parsing/dispatch is intentionally not inside this low-level
    /// call. Callers that need compatibility text streaming parse markers at
    /// the orchestration layer between provider turns.
    public nonisolated func streamTurn(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        streamingLLM: any StreamingLLMClient,
        // Wave 16 fix-up (2026-06-01): accept injection so scoped test
        // clients with a tempRoot SessionHistoryReader / non-default
        // historyLimit thread their state through streaming the way they
        // already do for non-streaming chat(). Defaults preserve the
        // pre-fix-up production behavior (chat() in ChatOrchestrationClient
        // passes the injected reader/limit explicitly from runStream).
        historyLimit: Int = 40,
        historyReader: SessionHistoryReader = SessionHistoryReader(),
        // 2026-06-02 persona fix: forward UserDefaults["chatPersona"] into
        // the compiled persona packet so streaming respects the picked
        // persona. nil → no override (legacy callers unaffected).
        personaOverride: String? = nil,
        // Eval fix (2026-06-03): when non-nil/non-empty, override the
        // model resolved by buildTurnContext (which otherwise re-reads
        // providers/surfaces.json and ignores the Mac UI's picker).
        modelOverride: String? = nil,
        // Match the structured chat path: a nonblank caller selection wins,
        // while nil/blank preserves the per-surface preference from context.
        reasoningEffortOverride: String? = nil,
        // Current live run id. When chatStream() has already persisted the user
        // row, excluding this run keeps that row/tool rows out of prior history.
        excludeHistoryRunId: String? = nil,
        // Eval fix (2026-06-03): when set, periodically poll for
        // `<cancelFlagPath>` existence and finish the stream with a
        // cancellation note. Defaults to nil so test callers see no change.
        cancelFlagPath: URL? = nil,
        cancelCheckEveryN: Int = 8,
        // Anthropic OAuth compatibility mode cannot send provider-native
        // `tools[]`, but it can still expose Swift tools through an in-band
        // marker contract parsed by ChatOrchestrationClient.
        textToolCompatibility: Bool = false,
        // U1 item 9: append-only messages transport for the text-compat
        // loop. When non-nil AND `streamingLLM` is messages-capable
        // (MessagesStreamingLLMClient), the provider call sends THIS
        // conversation (grown append-only across loop iterations by the
        // caller) with live SSE deltas, instead of the single `userMessage`
        // prompt. `userMessage` is still used for context building (memory
        // recall + history threading). tools stay nil on this transport —
        // the text-compat marker contract is unchanged. nil → exact legacy
        // prompt path, byte-for-byte.
        conversation: [LLMMessage]? = nil,
        turnPlan: TurnPlan? = nil,
        runtimeContext: String? = nil,
        // MEMORY-SAFETY (2026-07-04): the per-turn active-tools set is passed
        // EXPLICITLY and bound INSIDE this function's Task (below) rather than
        // by a SYNC `LLMCallContext.$turnActiveTools.withValue { … }` wrapped
        // around the caller's `engine.streamTurn(...)` call. That old shape
        // pushed the task-local on the CALLER's task and popped it the instant
        // the sync withValue returned (after merely constructing the stream),
        // while this function's spawned child Task had inherited a reference
        // into that storage → task-allocator LIFO violation ("freed pointer was
        // not the last allocation" / swift_task_dealloc_specific), the
        // deterministic release crash on first chat. nil preserves prior
        // behavior for callers that don't thread an active-tools set.
        providerIDOverride: String? = nil,
        turnActiveTools: Set<String>? = nil,
        // turn-context-iteration-cache (2026-08-13): when non-nil, the lazy
        // tool filter uses THIS set instead of re-reading ActiveToolsStore —
        // the text-compat loop passes its turn-start set on every iteration
        // so a mid-turn tool_load cannot mutate the stable system segment's
        // tool catalog and bust the prompt-cache prefix. nil = today's
        // behavior (fresh store read), used by all other callers.
        pinnedActiveTools: Set<String>? = nil,
        // Sibling of pinnedActiveTools: turn-start instant for the dynamic
        // segment's clock line, passed identically on every iteration of a
        // tool loop so a minute boundary can't churn the cache mid-turn.
        clockNowOverride: Date? = nil,
        // Full per-turn context reuse (turn-context-iteration-cache, third
        // churn source): on the live app the ContextFlow PACKET rides the
        // dynamic segment, and the turn's own tool results move her
        // attention, so a per-iteration re-prepare reshuffles packet bytes
        // and busts the prompt cache mid-turn — a source the tool-set and
        // clock pins cannot cover. A tool loop passes iteration 1's built
        // context back in on iterations 2+; the build (and its ContextFlow
        // prepare) then runs ONCE per turn, native-loop parity
        // (resolveToolLoopContext precedent). Reuse of the SAME TurnContext
        // object is lease/outcome-safe: ContextPreparedTurn.recordOutcome is
        // latched idempotent and deinit releases the generation lease once.
        preBuiltContext: TurnContext? = nil,
        // Fires exactly once, after a fresh build completes (never on the
        // preBuiltContext path) — the tool loop's capture hook.
        onContextBuilt: (@Sendable (TurnContext) -> Void)? = nil,
        imageBlocks: [LLMContentBlock] = [],
        // NATIVE TOOL LANE (kimi-code only — NativeToolCapability).
        // docs/build_plans/kimi-native-tools.md P2. When true, this turn ships
        // the per-iteration `ctx.toolSchemas` as a provider-native tools array
        // and the system prompt drops the marker-syntax protocol (the
        // COMPLETION CONTRACT is kept — it is model-behavior guidance, not
        // wire syntax). Reading the schemas off `ctx` rather than a
        // caller-supplied list is deliberate: ctx is rebuilt per iteration
        // through lazyFilteredTurnContext, so a lazy `tool_load` in iteration
        // N is reflected in iteration N+1's tools array for free — the same
        // round-trip the text-compat lane gets.
        nativeTools: Bool = false,
        // Where native tool_use blocks go. Kept OUT of TurnStreamEvent on
        // purpose: adding a case to that public enum would force a change at
        // every exhaustive switch on every surface (Mac UI, Telegram, iOS,
        // eval harnesses) for a signal only the text-compat loop consumes.
        // The sink is awaited inline in the consumption loop, so calls arrive
        // in wire order and strictly before `.final`.
        nativeToolCallSink: (@Sendable (LLMStreamToolCall) async -> Void)? = nil,
        // Raw user text for relevance consumers (selection queryText, memory
        // recall, query embedding) when `userMessage` carries turn-scoped wire
        // riders — the text-compat tool-routing hint. nil → `userMessage`.
        queryUserMessage: String? = nil
    ) -> AsyncThrowingStream<TurnStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let startNs = DispatchTime.now().uptimeNanoseconds
            // Wave 16 (2026-06-01): cancellation hardening — bind the inner
            // Task so the consumer's continuation.onTermination can cancel it.
            // Without this, when the UI calls stop() the LLM provider stream
            // kept running until natural completion (token waste + delayed
            // teardown). gpt-5.5 review flagged this as a state-lifecycle leak
            // (Claude's top bug class). Mirror the lower-level provider stream
            // pattern: bind Task, propagate cancel via onTermination, check
            // Task.isCancelled around every chunk forward.
            //
            // Turn Inspector W1: bind the per-turn trace id for the inner Task.
            // MEMORY-SAFETY (2026-07-04): the binding is done INSIDE the Task
            // via the ASYNC withValue overload — NOT a synchronous withValue
            // wrapping the Task {} creation. The old shape pushed the task-local
            // on the PARENT task and popped it the instant the sync withValue
            // returned, while this spawned child task had inherited a reference
            // into that same storage; the child then tore down freed task-local
            // storage → swift_task_dealloc_specific fatalError. This is the
            // inner turn Task that runs buildTurnContextWithHistory →
            // promptMessagesWithStats — Thread B in the G4-5 crash. Binding
            // inside keeps push/pop LIFO on the child's own stack.
            // INHERIT-OR-MINT: a single chatStream() turn calls streamTurn once
            // PER tool-loop iteration, and the text-compat tool loop already
            // binds the turn id ONCE around all iterations — so reuse an
            // already-bound id and only mint when this is a direct one-shot
            // streamTurn with no ambient turn. This keeps every iteration of one
            // turn under ONE story while still giving a bare caller a valid id.
            let turnId = TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
            let task = Task {
                await LLMCallContext.$providerId.withValue(
                    providerIDOverride ?? LLMCallContext.providerId
                ) {
                await LLMCallContext.$turnActiveTools.withValue(turnActiveTools) {
                await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(turnId) {
                // Pre-context cancellation check — avoid burning context-build
                // work for a stream that's already been cancelled (gpt-5.5
                // follow-up review note).
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let ctx: TurnContext
                if let preBuiltContext {
                    ctx = preBuiltContext
                } else {
                do {
                    // Wave 16: when a sessionId is supplied, thread prior
                    // conversation history through the context so streaming
                    // is coherent across turns (Mac UI's normal sends carry
                    // a sessionId). When nil, fall back to context-only
                    // (one-shot). gpt-5.5 review flagged the original
                    // history-less path as a behavioral regression vs the
                    // daemon's /v1/chat/stream which threaded history.
                    let rawCtx: TurnContext
                    if let sessionId, !sessionId.isEmpty {
                        rawCtx = try await self.buildTurnContextWithHistory(
                            surface: surface,
                            userMessage: userMessage,
                            sessionId: sessionId,
                            historyLimit: historyLimit,
                            historyReader: historyReader,
                            personaOverride: personaOverride,
                            excludeHistoryRunId: excludeHistoryRunId,
                            imageBlocks: imageBlocks,
                            queryUserMessage: queryUserMessage,
                            clockNowOverride: clockNowOverride
                        )
                    } else {
                        rawCtx = try await self.buildTurnContext(
                            surface: surface,
                            userMessage: userMessage,
                            personaOverride: personaOverride,
                            imageBlocks: imageBlocks,
                            queryUserMessage: queryUserMessage,
                            clockNowOverride: clockNowOverride
                        )
                    }
                    let plannedCtx = Self.contextByAppendingTurnPlanHint(
                        rawCtx,
                        turnPlan: turnPlan
                    )
                    let runtimeCtx = Self.contextByAppendingRuntimeContext(
                        plannedCtx,
                        runtimeContext: runtimeContext ?? ""
                    )
                    // 2026-06-08 lazy-tool-skill-loading close-out: Anthropic
                    // OAuth compat path (textToolCompatibility: true) goes
                    // through here too — apply the SAME per-session lazy
                    // filter the structured tool loop applies so this surface
                    // doesn't ship the full eager catalog. Empty/nil sessionId
                    // falls closed to alwaysOnCore + MCP only. (C3 shared helper.)
                    ctx = await self.lazyFilteredTurnContext(
                        runtimeCtx,
                        sessionId: sessionId,
                        pinnedActiveTools: pinnedActiveTools
                    )
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    continuation.yield(.error(message))
                    continuation.finish()
                    return
                }
                onContextBuilt?(ctx)
                }
                if Task.isCancelled {
                    continuation.finish()
                    return
                }

                // Eval fix (2026-06-03): honor the explicit model override
                // (Mac UI chatModel) instead of re-resolving from surfaces.json.
                let resolvedModel: String = {
                    if let m = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !m.isEmpty { return m }
                    return ctx.modelId
                }()
                let resolvedReasoningEffort: String = {
                    if let effort = reasoningEffortOverride?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !effort.isEmpty {
                        return effort
                    }
                    return ctx.reasoningEffort
                }()
                let compatibilityLayout = textToolCompatibility
                    ? Self.textToolCompatibilityLayout(
                        baseSystem: ctx.systemPrompt,
                        segments: ctx.systemSegments,
                        context: ctx,
                        nativeTools: nativeTools
                    )
                    : nil
                let resolvedSystem = compatibilityLayout?.system ?? ctx.systemPrompt
                let resolvedSegments = textToolCompatibility
                    ? compatibilityLayout?.segments
                    : ctx.systemSegments
                let snapshotContext = TurnContext(
                    surface: ctx.surface,
                    personaID: ctx.personaID,
                    personaDocs: ctx.personaDocs,
                    recalled: ctx.recalled,
                    modelId: resolvedModel,
                    reasoningEffort: resolvedReasoningEffort,
                    providerId: ctx.providerId,
                    serviceTier: ctx.serviceTier,
                    toolsAvailable: ctx.toolsAvailable,
                    systemPrompt: resolvedSystem,
                    userMessage: ctx.userMessage,
                    toolSchemas: ctx.toolSchemas,
                    systemSegments: resolvedSegments,
                    imageBlocks: ctx.imageBlocks,
                    fluidContextTurn: ctx.fluidContextTurn
                )
                Self.fireContextSnapshotEvent(
                    surface: surface,
                    context: snapshotContext,
                    sessionId: sessionId,
                    systemPromptOverride: resolvedSystem,
                    systemSegmentsOverride: resolvedSegments
                )

                var accumulated = ""
                var chunkIndex = 0
                var emittedProviderFirstDelta = false
                var emittedSurfaceOutputEnqueued = false
                var cancelledByFlag = false
                // Turn Inspector W2 — stream.tick throttle state. Per-stream
                // LOCAL vars (no shared mutable state → Swift-6-clean): the
                // ticker fires at most ~1 event/second by comparing timestamps,
                // NEVER by adding awaits/sleeps to the hot loop. `streamStartNs`
                // anchors elapsedMs; `lastTickNs` gates the throttle.
                let streamStartNs = DispatchTime.now().uptimeNanoseconds
                var lastTickNs: UInt64 = 0
                // U1 step 4: thread the session id task-locally (sync binding
                // around stream construction; inner adapter Task inherits) so
                // the OpenAI Responses adapter gets a stable prompt_cache_key.
                // U1 step 2b/3b: same for the stable/dynamic system split
                // (Anthropic adapters' breakpoint placement).
                // U1 item 9: when the caller passed an append-only
                // conversation and the client can stream messages, swap the
                // transport — the MessagesCacheHint binding tells the
                // Anthropic adapter this conversation is re-sent as a prefix
                // next iteration, earning the trailing message breakpoint
                // despite tools being nil on this path.
                // Turn Inspector W2 — GATED summarized-thinking lane. Read the
                // per-surface opt-in ONCE; bind the request-body task-local TRUE
                // only when it's on (Mac chat surface only). The binding wraps
                // the SYNCHRONOUS stream construction so the Anthropic adapter's
                // inner Task inherits it (same propagation as MessagesCacheHint).
                // FALSE (the default) → byte-identical request body (no
                // `thinking` key). Only meaningful on the Anthropic MESSAGES
                // transport (`thinking` is a Messages-API param); the legacy
                // `stream(prompt:)` lane below has no thinking channel.
                let thinkingOn = InspectorThinkingLane.isEnabledForSurface(surface)
                // NATIVE LANE WIRE NAMES (live 400, 2026-07-20 16:19Z): Kimi
                // validates tool names — "must start with a letter and can
                // contain letters, numbers, underscores, and dashes" — and the
                // catalog carries dotted/bridged names (mac.notify,
                // mcp__server__tool). Ship PROVIDER-SAFE aliases on the wire
                // (same ProviderToolNameMap the structured loop uses) and
                // reverse-map the model's calls back to internal names before
                // they reach the sink, so dispatch/gating/records never see an
                // alias.
                let nativeToolMap = nativeTools ? ProviderToolNameMap(ctx.toolSchemas) : nil
                // MEMORY-SAFETY (2026-07-21): bind via the ASYNC withValue
                // overload wrapping BOTH construction AND consumption of the
                // provider stream — never a sync withValue around construction
                // alone (the shape this code carried before this fix). Both
                // production adapters spawn their child Task synchronously
                // inside streamMessages/stream and read these task-locals
                // LAZILY while building the request body; a sync binding pops
                // at construction while the child still references it — the
                // G4-5 release-crash LIFO shape documented at
                // ChatOrchestration+ToolLoop.swift. The consumption loop is
                // shared by both transports, so it lifts into this closure and
                // each transport's async chain wraps construction + drain,
                // holding every binding LIFO-ordered until the adapter child
                // finishes. Zero behavior change: same bindings, same values,
                // same transport split (the legacy prompt lane still never
                // sees MessagesCacheHint/summarizedThinking).
                let drainStream: (AsyncThrowingStream<String, Error>) async -> Void = { llmStream in
                    do {
                        for try await chunk in llmStream {
                            if Task.isCancelled { break }
                            chunkIndex += 1
                            if let flag = cancelFlagPath,
                               chunkIndex % max(1, cancelCheckEveryN) == 0,
                               FileManager.default.fileExists(atPath: flag.path) {
                                cancelledByFlag = true
                                break
                            }
                            accumulated += chunk
                            if !chunk.isEmpty, !emittedProviderFirstDelta {
                                emittedProviderFirstDelta = true
                                TurnLifecycleTelemetry.emit(
                                    .providerFirstDelta,
                                    surface: surface,
                                    sessionId: sessionId,
                                    observedBy: "stream_turn.provider"
                                )
                            }
                            continuation.yield(.delta(chunk))
                            if !chunk.isEmpty, !emittedSurfaceOutputEnqueued {
                                emittedSurfaceOutputEnqueued = true
                                TurnLifecycleTelemetry.emit(
                                    .surfaceOutputEnqueued,
                                    surface: surface,
                                    sessionId: sessionId,
                                    observedBy: "stream_turn.continuation"
                                )
                            }
                            // Turn Inspector W2 — coarse progress ticker. THROTTLE
                            // is a pure timestamp-compare (no await, no sleep): emit
                            // at most ~1 event/second carrying accumulated char
                            // count + elapsed ms. Fire-and-forget only; zero awaits
                            // added to this hot path.
                            let nowNs = DispatchTime.now().uptimeNanoseconds
                            if nowNs &- lastTickNs >= 1_000_000_000 {
                                lastTickNs = nowNs
                                let elapsedMs = Int((nowNs &- streamStartNs) / 1_000_000)
                                TurnTraceBus.fireFromContext(
                                    kind: "stream.tick",
                                    surface: surface,
                                    payload: .object([
                                        "chars": .int(Int64(accumulated.count)),
                                        "elapsedMs": .int(Int64(elapsedMs)),
                                        "chunks": .int(Int64(chunkIndex)),
                                    ])
                                )
                            }
                        }
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        continuation.yield(.error(message))
                        continuation.finish()
                        return
                    }

                    if Task.isCancelled || cancelledByFlag {
                        if cancelledByFlag {
                            continuation.yield(.error("cancelled"))
                        }
                        continuation.finish()
                        return
                    }

                    // Provider honesty boundary shared by every streaming
                    // surface. A clean EOF with no semantic output is not a
                    // successful blank answer: the text-compat loop can nudge
                    // it in-turn, while bounded callers surface an honest
                    // failure. Native tool streams are excluded because their
                    // tool calls travel through the separate sink and produce
                    // no text by design; native adapters enforce their own
                    // text-or-tool invariant.
                    if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !nativeTools {
                        continuation.yield(.error(
                            "provider stream completed with no answer text or tool call"
                        ))
                        continuation.finish()
                        return
                    }

                    let recalledIds = ctx.resolvedRecalledIds
                    let endNs = DispatchTime.now().uptimeNanoseconds
                    let elapsedMs = Int((endNs &- startNs) / 1_000_000)
                    let result = TurnEngineResult(
                        reply: accumulated,
                        modelUsed: resolvedModel,
                        recalledIds: recalledIds,
                        toolDispatches: [],
                        elapsedMs: elapsedMs,
                        rawLLMResponse: accumulated,
                        terminalObservation: .init(context: ctx)
                    )
                    continuation.yield(.final(result))
                    continuation.finish()
                }
                if let conversation,
                   let messagesLLM = streamingLLM as? any MessagesStreamingLLMClient {
                    await LLMCallContext.$providerId.withValue(snapshotContext.providerId) {
                    await LLMCallContext.$serviceTier.withValue(snapshotContext.serviceTier) {
                    await LLMCallContext.$systemSegments.withValue(resolvedSegments) {
                    await LLMCallContext.$sessionId.withValue(sessionId) {
                    await LLMCallContext.$reasoningEffort.withValue(resolvedReasoningEffort) {
                    await AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
                    await InspectorThinkingLane.$summarizedThinking.withValue(thinkingOn) {
                        let events = messagesLLM.streamMessages(
                            messages: conversation,
                            system: resolvedSystem,
                            model: resolvedModel,
                            surface: surface,
                            // Native lane ONLY: every other
                            // provider keeps tools nil here, which
                            // is what guarantees the Claude OAuth
                            // adapters never receive a tools array.
                            tools: nativeToolMap?.schemas
                        )
                        let resolvedSink: (@Sendable (LLMStreamToolCall) async -> Void)?
                        if let nativeToolCallSink, let map = nativeToolMap {
                            resolvedSink = { call in
                                await nativeToolCallSink(LLMStreamToolCall(
                                    id: call.id,
                                    name: map.internalName(forProviderName: call.name),
                                    inputJSON: call.inputJSON
                                ))
                            }
                        } else {
                            resolvedSink = nativeToolCallSink
                        }
                        await drainStream(Self.textChunkStream(from: events, nativeToolCallSink: resolvedSink))
                    }
                    }
                    }
                    }
                    }
                    }
                    }
                } else {
                    // TRIPWIRE (streaming legacy prompt lane): the plain
                    // `stream(prompt:)` transport has NO image channel, so any
                    // image blocks on this turn cannot be seen by the model.
                    // Prepend an honest note (never silently describe-or-pretend)
                    // and emit a `vision.attachment_unsupported` trace.
                    var promptForStream = ctx.userMessage
                    if !ctx.imageBlocks.isEmpty {
                        let n = ctx.imageBlocks.count
                        let note = "[NOTE TO ASSISTANT: the user attached \(n) image(s) but the active provider/model on this stream cannot see images. Tell the user honestly that you could not view the attached image(s) — do NOT guess or pretend to describe them.]"
                        promptForStream = promptForStream.isEmpty ? note : note + "\n" + promptForStream
                        await Self.emitVisionUnsupportedTrace(
                            imageCount: n, surface: surface, model: resolvedModel,
                            turnTraceBus: turnTraceBus
                        )
                    }
                    let streamPrompt = promptForStream
                    await LLMCallContext.$providerId.withValue(snapshotContext.providerId) {
                    await LLMCallContext.$serviceTier.withValue(snapshotContext.serviceTier) {
                    await LLMCallContext.$systemSegments.withValue(resolvedSegments) {
                    await LLMCallContext.$sessionId.withValue(sessionId) {
                    await LLMCallContext.$reasoningEffort.withValue(resolvedReasoningEffort) {
                        await drainStream(streamingLLM.stream(
                            prompt: streamPrompt,
                            system: resolvedSystem,
                            model: resolvedModel,
                            surface: surface
                        ))
                    }
                    }
                    }
                    }
                    }
                }
                }
                }
                }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// U1 item 9: bridge a structured messages event stream back to the text
    /// chunk shape streamTurn's consumption loop (cancel-flag polling, delta
    /// accumulation, flush buffering downstream) already handles — the loop
    /// stays byte-identical for both transports. tools[] is never sent on
    /// the text-compat messages transport, so .toolCall events should not
    /// occur; if a provider emits one anyway it is rendered defensively as
    /// the exact id-bearing marker text ToolCallParser already parses (same
    /// rendering as the structured streaming loop's raw-response trace).
    private nonisolated static func textChunkStream(
        from events: AsyncThrowingStream<LLMMessageStreamEvent, Error>,
        // NATIVE TOOL LANE: when non-nil, a provider tool_use block is handed
        // to the sink as STRUCTURED data and contributes an empty text chunk
        // instead of being re-rendered as marker prose. The empty chunk is not
        // cosmetic — streamTurn's consumption loop runs the cross-process
        // cancel-FLAG poll per yielded chunk, and a tool-only response would
        // otherwise starve that cadence entirely (same reasoning as the
        // keepAlive case below).
        nativeToolCallSink: (@Sendable (LLMStreamToolCall) async -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .textDelta(let s):
                            continuation.yield(s)
                        case .toolCall(let call):
                            if let nativeToolCallSink {
                                await nativeToolCallSink(call)
                                continuation.yield("")
                                continue
                            }
                            let args = String(data: call.inputJSON, encoding: .utf8) ?? "{}"
                            continuation.yield("\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>")
                        case .keepAlive:
                            // Liveness signal, no content. This text-compat mapper
                            // is deliberately dumb — streamTurn's consumption loop
                            // does the cross-process cancel-FLAG poll PER yielded
                            // chunk (see header comment). Yield an empty string so
                            // that poll keeps firing during a keepalive-only
                            // (pure-thinking) phase; streamTurn accumulates "" as a
                            // no-op. (Task cancellation is already checked above per
                            // event; this restores the FILE-flag cadence a `break`
                            // would have starved — gpt-5.5 review 2026-06-15.)
                            // Event-layer purity is unaffected: direct
                            // LLMMessageStreamEvent consumers still get `.keepAlive`,
                            // never `.textDelta("")`.
                            continuation.yield("")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func withTextToolCompatibilityInstructions(
        _ baseSystem: String?,
        context: TurnContext,
        nativeTools: Bool = false
    ) -> String {
        let toolBlock = nativeTools
            ? renderNativeToolInstructions()
            : renderTextToolCompatibilityInstructions(
                schemas: context.toolSchemas,
                names: context.toolsAvailable
            )
        guard let base = baseSystem?.trimmingCharacters(in: .whitespacesAndNewlines),
              !base.isEmpty else {
            return toolBlock
        }
        return base + "\n\n" + toolBlock
    }

    /// Places the lazy tool contract ahead of volatile recall/history so the
    /// provider can reuse one honest stable prefix across ordinary turns.
    /// The contract and catalog are stable until the session loads a different
    /// tool set; that mutation intentionally rewrites the cache once. No tool,
    /// memory, or conversation content is removed.
    nonisolated static func textToolCompatibilityLayout(
        baseSystem: String?,
        segments: SystemPromptSegments?,
        context: TurnContext,
        nativeTools: Bool = false
    ) -> (system: String, segments: SystemPromptSegments?) {
        let toolBlock = nativeTools
            ? renderNativeToolInstructions()
            : renderTextToolCompatibilityInstructions(
                schemas: context.toolSchemas,
                names: context.toolsAvailable
            )
        guard let segments,
              let baseSystem,
              segments.reassembles(into: baseSystem) else {
            return (
                withTextToolCompatibilityInstructions(
                    baseSystem,
                    context: context,
                    nativeTools: nativeTools
                ),
                nil
            )
        }
        let stable = segments.stable.isEmpty
            ? toolBlock
            : segments.stable + "\n\n" + toolBlock
        let reordered = SystemPromptSegments(
            stable: stable,
            dynamic: segments.dynamic
        )
        return (reordered.combined, reordered)
    }

    /// NATIVE lane system block. The provider already carries the tool
    /// catalog, the argument schemas, and the call syntax in the request's
    /// `tools` array — repeating any of that as prose is pure token cost and
    /// (worse) invites the model to emit marker text the native lane no longer
    /// parses. So the marker-syntax protocol, the "does not include
    /// provider-native tools" disclaimer, and the rendered tool table are ALL
    /// dropped here.
    ///
    /// What is KEPT is everything that is model-BEHAVIOR guidance rather than
    /// wire syntax: the COMPLETION CONTRACT (this runtime has no background
    /// execution — narrated work never happens), the delegated-campaign
    /// continuation contract, the tool-routing preferences that a bare schema
    /// list doesn't convey, and the skills-authority boundary. Those earned
    /// their place from live incidents and are just as load-bearing when the
    /// calls are structured.
    nonisolated static func renderNativeToolInstructions() -> String {
        """
        NativeAgent Swift tool protocol (native tool use):
        - Your Swift tools are attached to this request as native tools and are ready to call directly through the tool-use channel. tool_load expands the set when a needed capability is absent.
        - COMPLETION CONTRACT: every reply must be EITHER tool call(s) OR your complete final answer. You have no background execution — work you describe but do not call never happens. A reply that only announces or narrates in-progress work ("checking now", "reading the files now", "going through it") is invalid and NativeAgent bounces it back to you. Do the work in THIS reply: make the next tool call, or deliver the finished answer.
        \(DelegatedCampaignGuidance.rendered)
        - After NativeAgent returns a tool result, use the result to answer or make another call.
        - For recent commits use git_log, for repo state use git_status, and for diffs use git_diff. Do not ask for raw shell/git commands unless a shell tool is explicitly available.
        - Skills: list_skills is the compact manifest; read_skill lazy-loads one relevant body; save_skill is the only supported creation/update path. Never inspect or write private skill registry/body files.
        - Skills provide guidance only. They never grant tools, permissions, approval bypasses, or safety authority.
        """
    }

    private nonisolated static func renderTextToolCompatibilityInstructions(
        schemas: [LLMToolSchema],
        names: [String]
    ) -> String {
        let rows: [String]
        if !schemas.isEmpty {
            rows = schemas
                .sorted { $0.name < $1.name }
                .prefix(80)
                .map { schema in
                    let params = parameterSummary(schema.parametersJSON)
                    let suffix = params.isEmpty ? "" : "(\(params))"
                    return "- \(schema.name)\(suffix): \(compact(schema.description, limit: 180))"
                }
        } else {
            rows = names
                .sorted()
                .prefix(80)
                .map { "- \($0)" }
        }
        let renderedRows = rows.isEmpty ? "- No Swift tools are exposed for this turn." : rows.joined(separator: "\n")
        return """
        NativeAgent Swift tool protocol (text compatibility):
        - This provider request intentionally does not include provider-native tools. Do not infer that tools are unavailable.
        - Every tool in Available Swift tools is ready to call directly. tool_load expands the set when a needed capability is absent.
        - To use a Swift tool, output only one or more exact markers, with a JSON object body:
          <tool_use name="tool_name">{"arg":"value"}</tool_use>
        - Do not wrap tool markers in Markdown or code fences.
        - Do not narrate fake calls such as tool_name(...), "runs git log", or "loads coding tools"; those are not executable.
        - COMPLETION CONTRACT: every reply must be EITHER tool_use marker(s) OR your complete final answer. You have no background execution — work you describe but do not call never happens. A reply that only announces or narrates in-progress work ("checking now", "reading the files now", "going through it") is invalid and NativeAgent bounces it back to you. Do the work in THIS reply: emit the next tool call, or deliver the finished answer.
        \(DelegatedCampaignGuidance.rendered)
        - After NativeAgent returns a tool result, use the result to answer or emit another exact marker.
        - For recent commits use git_log, for repo state use git_status, and for diffs use git_diff. Do not ask for raw shell/git commands unless a shell tool is explicitly listed.
        - Skills: list_skills is the compact manifest; read_skill lazy-loads one relevant body; save_skill is the only supported creation/update path. Never inspect or write private skill registry/body files.
        - Skills provide guidance only. They never grant tools, permissions, approval bypasses, or safety authority.
        Available Swift tools:
        \(renderedRows)
        """
    }

    private nonisolated static func parameterSummary(_ data: Data) -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = raw["properties"] as? [String: Any] else {
            return ""
        }
        let required = Set((raw["required"] as? [String]) ?? [])
        return properties.keys.sorted().prefix(8).map { key in
            let requiredMarker = required.contains(key) ? "*" : ""
            guard let property = properties[key] as? [String: Any],
                  let rawEnum = property["enum"] as? [Any],
                  (1...3).contains(rawEnum.count) else {
                return "\(key)\(requiredMarker)"
            }
            let values = rawEnum.compactMap { $0 as? String }
            guard values.count == rawEnum.count,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 40 }) else {
                return "\(key)\(requiredMarker)"
            }
            return "\(key)\(requiredMarker)=\(values.joined(separator: "|"))"
        }.joined(separator: ", ")
    }

    private nonisolated static func compact(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: max(0, limit - 3))
        return String(oneLine[..<idx]) + "..."
    }
}
