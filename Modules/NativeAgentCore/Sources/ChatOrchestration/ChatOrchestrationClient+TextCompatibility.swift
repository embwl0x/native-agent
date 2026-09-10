import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate

/// Per-ITERATION sink for provider-native tool_use blocks. Deliberately
/// constructed fresh inside each tool-loop iteration rather than once per turn:
/// a turn-scoped collector would have to be drained correctly on every one of
/// the loop's early-return paths (cancel, provider error, empty-reply recovery,
/// protocol violation), and a missed drain would leak iteration N's calls into
/// iteration N+1 as phantom dispatches. Fresh-per-iteration makes that class of
/// bug unrepresentable.
actor NativeToolCallCollector {
    private var calls: [LLMStreamToolCall] = []
    func append(_ call: LLMStreamToolCall) { calls.append(call) }
    /// Wire order preserved — P0 shape C requires ALL blocks to dispatch in
    /// the order the model emitted them.
    func drain() -> [LLMStreamToolCall] { calls }
}

extension SwiftNativeChatOrchestrationClient {

    func runTextStreamingCompatibility(
        message: String,
        sessionId: String?,
        runId runIdOverride: String? = nil,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        streamingLLM: any StreamingLLMClient,
        emitTextDeltas: Bool,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async {
        // v2Prefix (a): the adapters read ONLY the task-local override, so this
        // entry resolves `.effective` exactly once and binds it for the whole
        // turn. Redundant when the streaming facade already bound it (same
        // value); load-bearing for the non-streaming caller.
        await ConversationPrefixShape.$override.withValue(ConversationPrefixShape.effective) {
        // Whole-turn clock, from entry (user-message persist, compaction, tool
        // preload all happen before the loop). Each iteration's streamTurn starts
        // its own clock, so a result's elapsedMs was the LAST segment only —
        // turn.terminal carried 9.7 s for a 23-tool turn that ran 204 s
        // (2026-08-23 instrument lead).
        let turnStartNs = DispatchTime.now().uptimeNanoseconds
        // Same caller-scoped override the structured loops thread through
        // (StructuredChat 378/757 → ToolLoop 1924/2167). Without it the bridge
        // profile's marathon budget (turnWallClockSeconds=3900) was dropped on
        // this lane and Anthropic-model bridge turns died at chat's 600s.
        var wholeTurnBudget = WholeTurnWallClockBudget.start(
            surface: surface,
            requestedSeconds: turnWallClockSecondsOverride
        )
        let resolvedSession: String
        do {
            resolvedSession = try Self.resolveSessionId(sessionId)
        } catch {
            continuation.yield(.error((error as? LocalizedError)?.errorDescription ?? "invalid chat session id"))
            continuation.finish()
            return
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: resolvedSession,
            turnId: TurnTraceContext.turnId
        )
        defer {
            if let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        let runId = runIdOverride ?? UUID().uuidString
        func persistCompatibilityPartial(_ text: String, cancelled: Bool) async {
            await persistPartialIfNeeded(
                sessionId: resolvedSession,
                runId: runId,
                text: text,
                cancelled: cancelled,
                source: surface,
                outcomeInterventionAssignment: nil,
                onNotice: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
            )
        }
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "text_compat.entry"
        )
        let cancelFlagPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(resolvedSession, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
        // Clear only the marker inherited from a PRIOR turn, at the same
        // acceptance boundary as the structured provider lane. A Stop written
        // after acceptance must remain observable while persistence/context
        // work is in flight; clearing it later can erase a real remote Stop.
        try? FileManager.default.removeItem(at: cancelFlagPath)
        // Native vision: image attachments become per-turn DYNAMIC image blocks
        // on the CURRENT user message; the model sees the RAW message text (no
        // stringified suffix). Empty → byte-identical wire shape.
        // 2026-09-06: through the Trust ▸ Multimodal gates like the structured
        // lanes — "Allow vision API calls" off skips the images (and says so),
        // "Allow PDF file ingestion" on puts an attached PDF's text into the
        // model-facing message. The PERSISTED user row keeps `message`.
        let attachmentInput = Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot)
        let composed = attachmentInput.userMessage
        let imageBlocks = attachmentInput.imageBlocks

        if !suppressUserAppend {
            do {
                try await appendMessage(
                    sessionId: resolvedSession,
                    role: "user",
                    content: message,
                    runId: runId,
                    attachments: attachments,
                    persona: persona,
                    source: surface
                )
            } catch is CancellationError {
                continuation.yield(.error("cancelled"))
                continuation.finish()
                return
            } catch {
                continuation.yield(.error("persist user turn failed: \(error)"))
                continuation.finish()
                return
            }
        }

        // The window cursor must not slide in a turn the autocompactor already
        // rewrote (see HistoryWindowCursor) — so the outcome is carried, not
        // discarded.
        var compactionRanThisTurn = false
        do {
            compactionRanThisTurn = try await prepareSessionHistoryForTurn(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch {
            continuation.yield(.error("cancelled"))
            continuation.finish()
            return
        }

        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            fileAccess: fileAccess
        )
        // TURN START: advance the session turn clock and batch-drop tools that
        // went two completed turns without being called, before the catalog is
        // read. Drops rewrite the advertised contract, so they happen here and
        // nowhere else in the turn.
        async let preloadActiveToolsTask = activeToolsStore.beginTurn(sessionId: resolvedSession)
        async let preloadToolSchemaCatalogSeedTask: TurnToolSchemaCatalogSeed? = {
            guard let schemas = try? await tools.listAvailableToolSchemas() else { return nil }
            return TurnToolSchemaCatalogSeed(schemas: schemas)
        }()

        // U1 step 7 fix (2026-06-10 review): this Anthropic text-compat path
        // was the one first-model-call site WITHOUT predictive preload — and
        // claude models stream through here, so it's the PRIMARY production
        // path. The preload is request-scoped: streamTurn and dispatch read it
        // through LLMCallContext.turnActiveTools so first-call schemas and the
        // lazy gate agree without growing the persisted ActiveToolsStore.
        // availableToolNames mirrors the context builder's catalog source:
        // tools.listAvailableToolSchemas() under fullMacToolAccess() policy
        // flags (ChatOrchestration+TurnEngine.swift buildTurnContext; the
        // factory hands engine + client the same dispatcher instance).
        let residentPreparation = await residentPreparationTask
        let turnPlan = residentPreparation.turnPlan
        let preloadActiveTools = await preloadActiveToolsTask.activeTools
        let preloadToolSchemaCatalogSeed = await preloadToolSchemaCatalogSeedTask
        let preloadAvailableNames = Set(preloadToolSchemaCatalogSeed?.schemas.map(\.name) ?? [])
        let preloadPrediction = turnPlan?.preloadPrediction
            ?? ToolPreloadHeuristics.predict(userMessage: message, surface: surface)
        let preloadOutcome = await ToolPreloadHeuristics.preloadOutcome(
            prediction: preloadPrediction,
            sessionId: resolvedSession,
            activeTools: preloadActiveTools,
            availableToolNames: preloadAvailableNames,
            surface: surface,
            dataRoot: dataRoot
        )
        // Still TURN START, before the first prefix is built: snapshot MCP
        // membership, freeze a descriptor per slot, and promote the confident
        // route prediction into the load order so its schemas are ADVERTISED on
        // this turn (docs/ANATOMY_OF_A_TURN.md §3 — a GitHub URL prepares the
        // GitHub read tools with no discovery round) and byte-stable after it.
        let contractCommit = await activeToolsStore.commitTurnStartContract(
            sessionId: resolvedSession,
            promoting: preloadOutcome.promotable,
            catalog: preloadToolSchemaCatalogSeed?.schemas ?? []
        )
        // A name that was NOT admitted (no headroom, or the write failed) stays
        // discovery-only — tool_load is the honest recovery path, and
        // tool_catalog must not describe it as loaded.
        let turnActiveTools = preloadOutcome.activeTools.subtracting(
            preloadOutcome.promotable.subtracting(contractCommit?.promoted ?? [])
        )
        // Pinned for the WHOLE turn: every later iteration advertises this
        // exact contract, so a mid-turn tool_unload or idle drop cannot shrink
        // the catalog inside the cache-breakpointed stable segment.
        let turnContract = contractCommit?.state.toolContract
        // Route focus now lives in TurnPlan's dynamic system segment, shared
        // by structured and text-compatible providers. Keeping it there makes
        // the cue identical across Mac, Telegram, Slack, and bridge surfaces,
        // and avoids a second, request-appended set of behavioral fences.
        let routedComposed = composed

        var accumulated = ""
        var pendingDelta = ""
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var finalResult: TurnEngineResult?
        // Packet provenance (gpt-5.5 LOW, 2026-07-11): a protocol violation
        // clears finalResult, but the memories the turn USED don't un-happen —
        // retain the last seen recalledIds so the exhaustion fallback still
        // stamps them on the persisted assistant turn.
        var lastRecalledIds: [String] = []
        var sawFinal = false
        let maxToolIterations = toolLoopMaxIterations(for: surface)
        var currentUserMessage = routedComposed
        var announceNudgeCount = 0
        // K3 empty-reply recovery (2026-07-20 live: two turns died on
        // "HTTP 200 with no answer text (stop_reason=end_turn; content:
        // thinking×1)" — the model did the whole move inside its thinking
        // block and emitted zero text, deterministically enough that
        // identical whole-turn replays failed identically). In-loop feedback
        // is the fix, same plumbing as the protocol-violation and announce
        // nudges; bounded so a provider that only ever thinks can't loop.
        var emptyReplyNudgeCount = 0
        // 2026-07-21 audit fix: bound the protocol-violation bounce. Announce
        // and empty-reply nudges were capped (< 2) but a deterministically
        // malformed model could violate EVERY iteration — and since violation
        // iterations dispatch zero tools, the no-progress guard never fires —
        // burning the ENTIRE iteration budget (up to 180 provider calls on
        // telegram). Same philosophy: the third violation is accepted as
        // final (the post-loop exhausted path yields its terminalReply).
        var violationNudgeCount = 0
        var didCancel = false
        var exhaustedToolLoop = false
        var wallClockElapsedSeconds: Int?
        var lastProtocolViolation: ToolCallProtocolViolation?
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        var reachedLengthLimit = false
        // C-H1 (2026-07-18): this text-compat loop is the PRIMARY Anthropic/Claude
        // chat path but never counted provider calls — streamTurn yields a
        // TurnEngineResult with providerCallCount:nil (one provider completion per
        // call), so ChatDrive/eval aggregations undercounted the main surface. The
        // loop OWNS the count (one streamTurn per iteration); stamp it onto every
        // result site this function emits, same pattern as the structured loops
        // (ChatOrchestration+ToolLoop.swift:1548 B3).
        var providerCallCount = 0
        // User, 2026-09-06: replay-only reconnect ladder for this lane (the
        // structured loops' ladder lives in ChatOrchestration+ToolLoop.swift).
        // `providerCallAttempt` counts the attempts the CURRENT provider call
        // has burned — reset once an attempt gets through the stream — and
        // `providerTurnRecoveries` is the whole-turn ceiling both lanes share.
        // `providerReplayError` is set by a failure site that wants the call
        // replayed; the ladder itself runs once, after the stream block.
        var providerCallAttempt = 1
        var providerTurnRecoveries = 0
        var providerReplayError: Error?

        let effectiveModel = LLMCallContext.admittedModel ?? model
        // The user's selected effort is the provider contract. The retired
        // adaptive-effort experiment no longer runs a pre-provider decision
        // or records a production intervention on ordinary chat.
        let effectiveReasoningEffort = LLMCallContext.reasoningEffort ?? reasoningEffort
        if let turnPlan {
            await TurnPlanTraceRecorder.append(
                turnPlan,
                runId: runId,
                surface: surface,
                dataRoot: dataRoot,
                turnTraceBus: turnTraceBus
            )
        }
        let cognitiveRuntimeContext = Self.cognitiveRuntimeContext(
            runId: runId,
            sessionId: resolvedSession,
            surface: surface,
            fileAccess: fileAccess,
            capsule: residentPreparation.cognitiveProjection?.capsule,
            posture: residentPreparation.cognitiveProjection?.posture
        )
        // R-F1: held until the provider accepts the turn; nil when nothing was
        // actually appended to provider input.
        let pendingProjectionCommit: CognitiveTurnProjection? =
            cognitiveRuntimeContext == nil ? nil : residentPreparation.cognitiveProjection

        // U1 item 9 (F1 lane (b), text-compat): the grown single user
        // message re-paid its full mass to the provider EVERY tool-loop
        // iteration (F1 live measure: 12-18k input tokens/iteration; only
        // Anthropic's flaky server-side heuristic ever recovered any). New
        // default shape: an APPEND-ONLY [LLMMessage] conversation —
        // [user(composed)] + per iteration [assistant(raw reply incl.
        // markers), user(tool results)] — streamed over the adapter's real
        // messages SSE with a trailing message breakpoint, so iteration N+1
        // deterministically cache-READS everything through iteration N.
        // Eligibility is fail-closed to the legacy grown-prompt wire shape
        // (see appendOnlyMessagesEligibility); NATIVE_AGENT_GROWN_PROMPT_
        // COMPAT=1 is the same one rollback lever item 8 shipped — it
        // restores the old grown-prompt shape here AND the old breakpoint
        // layout in the adapter.
        //
        // Known model-visible deltas vs the grown shape (QA-gate pinned
        // equivalent on fixtures, TextCompatAppendOnlyQATests): the model
        // now sees its own prior in-turn replies as assistant messages
        // (Claude-Code incremental framing), and memory recall is keyed on
        // the ORIGINAL user message every iteration instead of the
        // tool-result-polluted grown prompt (which also keeps the system
        // prompt byte-stable across iterations — the cache precondition).
        // turn-context-iteration-cache (2026-08-13): the append-only marker
        // lane now builds the turn context ONCE (iteration 1) and REUSES it
        // for every later iteration — catalog, clock line, and ContextFlow
        // packet all pin for the turn, native-structured-loop parity. The
        // per-iteration rebuild survives ONLY on the legacy grown-prompt
        // shape (its transcript rides ctx.userMessage) and the kimi native
        // lane (its provider tools array is its only call channel). Mid-turn
        // tool_load stays usable everywhere via schemas_added in its result
        // + the store-reading dispatch gate.
        // NATIVE TOOL LANE (kimi-code and the Anthropic API-KEY provider —
        // never OAuth). Resolved ONCE per turn: the provider cannot change
        // mid-turn, and re-resolving per iteration would add a routing-snapshot
        // read to every provider call.
        let nativeDecision = await usesNativeToolLane(model: effectiveModel, surface: surface)
        let nativeLane = nativeDecision.engaged
        // This preflight chooses a materially different provider wire shape.
        // It must remain visible in the per-turn trace: a missing OAuth file,
        // an adapter regression, or the emergency rollback lever otherwise
        // looks exactly like an ordinary (but slower and more expensive) turn.
        let appendOnlyEligibility = Self.appendOnlyMessagesEligibility(
            streamingLLM: streamingLLM,
            dataRoot: dataRoot
        )
        var appendOnlyEligible = appendOnlyEligibility.isEligible
        // The native lane REQUIRES the structured messages transport: tool_use
        // and tool_result are content BLOCKS, and there is no way to express
        // them in the legacy grown-prompt string. The standard eligibility
        // check gates on Anthropic OAuth credentials (the only provider with a
        // real messages SSE implementation on the text-compat lane), which
        // kimi-code does not have and does not need — it rides the adapter's
        // non-streaming messages path. So a messages-capable client is the
        // whole requirement here.
        if nativeLane, streamingLLM is any MessagesStreamingLLMClient {
            appendOnlyEligible = true
        }
        Self.emitAppendOnlyMessagesEligibilityTrace(
            appendOnlyEligibility,
            effectiveTransport: appendOnlyEligible
                ? (nativeLane ? "native_messages" : "append_only_messages")
                : "grown_prompt",
            nativeLane: nativeDecision,
            // The lane only actually engages when the messages transport is
            // there to carry tool_result blocks back — see `ridesNativeTools`
            // just below. Both booleans are emitted so a denied native lane is
            // legible as a DOWNGRADE rather than as a provider that was never
            // eligible.
            nativeToolsEngaged: nativeLane && appendOnlyEligible,
            sessionId: resolvedSession,
            surface: surface
        )
        // Fail closed and LOUD rather than silently degrading: without the
        // messages transport the native lane would ship a tools array whose
        // results could never be returned, so the model would call the same
        // tool forever. Drop back to the proven text-compat marker protocol.
        let ridesNativeTools = nativeLane && appendOnlyEligible
        var emittedProviderFirstDelta = false
        // Sibling of the catalog pin: the clock line renders into the dynamic
        // system segment, and a turn crossing a minute boundary re-rendered
        // it mid-turn — byte-diff-proven cache bust. The turn is one moment:
        // freeze its instant here and pass it to every iteration's build.
        let turnClockNow = Date()
        // Quiet-hours configuration is likewise a whole-turn snapshot. This
        // wrapper preserves configured absence, so legacy grown-prompt and
        // native-tools iterations cannot turn one preference read into N.
        let quietHoursSnapshot = await engine.captureTurnQuietHoursSnapshot()
        // Third pin (see streamTurn.preBuiltContext): iteration 1's fully
        // built context is captured and reused for every later iteration, so
        // ContextFlow prepares ONCE per turn and the packet bytes cannot
        // reshuffle mid-turn as her attention moves with tool results.
        // Kimi native lane exempt (its per-iteration tools-array refresh is
        // load-bearing). Box is @unchecked Sendable: written once inside
        // iteration 1's stream (before its first yield), read only after
        // that stream completes — sequential access by construction.
        final class TurnContextBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: TurnContext?
            func set(_ ctx: TurnContext) { lock.lock(); if value == nil { value = ctx }; lock.unlock() }
            func get() -> TurnContext? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let turnContextBox = TurnContextBox()
        // User, 2026-09-06: the typed error behind an engine-yielded
        // `.error(String)`. `@unchecked Sendable` for the same reason
        // TurnContextBox is — written inside the provider stream's task,
        // read on this one after the event that follows the write, with an
        // NSLock making the handoff safe. Without it a typed
        // `LLMError.streamTruncated` (a clean Anthropic EOF with no
        // message_stop — the commonest drop there is) reached the reconnect
        // ladder as prose, got re-wrapped as `.providerError`, and failed
        // classification, so the ladder never ran.
        final class StreamFailureBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (any Error)?
            func set(_ error: any Error) {
                lock.lock(); if value == nil { value = error }; lock.unlock()
            }
            func get() -> (any Error)? { lock.lock(); defer { lock.unlock() }; return value }
        }
        // Reuse ONLY on the append-only messages transport: the legacy
        // grown-prompt shape carries the growing transcript INSIDE
        // ctx.userMessage, so it structurally requires a fresh build per
        // iteration (QA2/QA3/QA6 pin that carrier byte-for-byte). Kimi
        // native lane exempt for its tools-array refresh.
        let reuseTurnContext = !ridesNativeTools && appendOnlyEligible
        let onTurnContextBuilt: (@Sendable (TurnContext) -> Void)? =
            reuseTurnContext ? { @Sendable ctx in turnContextBox.set(ctx) } : nil

        // v2Prefix (2026-09-01) — the conversation-prefix shape FOR THIS TURN.
        //
        // v2 only engages on the reuse lane, and that is not a convenience:
        //   - the legacy GROWN-PROMPT shape carries the transcript inside
        //     `ctx.userMessage`, so there is no message array to put a prefix
        //     in at all;
        //   - the KIMI native lane deliberately rebuilds its context every
        //     iteration for its tools-array refresh, which is exactly the
        //     mid-turn prefix churn v2 exists to remove.
        // Both fall back to `.v1Legacy` for the whole turn — an honest v1 turn,
        // not a half-migrated one.
        let prefixShape: ConversationPrefixShape = reuseTurnContext
            ? (ConversationPrefixShape.override ?? .v1Legacy)
            : .v1Legacy
        var prefixTelemetry: ConversationPrefixTelemetrySnapshot?
        // What the seed ACTUALLY produced. `.v2Prefix` is only reached when a
        // replayed prefix exists; everything else (no history, kimi native,
        // grown-prompt compat) resolves to `.v1Legacy` and is re-bound below so
        // the body and the adapter's wire layout cannot disagree.
        var resolvedPrefixShape: ConversationPrefixShape = .v1Legacy
        // Where THIS turn's user message sits in `conversation`. 0 is correct
        // for every non-seeded shape here (grown-prompt and kimi both start the
        // array with the user message); the v2 seed overwrites it below.
        var resolvedCurrentUserIndex = 0
        // Image blocks ride the FIRST user message of the append-only
        // conversation (per-turn DYNAMIC). Later iterations append assistant +
        // tool-result user messages WITHOUT images — base64 is never re-sent.
        var conversation: [LLMMessage] = imageBlocks.isEmpty
            ? [.user(routedComposed)]
            : [.userWithImages(routedComposed, images: imageBlocks)]
        if prefixShape == .v2Prefix {
            // The volatile block IS the context's dynamic segment, so the
            // context has to exist before the messages it goes into. Build it
            // here, once, and hand it to iteration 1 as its preBuiltContext —
            // the same context every later iteration already reused.
            do {
                let built = try await ConversationPrefixShape.$override.withValue(.v2Prefix) {
                    try await HistoryWindowTurnFacts.$compactionRanThisTurn
                        .withValue(compactionRanThisTurn) {
                        // The SAME build path streamTurn takes — one owner,
                        // called a frame earlier so the volatile block exists
                        // before the message array it goes into.
                        try await engine.prepareTurnContext(
                            surface: surface,
                            userMessage: routedComposed,
                            sessionId: resolvedSession,
                            historyLimit: historyLimit,
                            historyReader: history,
                            personaOverride: persona,
                            excludeHistoryRunId: runId,
                            imageBlocks: imageBlocks,
                            queryUserMessage: message,
                            clockNowOverride: turnClockNow,
                            toolSchemaCatalogSeed: preloadToolSchemaCatalogSeed,
                            quietHoursSnapshot: quietHoursSnapshot,
                            turnPlan: turnPlan,
                            runtimeContext: cognitiveRuntimeContext,
                            turnActiveTools: turnActiveTools,
                            pinnedActiveTools: turnActiveTools,
                            // Same pin as the iterations that reuse this
                            // context. Without it the SEEDED first call would
                            // resolve the contract from a fresh store read and
                            // could differ from every later iteration — a
                            // mismatch at the exact byte the prefix cache keys.
                            pinnedContract: turnContract
                        )
                    }
                }
                // TEXT lane: the session-loaded catalog run is delivered in the
                // volatile block, not the cached prefix, so a mid-session
                // tool_load/promotion cannot invalidate the replayed history.
                // `textToolCompatibilityLayout` drops it from the system prompt
                // under the same v2 gate. `reuseTurnContext` already excludes
                // the native-tools lane, so this is always the prose lane.
                let seed = ConversationPrefixSeeding.seed(
                    built,
                    shape: .v2Prefix,
                    textToolCatalogAppendix: SwiftNativeTurnEngine
                        .textToolCatalogSections(
                            schemas: built.toolSchemas,
                            names: built.toolsAvailable
                        ).appended
                )
                resolvedPrefixShape = seed.shape
                resolvedCurrentUserIndex = seed.currentUserIndex
                // Iteration 1 now reads the SAME context every later
                // iteration already reused — the "one context per turn" pin,
                // extended to cover the turn's first provider call.
                turnContextBox.set(seed.context)
                conversation = seed.messages
                // ARCHIVE THIS TURN'S REPLAYABLE TAIL — every message the seed
                // placed AFTER the current user turn. A turn-scoped system
                // message is cleared once a later user message arrives (0 input
                // tokens) but must STAY in `messages` byte-for-byte; dropping it
                // made turn N+1's prefix diverge from turn N's immediately after
                // `user(N)`, so the previous turn's tool rounds and reply were
                // re-created at full price every turn.
                //
                // Taking the SEEDED MESSAGES rather than re-deriving them is the
                // point: what gets archived is exactly what went on the wire, so
                // the replay cannot drift from the original by a byte.
                let replayable = Array(seed.messages.dropFirst(seed.currentUserIndex + 1))
                if !replayable.isEmpty {
                    await TurnVolatileArchiveRegistry.shared
                        .archive(dataRoot: history.dataRoot)
                        .record(
                            sessionId: resolvedSession, runId: runId,
                            messages: replayable
                        )
                }
                // The window decision rides on the context (the cursor ran
                // once, inside the build), so this no longer costs a second
                // locked read of the cursor file.
                prefixTelemetry = ConversationPrefixSeeding.telemetry(
                    seed,
                    shape: .v2Prefix,
                    toolSchemaFingerprint: SwiftNativeTurnEngine
                        .toolSchemaFingerprint(seed.context.toolSchemas)
                )
            } catch is CancellationError {
                continuation.yield(.error("cancelled"))
                continuation.finish()
                return
            } catch {
                // Same terminal shape streamTurn's own build failure produces —
                // an honest error event, not a silent degrade to a shape the
                // caller did not ask for.
                let text = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                continuation.yield(.error(text))
                continuation.finish()
                return
            }
        }
        if let prefixTelemetry { ConversationPrefixTelemetry.sink?.set(prefixTelemetry) }
        // (b) Every provider call for the REST of this turn — every tool-loop
        // iteration's streamTurn — runs under the shape that was actually
        // seeded. Zero re-indent: the remainder of this function is the loop
        // plus its terminal persistence, and each `return` inside simply exits
        // the closure at the same point the function used to end.
        await ConversationPrefixShape.$override.withValue(resolvedPrefixShape) {
        // The authoritative current-turn seam for the adapter's cross-turn
        // marker. Without it the adapter anchored on the last `system` message,
        // which on a replayed prefix is an ARCHIVED block from an old turn —
        // so the 1h marker landed near the start of the conversation and cached
        // almost nothing. Within-turn rounds only append, so this index holds
        // for the whole turn.
        await ConversationPrefixBoundary.$currentUserIndex
            .withValue(resolvedCurrentUserIndex) {

        toolLoop: for iteration in 0..<maxToolIterations {
            // A6: observe the whole-turn ceiling only between iterations. An
            // active provider stream or tool dispatch always settles under
            // its own timeout contract; expiry then joins the existing
            // exhausted-loop fallback and persistence path below.
            if wholeTurnBudget.isExhausted {
                exhaustedToolLoop = true
                wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                break toolLoop
            }
            providerCallCount += 1
            var iterAccumulated = ""
            // User, 2026-09-06: bytes this attempt actually HANDED TO THE
            // SURFACE. The replay condition used to read `iterAccumulated`,
            // which counts text the compatibility buffer is still holding back
            // (up to 16 chars, or a marker candidate) — so a provider that sent
            // "Hello" and dropped had shown the user nothing yet was refused the
            // replay it qualified for, and the terminal branch then force-
            // flushed that held text as the whole reply.
            var iterFlushedToSurface = false
            var iterFinal: TurnEngineResult?
            var emptyReplyRecovery = false
            // Fresh per iteration — see NativeToolCallCollector's note.
            let nativeCollector = ridesNativeTools ? NativeToolCallCollector() : nil
            var nativeSink: (@Sendable (LLMStreamToolCall) async -> Void)?
            if let nativeCollector {
                nativeSink = { @Sendable call in await nativeCollector.append(call) }
            }
            // The typed failure behind this iteration's `.error(String)` event.
            // Fresh per iteration, so a previous attempt's error can never be
            // read as this one's. The engine calls the sink and returns before
            // it yields the matching event, so by the time the event is in hand
            // here the box holds the error the string was rendered from.
            let failureBox = StreamFailureBox()
            let failureSink: (@Sendable (any Error) -> Void) = { @Sendable err in
                failureBox.set(err)
            }
            let reusedTurnContext = reuseTurnContext ? turnContextBox.get() : nil
            // MEMORY-SAFETY (2026-07-04): pass turnActiveTools EXPLICITLY so
            // streamTurn binds it inside its own child Task. The old sync
            // `LLMCallContext.$turnActiveTools.withValue { engine.streamTurn(…) }`
            // wrap popped the task-local on THIS task while streamTurn's spawned
            // Task still referenced it → task-allocator LIFO violation ("freed
            // pointer was not the last allocation"), the deterministic release
            // crash on first chat (reproduced headlessly via chat-drive).
            // turn-context-iteration-cache (2026-08-13): pin the advertised
            // tool catalog to the turn-start set for the whole turn. Without
            // this, a mid-turn tool_load grew the catalog inside the STABLE
            // cache-breakpointed system segment on the next iteration's
            // rebuild — byte-diff-proven prefix kill (369k cache-creation
            // tokens on live turn 47ee5b6d). Dispatch still honors the store
            // per call and tool_load returns schemas_added, so a just-loaded
            // tool is usable THIS turn. The kimi native lane keeps the fresh
            // store read: its provider tools array is the only channel its
            // model can call a tool through, so next-iteration refresh is
            // load-bearing there (and its providers don't use Anthropic
            // prefix caching).
            let stream = engine.streamTurn(
                surface: surface,
                userMessage: appendOnlyEligible ? routedComposed : currentUserMessage,
                sessionId: resolvedSession,
                streamingLLM: streamingLLM,
                historyLimit: historyLimit,
                historyReader: history,
                personaOverride: persona,
                modelOverride: effectiveModel,
                reasoningEffortOverride: effectiveReasoningEffort,
                excludeHistoryRunId: runId,
                cancelFlagPath: cancelFlagPath,
                textToolCompatibility: true,
                conversation: appendOnlyEligible ? conversation : nil,
                turnPlan: turnPlan,
                runtimeContext: cognitiveRuntimeContext,
                providerIDOverride: nil,
                turnActiveTools: turnActiveTools,
                pinnedActiveTools: ridesNativeTools ? nil : turnActiveTools,
                pinnedContract: ridesNativeTools ? nil : turnContract,
                clockNowOverride: turnClockNow,
                toolSchemaCatalogSeed: preloadToolSchemaCatalogSeed,
                quietHoursSnapshot: quietHoursSnapshot,
                preBuiltContext: reusedTurnContext,
                onContextBuilt: onTurnContextBuilt,
                imageBlocks: imageBlocks,
                nativeTools: ridesNativeTools,
                nativeToolCallSink: nativeSink,
                // Relevance consumers see the RAW message; the tool-routing
                // hint (and any loop nudges grown onto currentUserMessage)
                // stay wire-only. Without this, the hint's tool names are
                // selection-query vocabulary on every text-compat turn.
                queryUserMessage: message,
                // User, 2026-09-06: the router shortens THIS call's wall to
                // what the turn can still afford, minus the reconnect
                // reserve — the structured loops already bind this. Without
                // it the wall (600s) equalled the interactive and Telegram
                // turn window, so one hung first call spent the whole budget
                // and the ladder below never got a second attempt.
                remainingTurnSeconds: { [wholeTurnBudget] in wholeTurnBudget.remainingSeconds },
                streamFailureSink: failureSink
            )
            providerCall: do {
                for try await event in stream {
                    if Task.isCancelled {
                        didCancel = true
                        break
                    }
                    switch event {
                    case .delta(let s):
                        if !s.isEmpty, !emittedProviderFirstDelta {
                            emittedProviderFirstDelta = true
                            TurnLifecycleTelemetry.emit(
                                .providerFirstDelta,
                                surface: surface,
                                sessionId: resolvedSession,
                                observedBy: "text_compat.stream"
                            )
                        }
                        iterAccumulated += s
                        if emitTextDeltas {
                            pendingDelta += s
                            let enqueued = Self.flushCompatibilityDeltaBuffer(
                                &pendingDelta,
                                force: false,
                                continuation: continuation
                            )
                            if enqueued {
                                iterFlushedToSurface = true
                                if await outputMilestoneGate.claim() {
                                    TurnLifecycleTelemetry.emit(
                                        .surfaceOutputEnqueued,
                                        surface: surface,
                                        sessionId: resolvedSession,
                                        observedBy: "text_compat.continuation"
                                    )
                                }
                            }
                        }
                    case .toolUse, .toolResult, .notice:
                        continuation.yield(event)
                    case .final(let r):
                        iterFinal = r
                        finalResult = r
                        if !r.recalledIds.isEmpty { lastRecalledIds = r.recalledIds }
                    case .error(let m):
                        if m == "cancelled" {
                            didCancel = true
                            continuation.yield(.error(m))
                            break   // breaks the switch; the producer finishes
                                    // after .error so the loop ends and the
                                    // didCancel block (~2171) persists cancelled:true
                        }
                        // User, 2026-09-06: the engine REFUSED to start a call
                        // this turn cannot pay for. That is the whole-turn
                        // budget ending, not a provider failure — take the same
                        // exhausted exit the loop head takes, so the turn ends
                        // on its fallback instead of through the reconnect
                        // ladder (which would replay a call there is equally no
                        // time for). The round-head increment counted a
                        // provider round that never happened; take it back.
                        if failureBox.get() is TurnBudgetSpentBeforeProviderCall {
                            exhaustedToolLoop = true
                            wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                            providerCallCount = max(0, providerCallCount - 1)
                            break toolLoop
                        }
                        // "no answer text" is the adapter's own grammar for a
                        // thinking-only empty 200/stream (emptyTextResponseError
                        // / the stream message_stop guard, both test-pinned).
                        // Recoverable in-loop: swallow the event (no .error
                        // reaches the surface), then nudge-continue below —
                        // an identical whole-turn replay is proven useless
                        // against this shape (13:08Z live, retried same-fail).
                        if m.contains("no answer text"),
                           iterAccumulated.isEmpty,
                           emptyReplyNudgeCount < 2 {
                            emptyReplyRecovery = true
                            break
                        }
                        // User, 2026-09-06: RECONNECT instead of dying. Classify
                        // the TYPED failure the engine handed the sink when it
                        // has one — an `LLMError.streamTruncated`, a URLError,
                        // whatever was actually thrown — and only fall back to
                        // wrapping the string when the failure had no type to
                        // carry. Replay the identical call when this attempt put
                        // NOTHING on the surface (no delta flushed; tool dispatch
                        // happens after the stream ends, so nothing was
                        // dispatched either). An attempt that already emitted
                        // output keeps the old behaviour: persist the partial and
                        // end the turn.
                        let classified: any Error = failureBox.get()
                            ?? LLMError.providerError(message: m)
                        if case .outputLengthLimit = classified as? LLMError {
                            reachedLengthLimit = true
                            accumulated = ToolCallParser.visiblePrefix(in: accumulated + iterAccumulated)
                            loopRecoveryReply = LLMError.outputLengthLimitNotice
                            exhaustedToolLoop = true
                            break toolLoop
                        }
                        if !iterFlushedToSurface,
                           providerCallAttempt < ProviderRecoveryPolicy.maxAttemptsPerCall,
                           providerTurnRecoveries < ProviderRecoveryPolicy.maxRecoveriesPerTurn,
                           ProviderRecoveryPolicy.isRecoverableTurnFailure(classified) {
                            providerReplayError = classified
                            break providerCall
                        }
                        // Provider failures arriving as ENGINE-YIELDED .error
                        // events bypassed the thrown-stream catch's post-tool-
                        // effect wrap below, so a surface retry ladder saw a
                        // bare retryable string and replayed already-run tools
                        // (gpt-5.5 BLOCKING, 2026-07-20 — the 13:08Z live error
                        // carried no marker despite 3 dispatches). Stamp the
                        // same cross-module marker contract here.
                        // User, 2026-09-06: count EFFECTFUL dispatches, as the
                        // thrown-error sibling below already does. Counting
                        // every dispatch stamped "tool effects present" on a
                        // turn whose only tools were read-only (inner_state,
                        // agent_introspect) and refused it the whole-turn
                        // replay it was safe to have.
                        let effectful = ProviderErrorAfterToolEffects.effectfulCount(dispatches)
                        let m = effectful == 0
                            ? m
                            : "provider failure after \(effectful) tool "
                              + "dispatch(es) [\(ProviderErrorAfterToolEffects.markerPhrase)]: \(m)"
                        // Real provider error mid-turn: TERMINAL. A plain `break`
                        // only exits the switch (Swift semantics), so the loop
                        // would fall through to ToolCallParser.parse (~2182) —
                        // dispatching a tool AFTER the turn already failed, and
                        // the no-marker path would persist the partial mislabeled
                        // as cancelled:true (~2311). Surface the error and persist
                        // the partial as a NON-cancel truncation. CRITICAL: stream
                        // + persist only the VISIBLE prose BEFORE any tool marker —
                        // a marker that was mid-emission when the stream failed must
                        // never render or persist as raw text (audit #1; the #6
                        // force-flush would otherwise leak it — gpt-5.5 review
                        // 2026-06-14).
                        if emitTextDeltas {
                            if let r = ToolCallParser.earliestPotentialProtocolMarker(in: pendingDelta) {
                                let safe = String(pendingDelta[..<r.lowerBound])
                                if !safe.isEmpty { continuation.yield(.delta(safe)) }
                            } else {
                                // force-flush: the compat buffer holds back a
                                // <=16-char tail, so a short reply like "Hello"
                                // would be lost on this early return otherwise.
                                let enqueued = Self.flushCompatibilityDeltaBuffer(
                                    &pendingDelta,
                                    force: true,
                                    continuation: continuation
                                )
                                if enqueued, await outputMilestoneGate.claim() {
                                    TurnLifecycleTelemetry.emit(
                                        .surfaceOutputEnqueued,
                                        surface: surface,
                                        sessionId: resolvedSession,
                                        observedBy: "text_compat.continuation"
                                    )
                                }
                            }
                            pendingDelta.removeAll(keepingCapacity: true)
                        }
                        continuation.yield(.error(m))
                        var partialVisible = ToolCallParser.visiblePrefix(in: accumulated + iterAccumulated)
                        // Transcript honesty, ENGINE-YIELDED error path (live
                        // 2026-07-20 16:19Z: a native-lane 400 died here with
                        // no stub, no trace — the turn just vanished; only the
                        // bridge event ring held the reason). Same stub the
                        // thrown-catch path persists.
                        if partialVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            partialVisible = "(reply failed before any text: \(String(m.prefix(240))))"
                        }
                        TurnTraceBus.fireFromContext(
                            kind: "turn.failed",
                            surface: surface,
                            payload: .object([
                                "reason": .string(String(m.prefix(200))),
                                "iteration": .int(Int64(iteration)),
                                "dispatchCount": .int(Int64(dispatches.count)),
                            ])
                        )
                        await persistCompatibilityPartial(partialVisible, cancelled: false)
                        continuation.finish()
                        return
                    }
                }
            } catch is CancellationError {
                didCancel = true
                TurnTraceBus.fireFromContext(
                    kind: "turn.cancelled", surface: surface,
                    payload: .object(["where": .string("text_compat.\(#line)")])
                )
                continuation.yield(.error("cancelled"))
            } catch {
                // Same ladder as the engine-yielded sibling above, on a TYPED
                // error — `isRecoverableTurnFailure` unwraps the two wrappers
                // this module owns, so no string round-trip is needed here
                // (User, 2026-09-06).
                if case .outputLengthLimit = error as? LLMError {
                    reachedLengthLimit = true
                    accumulated = ToolCallParser.visiblePrefix(in: accumulated + iterAccumulated)
                    loopRecoveryReply = LLMError.outputLengthLimitNotice
                    exhaustedToolLoop = true
                    break toolLoop
                }
                if !iterFlushedToSurface,
                   providerCallAttempt < ProviderRecoveryPolicy.maxAttemptsPerCall,
                   providerTurnRecoveries < ProviderRecoveryPolicy.maxRecoveriesPerTurn,
                   ProviderRecoveryPolicy.isRecoverableTurnFailure(error) {
                    providerReplayError = error
                    break providerCall
                }
                // Marker-wrap post-tool-effect failures so the surface retry
                // ladder (Telegram) sees "whole-turn retry unsafe" in the event
                // text and does not replay a turn whose tools already ran.
                let surfaced = ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: ProviderErrorAfterToolEffects.effectfulCount(dispatches))
                TurnTraceBus.fireFromContext(
                    kind: "turn.failed",
                    surface: surface,
                    payload: .object([
                        "reason": .string(String(String(describing: surfaced).prefix(200))),
                        "iteration": .int(Int64(iteration)),
                        "dispatchCount": .int(Int64(dispatches.count)),
                    ])
                )
                continuation.yield(.error("stream error: \(surfaced)"))
                // accumulated only absorbs an iteration's text after it
                // completes call-free; the text the user just watched render
                // is still in iterAccumulated. Persist both, or a mid-stream
                // provider error silently loses the whole partial reply.
                var partialVisible = ToolCallParser.visiblePrefix(in: accumulated + iterAccumulated)
                // Transcript honesty (2026-07-19 Kimi 403 incident): a turn
                // that dies BEFORE any text leaves a hole in the session —
                // the next turn's history shows User's message with no reply
                // and the model has no idea the failure happened. Persist a
                // short honest stub so the conversation itself carries the
                // failure, on every surface.
                if partialVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let reason = (surfaced as? LocalizedError)?.errorDescription
                        ?? String(describing: surfaced)
                    partialVisible = "(reply failed before any text: \(String(reason.prefix(240))))"
                }
                await persistCompatibilityPartial(partialVisible, cancelled: false)
                continuation.finish()
                return
            }
            // The ladder. Same budgets, same backoff, same Retry-After rule and
            // the same `provider_retry` notice the structured loops emit; the
            // replay itself is `continue toolLoop`, which re-runs the identical
            // provider call with the iteration-scoped accumulators rebuilt
            // (that is exactly what the empty-reply recovery below already
            // does). A replay spends one tool-loop iteration.
            if let replayError = providerReplayError {
                providerReplayError = nil
                // User, 2026-09-06: a replay costs one tool-loop iteration, so on
                // the LAST one there is nothing to replay into — `continue
                // toolLoop` would just end the loop with `exhaustedToolLoop`
                // unset, and the post-loop branch would persist an empty partial
                // as `cancelled: true`: a provider drop reported to the user as a
                // Stop the user never pressed. Don't schedule what cannot run —
                // no notice, no sleep — and leave through the exhausted path
                // carrying the failure as the reason.
                if iteration + 1 >= maxToolIterations {
                    loopRecoveryReply = "(provider failed on the last of "
                        + "\(maxToolIterations) tool-loop iterations, with no "
                        + "iteration left to reconnect into: "
                        + "\(String(ProviderRecoveryPolicy.describe(replayError).prefix(200))))"
                    exhaustedToolLoop = true
                    break toolLoop
                }
                let delaySeconds = ProviderRecoveryPolicy.retryDelaySeconds(
                    forRetry: providerCallAttempt, error: replayError
                )
                let remainingBudget = wholeTurnBudget.remainingSeconds
                if delaySeconds >= remainingBudget {
                    if let notice = ProviderRecoveryPolicy.retryAfterBeyondBudgetNotice(
                        for: replayError, remainingSeconds: remainingBudget
                    ) {
                        continuation.yield(.notice(
                            kind: "provider_retry",
                            text: notice
                        ))
                    }
                    exhaustedToolLoop = true
                    wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                    break toolLoop
                }
                providerTurnRecoveries += 1
                ProviderRetryTrace.emit(
                    error: replayError, attempt: providerCallAttempt,
                    delaySeconds: delaySeconds, mode: "replay",
                    turnRecoveries: providerTurnRecoveries, surface: surface
                )
                // Cancellation outranks recovery, by Task state and by the
                // cross-process flag — same order as the structured ladder.
                // This lane cannot throw (the producer body is non-throwing),
                // so a Stop sets didCancel and falls into the persistence
                // block below instead of unwinding.
                let stopped = { Task.isCancelled
                    || FileManager.default.fileExists(atPath: cancelFlagPath.path) }
                if stopped() {
                    didCancel = true
                } else {
                    // A silent reconnect looks identical to a hang. After the
                    // cancellation check so a Stop never leaves "reconnecting"
                    // as the last thing the surface said, before the backoff so
                    // it stands for the whole wait.
                    continuation.yield(.notice(
                        kind: "provider_retry",
                        text: ProviderRecoveryPolicy.reconnectStatus(
                            attemptsMade: providerCallAttempt
                        )
                    ))
                    try? await engine.providerRecoverySleep(delaySeconds)
                    if stopped() {
                        didCancel = true
                    } else {
                        providerCallAttempt += 1
                        // The dropped attempt is discarded WHOLE, so the text
                        // the buffer is still holding back goes with it — the
                        // re-issued call emits its own bytes, and keeping these
                        // would render the same fragment twice.
                        pendingDelta.removeAll(keepingCapacity: true)
                        // The loop head re-checks the whole-turn budget, so an
                        // expired budget ends on the exhausted path rather than
                        // starting one more attempt.
                        continue toolLoop
                    }
                }
            } else {
                providerCallAttempt = 1
            }
            if didCancel {
                let partialVisible = ToolCallParser.visiblePrefix(in: accumulated + iterAccumulated)
                await persistCompatibilityPartial(partialVisible, cancelled: true)
                continuation.finish()
                return
            }

            if emptyReplyRecovery {
                emptyReplyNudgeCount += 1
                finalResult = nil
                sawFinal = false
                pendingDelta.removeAll(keepingCapacity: true)
                // Lane-aware: telling a native-tools model to emit marker text
                // would instruct it to produce output this lane no longer
                // parses — the nudge would actively cause the next failure.
                // The TEXT-lane string is BYTE-IDENTICAL to the pre-native-lane
                // wording (gpt-5.5 blocking, 2026-07-20: a lane-generic rewrite
                // silently changed provider-visible text for every non-kimi
                // provider on the recovery path).
                let feedback = Self.textCompatibilityEmptyReplyFeedback(
                    ridesNativeTools: ridesNativeTools
                )
                if ridesNativeTools || appendOnlyEligible {
                    // Merge into the trailing user message and keep the v2 volatile
                    // system tail in place; both structured transports use this rule.
                    Self.appendNativeUserText(feedback, to: &conversation)
                } else {
                    currentUserMessage += "\n\n" + feedback
                }
                continue toolLoop
            }
            // NATIVE LANE: the structured tool calls the provider actually
            // emitted this iteration, in wire order. Empty on the text lane.
            let nativeCalls = await nativeCollector?.drain() ?? []
            if ridesNativeTools {
                // The marker protocol is NOT this lane's contract, so a reply
                // that merely LOOKS like a formatted marker is ordinary prose
                // here — running the violation detector would bounce valid
                // answers (e.g. the model explaining tool syntax to the user).
                lastProtocolViolation = nil
            } else if let violation = ToolCallParser.formattedToolCallViolation(in: iterAccumulated) {
                lastProtocolViolation = violation
                violationNudgeCount += 1
                if violationNudgeCount > 2 {
                    exhaustedToolLoop = true
                    break toolLoop
                }
                finalResult = nil
                sawFinal = false
                pendingDelta.removeAll(keepingCapacity: true)
                if iteration == maxToolIterations - 1 {
                    exhaustedToolLoop = true
                }
                if appendOnlyEligible {
                    conversation.append(.assistantText(iterAccumulated))
                    conversation.append(.user(violation.modelFeedback))
                } else {
                    currentUserMessage += "\n\n" + ToolCallParser.feedbackIncludingRejectedOutput(
                        iterAccumulated,
                        violation: violation
                    )
                }
                // 2026-09-06: deliberately NOT absorbed into `accumulated` —
                // this round's prose is the rejected output the bounce exists
                // to replace, and keeping it would ship the malformed attempt
                // alongside the retry's real answer.
                continue toolLoop
            }
            if !ridesNativeTools { lastProtocolViolation = nil }
            // ONE `calls` list feeds ONE dispatch block for both lanes. Native
            // tool_use blocks are mapped into the same ParsedToolCall shape the
            // marker parser produces, so dispatch keeps the identical gating,
            // dispatch records, transcript rows and tool.dispatch traces — only
            // the way the call was DECLARED on the wire differs.
            let calls = Self.textCompatibilityCalls(
                nativeCalls: nativeCalls,
                ridesNativeTools: ridesNativeTools,
                iterAccumulated: iterAccumulated
            )
            if calls.isEmpty {
                // Completion-contract guard (2026-07-19; round 2 after the
                // live incident showed round 1 was too narrow): a final reply
                // that is in-progress-shaped ("reading the README now") is not
                // a valid stopping point in an agent runtime with NO background
                // execution — whether or not tools already ran this turn (the
                // real miss: two dispatches, then narration, then stop). Bounce
                // through the violation-feedback plumbing, at most TWICE per
                // turn; a third promise is accepted as final so a model that
                // refuses to act can never loop. Worst case = 2 extra provider
                // calls on a turn that was already broken for the user.
                // R7 rides the same bounce: `**Tool: desk_read**` as the whole
                // reply is an attempted call that never left the text channel.
                if announceNudgeCount < 2, !preloadAvailableNames.isEmpty,
                   ToolCallParser.looksLikeUnfulfilledActionPromise(iterAccumulated)
                    || ToolCallParser.looksLikeNarratedToolInvocation(
                        iterAccumulated,
                        knownToolNames: preloadAvailableNames.union(turnActiveTools)
                    ) {
                    announceNudgeCount += 1
                    finalResult = nil
                    sawFinal = false
                    pendingDelta.removeAll(keepingCapacity: true)
                    let feedback = Self.textCompatibilityAnnounceFeedback(
                        turnActiveTools: turnActiveTools,
                        preloadAvailableNames: preloadAvailableNames,
                        ridesNativeTools: ridesNativeTools,
                        announceNudgeCount: announceNudgeCount
                    )
                    if appendOnlyEligible {
                        conversation.append(.assistantText(iterAccumulated))
                        conversation.append(.user(feedback))
                    } else {
                        currentUserMessage += "\n\n" + feedback
                    }
                    // 2026-09-06: deliberately NOT absorbed into `accumulated`
                    // — the narration this bounce rejected is the thing the
                    // user must not be shown, so the retry's reply stands
                    // alone.
                    continue toolLoop
                }
                // Marker stripping is a TEXT-lane concern. On the native lane
                // the model's prose is just prose — rewriting it because it
                // happens to contain marker-shaped text would corrupt a
                // legitimate answer (e.g. one that quotes tool syntax).
                let ignoredOnly = ridesNativeTools
                    ? false
                    : ToolCallParser.containsOnlyIgnorableCalls(iterAccumulated)
                let visibleIteration = ignoredOnly
                    ? ToolCallParser.stripToolUseMarkers(iterAccumulated)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : iterAccumulated
                sawFinal = iterFinal != nil
                accumulated = Self.absorbingVisibleRound(accumulated, visibleIteration)
                if emitTextDeltas {
                    if ignoredOnly {
                        pendingDelta = ToolCallParser.stripToolUseMarkers(pendingDelta)
                    }
                    let enqueued = Self.flushCompatibilityDeltaBuffer(
                        &pendingDelta,
                        force: true,
                        continuation: continuation
                    )
                    if enqueued, await outputMilestoneGate.claim() {
                        TurnLifecycleTelemetry.emit(
                            .surfaceOutputEnqueued,
                            surface: surface,
                            sessionId: resolvedSession,
                            observedBy: "text_compat.continuation"
                        )
                    }
                }
                if let r = iterFinal {
                    let finalWithDispatches = Self.turnResult(
                        r,
                        replacingToolDispatchesWith: dispatches,
                        rawLLMResponse: accumulated.isEmpty ? r.rawLLMResponse : accumulated,
                        providerCallCount: providerCallCount,
                        elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- turnStartNs) / 1_000_000),
                        replyOverride: ignoredOnly ? visibleIteration : nil
                    )
                    finalResult = finalWithDispatches
                    continuation.yield(.final(finalWithDispatches))
                }
                break toolLoop
            }
            pendingDelta.removeAll(keepingCapacity: true)
            // User, 2026-09-06: this round NARRATED before it called its tools,
            // and the user watched that prose render. Absorb it now, before the
            // dispatch, so `accumulated` is the whole visible reply and not just
            // its last call-free round — the exhaustion composition below reads
            // it, and used to find it empty after any narrated tool round and
            // persist the fallback line alone. Markers are stripped on the text
            // lane only; on the native lane the model's prose is just prose.
            accumulated = Self.absorbingVisibleRound(
                accumulated,
                ridesNativeTools
                    ? iterAccumulated
                    : ToolCallParser.stripToolUseMarkers(iterAccumulated)
            )

            if iteration == maxToolIterations - 1 {
                exhaustedToolLoop = true
            }

            // U1 item 9: the model's raw reply (prose + markers, exactly as
            // emitted) becomes the appended assistant message; this
            // iteration's tool results accumulate into ONE user message
            // appended after the dispatch loop. The per-call result text is
            // the SAME literal the grown shape appends — only the carrier
            // changes (new message vs string growth).
            //
            // PARALLEL DISPATCH (A1, 2026-08-28): the follow-up the old
            // "SERIAL DISPATCH — INTENTIONAL" note named (u1-performance-core
            // Decisions, 2026-06-11) is now taken. This path no longer owns a
            // dispatch loop: it hands its prepared calls to the SAME
            // `runIterationDispatchGroups` behind ToolLoop's
            // dispatchIterationCalls, so the fail-closed ParallelToolDispatch
            // veto table, the fleet cwd overrides and the
            // NATIVE_AGENT_SERIAL_TOOL_DISPATCH escape hatch are ONE
            // implementation for every lane. Yield order is the structured
            // contract: .toolUse for a concurrent group up-front in index
            // order, .toolResult per slot in index order as the group lands.
            // Slot FINALIZATION stays here — the prose carrier and the native
            // tool_result/tool_use block shapes below are this lane's format,
            // not the structured lane's.
            var iterationToolResults = ""
            // NATIVE LANE: the append-only conversation carries real content
            // blocks instead of prose. The assistant message replays the
            // model's own tool_use blocks (its ORIGINAL argument bytes, not our
            // session-injected dispatch input — the transcript must say what
            // the model said), and the following user message carries one
            // tool_result per call, paired by tool_use_id (P0 shape B).
            var nativeToolUseBlocks: [LLMContentBlock] = []
            var nativeToolResultBlocks: [LLMContentBlock] = []
            let iterationDispatchStart = dispatches.count

            // Same deadline/runtime/notice dispatch core as the structured
            // loops (this closed the former Claude text-compat carve where an
            // interactive tool could hang forever) — now reached through the
            // shared group runner rather than one call at a time.
            let preparedCalls = calls.map { call in
                SwiftNativeTurnEngine.PreparedToolCall(
                    pairedId: call.id,
                    internalName: call.name,
                    dispatchInput: Self.inputWithSessionIfNeeded(
                        toolName: call.name,
                        input: call.input,
                        sessionId: resolvedSession
                    )
                )
            }

            // A2 (2026-08-28): transcript receipts leave the dispatch critical
            // path. Rows are ENQUEUED in call order as each slot lands and
            // drained by ONE serial writer that overlaps the remaining
            // dispatch, so no tool call ever blocks on the previous call's
            // disk write. Write order is therefore CALL order, never
            // completion order. The M2 fail-loud receipt contract is intact:
            // a failed write still raises the same user-visible notice, and
            // the writer is awaited before the iteration continues so the
            // notice cannot outlive the turn (silent receipt loss is a
            // previously-fixed bug class — see the catch below).
            let (receiptRows, receiptSink) = AsyncStream<TextCompatToolReceipt>.makeStream()
            let receiptWriter = Task { [runId, surface, resolvedSession] in
                await self.writeTextCompatToolReceipts(
                    receiptRows, resolvedSession: resolvedSession, runId: runId,
                    surface: surface, continuation: continuation
                )
            }

            let slots = await LLMCallContext.$turnActiveTools.withValue(turnActiveTools) {
                await SwiftNativeTurnEngine.runIterationDispatchGroups(
                    prepared: preparedCalls,
                    modelId: model,
                    surface: surface,
                    tools: gated,
                    progress: { event in
                        if case .notice(let kind, let text) = event {
                            continuation.yield(.notice(kind: kind, text: text))
                        }
                    },
                    imagesEnabled: appendOnlyEligible,
                    cancelFlagPath: cancelFlagPath,
                    onToolUse: { prepared in
                        continuation.yield(.toolUse(
                            name: prepared.internalName,
                            input: ChatSecretRedactor.redactValue(.object(prepared.dispatchInput))
                        ))
                    },
                    onOutcome: { prepared, result, isError in
                        let redactedResult = ChatSecretRedactor.redactValue(result)
                        continuation.yield(.toolResult(
                            name: prepared.internalName,
                            output: redactedResult
                        ))
                        let redactedInput = ChatSecretRedactor.redactValue(
                            .object(prepared.dispatchInput)
                        )
                        receiptSink.yield(TextCompatToolReceipt(
                            toolName: prepared.internalName,
                            inputJSON: (try? redactedInput.serialize(pretty: false)) ?? "{}",
                            resultJSON: (try? redactedResult.serialize(pretty: false)) ?? "null",
                            ok: !isError,
                            redactedResult: redactedResult
                        ))
                    }
                )
            }
            receiptSink.finish()

            for slot in slots {
                let index = slot.index
                let call = slot.prepared
                let redactedResult = ChatSecretRedactor.redactValue(slot.result)
                let ok = !slot.isError
                dispatches.append(TurnEngineResult.ToolDispatchRecord(
                    id: call.pairedId,
                    name: call.internalName,
                    input: call.dispatchInput,
                    result: slot.result
                ))
                let resultJSON = (try? redactedResult.serialize(pretty: false)) ?? "null"
                let providerResultJSON = await ProviderToolResultProjection.project(
                    toolName: call.internalName,
                    content: resultJSON,
                    sessionId: resolvedSession,
                    turnId: TurnTraceContext.turnId
                )
                let toolResultBlock = """

                NativeAgent tool result for \(call.internalName):
                \(providerResultJSON)
                Use this verified result. If more action is needed, emit another exact <tool_use name="...">{...}</tool_use> marker; otherwise answer the user directly.
                """
                if ridesNativeTools {
                    if index < nativeCalls.count {
                        let native = nativeCalls[index]
                        // Replayed tool_use blocks go back over the wire next
                        // iteration, and the collector holds INTERNAL names
                        // (the sink reverse-maps before dispatch). Re-sanitize
                        // for the wire — Kimi validates name characters in
                        // blocks exactly like the tools array (the live 400).
                        // Static transform, not the per-iteration map: a
                        // collision-suffixed alias would differ, but the
                        // provider validates CHARACTERS, not catalog
                        // membership, and history may legitimately reference
                        // unloaded tools.
                        nativeToolUseBlocks.append(.toolUse(
                            id: native.id,
                            name: ProviderToolNameMap.providerName(for: native.name),
                            inputJSON: native.inputJSON
                        ))
                    }
                    nativeToolResultBlocks.append(.toolResult(
                        toolUseId: call.pairedId,
                        content: providerResultJSON,
                        isError: !ok
                    ))
                } else if appendOnlyEligible {
                    iterationToolResults += toolResultBlock
                } else {
                    currentUserMessage += toolResultBlock
                }
            }
            // Receipts must be durable (or their loss reported) before the
            // next provider call — the write is off the dispatch critical
            // path, not off the turn.
            await receiptWriter.value

            // A6 progress extension (same rule as both structured loops): a
            // round that landed at least one real tool result re-earns the
            // surface window, capped at the unattended ceiling. `slot.isError`
            // is the SAME classification the structured lane reads through
            // ChatToolOutcome.outputLooksSuccessful — an all-errored round is
            // the stuck case the budget exists to kill and extends nothing.
            // User, 2026-09-06: and an approval FILED is not a tool that ran —
            // same rule as the structured lane.
            if slots.contains(where: {
                !$0.isError && !ChatToolOutcome.isWaitingApproval($0.result)
            }) {
                wholeTurnBudget.recordProgress()
            }

            var stopForNoProgress = false
            let iterationRecords = Array(dispatches[iterationDispatchStart...])
            ChatTurnExecution.current?.keepTools(iterationRecords)
            if surface == "bot", iterationRecords.contains(where: { ChatToolOutcome.isWaitingApproval($0.result) }) {
                ChatTurnExecution.current?.waitForApproval()
                break
            }
            switch noProgressGuard.observe(iterationRecords) {
            case .none:
                break
            case .warn(let feedback):
                continuation.yield(.notice(kind: "tool_loop_recovery", text: feedback))
                // 2026-07-21 audit fix: model-directed WARN guidance must
                // reach the MODEL, not just the user (see the structured
                // loop's matching fix) — ride it on the SAME user message as
                // the tool results, like the stop branch's recovery block.
                let warnBlock = "\n\nNativeAgent recovery guidance:\n\(feedback)"
                if ridesNativeTools {
                    nativeToolResultBlocks.append(.text(warnBlock))
                } else if appendOnlyEligible { iterationToolResults += warnBlock }
                else { currentUserMessage += warnBlock }
            case .stop(let feedback):
                let block = "\n\nNativeAgent recovery guidance:\n\(feedback)"
                if ridesNativeTools {
                    // Rides as a trailing text block on the SAME user message
                    // as the tool_results — Anthropic allows mixed blocks, and
                    // a separate message would break tool_result adjacency.
                    nativeToolResultBlocks.append(.text(block))
                } else if appendOnlyEligible { iterationToolResults += block }
                else { currentUserMessage += block }
                loopRecoveryReply = feedback
                exhaustedToolLoop = true
                stopForNoProgress = true
            }

            if ridesNativeTools {
                // Assistant turn = its prose (if any) THEN its tool_use blocks.
                // A tool-only response legitimately has no text at all (P0
                // contract note 1) — the adapter's encoder drops empty text
                // blocks, so we can append unconditionally.
                var assistantBlocks: [LLMContentBlock] = []
                if !iterAccumulated.isEmpty { assistantBlocks.append(.text(iterAccumulated)) }
                assistantBlocks.append(contentsOf: nativeToolUseBlocks)
                conversation.append(LLMMessage(role: .assistant, content: assistantBlocks))
                conversation.append(contentsOf: LocalToolImage.continuation(
                    nativeToolResultBlocks + slots.flatMap(\.images)))
            } else if appendOnlyEligible {
                conversation.append(.assistantText(iterAccumulated))
                conversation.append(contentsOf: LocalToolImage.continuation(
                    [.text(iterationToolResults)] + slots.flatMap(\.images)))
            }
            LocalToolImage.boundConversation(&conversation)
            if stopForNoProgress { break toolLoop }
        }

        if reachedLengthLimit && (Task.isCancelled || FileManager.default.fileExists(atPath: cancelFlagPath.path)) {
            await persistCompatibilityPartial(accumulated, cancelled: true)
            continuation.yield(.error("cancelled"))
            continuation.finish()
            return
        }

        if exhaustedToolLoop && !sawFinal {
            let exhaustionReply = loopRecoveryReply ?? lastProtocolViolation?.terminalReply
                ?? ToolLoopExhaustion.fallbackReply(
                    iterationLimit: maxToolIterations,
                    dispatchCount: dispatches.count,
                    providerRounds: providerCallCount,
                    wallClockElapsedSeconds: wallClockElapsedSeconds
                )
            // User, 2026-09-06: same rule as the structured lane's
            // finishExhaustedTurn — the exhaustion line EXPLAINS the stop, it
            // never REPLACES prose the user already watched render. `accumulated`
            // is the marker-stripped visible text of the rounds that completed,
            // so an exhaustion after narrated tool rounds used to persist the
            // fallback alone and the narration vanished on reload.
            let shown = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = shown.isEmpty ? exhaustionReply : shown + "\n\n" + exhaustionReply
            let fallbackResult = TurnEngineResult(
                reply: fallback,
                modelUsed: finalResult?.modelUsed ?? effectiveModel,
                recalledIds: finalResult?.recalledIds ?? lastRecalledIds,
                toolDispatches: dispatches,
                elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- turnStartNs) / 1_000_000),
                rawLLMResponse: finalResult?.rawLLMResponse ?? accumulated,
                providerCallCount: providerCallCount,
                terminalObservation: finalResult?.terminalObservation,
                completionState: reachedLengthLimit ? .incomplete : nil
            )
            finalResult = fallbackResult
            continuation.yield(.final(fallbackResult))
        }

        if !sawFinal && !exhaustedToolLoop && (Task.isCancelled || finalResult == nil) {
            await persistCompatibilityPartial(accumulated, cancelled: true)
            continuation.finish()
            return
        }

        // R-F1: every failure path above (mid-stream provider error, thrown
        // stream error, cancel, no-final bailout) returned early — reaching
        // here means the provider accepted the turn (a final reply, or an
        // exhausted tool loop whose provider calls all carried the capsule).
        // Commit the projection exactly once, now.
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession
        )

        await persistTextCompatibilityCompletion(
            finalResult: finalResult,
            accumulated: accumulated,
            resolvedSession: resolvedSession,
            runId: runId,
            message: message,
            persona: persona,
            surface: surface,
            continuation: continuation
        )
        continuation.finish()
        } // ConversationPrefixBoundary.$currentUserIndex.withValue
        } // ConversationPrefixShape.$override.withValue (resolved seed shape)
        } // ConversationPrefixShape.$override.withValue (turn entry)
    }

}
