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

struct ResidentTurnPreparation: Sendable {
    let turnPlan: TurnPlan?
    let cognitiveProjection: CognitiveTurnProjection?
}

private actor ToolProgressPersistenceBuffer {
    struct RecordableToolResult: Sendable {
        let name: String
        let input: JSONValue
        let output: JSONValue
        let ok: Bool
    }

    private var pendingInputs: [String: [JSONValue]] = [:]

    func recordableToolResult(from event: TurnStreamEvent) -> RecordableToolResult? {
        switch event {
        case .toolUse(let name, let input):
            pendingInputs[name, default: []].append(input)
            return nil
        case .toolResult(let name, let output):
            let input = popInput(for: name) ?? .object([:])
            return RecordableToolResult(
                name: name,
                input: input,
                output: output,
                ok: ChatToolOutcome.outputLooksSuccessful(output)
            )
        case .delta, .final, .error, .notice:
            // .notice is ephemeral in-turn status — never persisted.
            return nil
        }
    }

    private func popInput(for name: String) -> JSONValue? {
        guard var values = pendingInputs[name], !values.isEmpty else { return nil }
        let first = values.removeFirst()
        pendingInputs[name] = values.isEmpty ? nil : values
        return first
    }

    // Failure-shape heuristic moved to ChatToolOutcome.outputLooksSuccessful
    // (ChatToolDispatchTrace.swift) — the trace recorder must classify
    // identically to these persisted rows.
}

extension SwiftNativeChatOrchestrationClient {
    func emitMetacognitiveTerminalTrace(
        turnId: String,
        sessionId: String,
        surface: String,
        context: TurnContext?,
        result: TurnEngineResult
    ) {
        // User, 2026-09-06: a slot a Stop reached never ran, so it is not a
        // failed dispatch. Its synthetic envelope carries an `error` string for
        // the model to read, which is exactly what `outputLooksSuccessful`
        // fails on — so a stopped batch reported its untried calls as failures.
        let failed = result.toolDispatches.filter {
            !ChatToolOutcome.outputLooksSuccessful($0.result)
                && !ChatToolOutcome.wasCancelled($0.result)
        }.count
        let expansions = result.toolDispatches.filter { $0.name == "context_expand" }.count
        var payload: [String: JSONValue] = [
            "schema": .string("metacognition.observed.v1"),
            "status": .string("completed"),
            "modelUsed": .string(result.modelUsed),
            "turnElapsedMs": .int(Int64(max(0, result.elapsedMs))),
            "recalledMemoryCount": .int(Int64(result.recalledIds.count)),
            "toolDispatchCount": .int(Int64(result.toolDispatches.count)),
            "failedToolDispatchCount": .int(Int64(failed)),
            "contextExpansionCount": .int(Int64(expansions)),
        ]
        let observation = context.map(TurnEngineResult.TerminalObservation.init(context:))
            ?? result.terminalObservation
        if let observation {
            payload["reasoningEffort"] = .string(observation.reasoningEffort)
            payload["toolSchemaCount"] = .int(Int64(observation.toolSchemaCount))
            payload["contextSource"] = .string(observation.contextSource)
            payload["contextSelectedAtomCount"] = .int(Int64(observation.contextSelectedAtomCount))
            payload["contextPacketCharacters"] = .int(Int64(observation.contextPacketCharacters))
            payload["contextExpandablePointerCount"] = .int(Int64(observation.contextExpandablePointerCount))
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId,
            kind: "turn.terminal",
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        ), on: turnTraceBus)
    }

    func executeStructuredChat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        persistToolMessages: Bool,
        progress: ChatOrchestrationProgressHandler?,
        noticeSink: @escaping @Sendable (String, String) async -> Void
    ) async throws -> StructuredChatExecution {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Suppressed-append turns adopt the enqueue-time runId (see
        // ChatPersistenceContext.pinnedTurnRunID) so history exclusion and
        // user/assistant row correlation match the normal path exactly.
        let runId = (suppressUserAppend ? ChatPersistenceContext.pinnedTurnRunID : nil)
            ?? UUID().uuidString
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        // B7 (review round 2, MED): derive + clear the per-session cancel flag
        // AT TURN ACCEPT — before the user append and autocompact awaits — so
        // the window where a cross-process Stop meant for THIS turn could be
        // wiped is effectively zero, while a stale flag from a prior turn still
        // cannot kill this one. The loop polls the same path per iteration.
        let cancelFlagPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(resolvedSession, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
        try? FileManager.default.removeItem(at: cancelFlagPath)

        // Native vision: convert image attachments to per-turn DYNAMIC image
        // content blocks on the CURRENT user message. Raw `message` text goes
        // to the model (no stringified suffix); non-image attachments and
        // empty-base64 entries are skipped. Empty → byte-identical wire shape.
        // 2026-09-06: routed through the Trust ▸ Multimodal gates, which also
        // put an attached PDF's text into the turn. `modelMessage` is the model
        // -facing text only — the PERSISTED user row below keeps `message`.
        let attachmentInput = Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot)
        let imageBlocks = attachmentInput.imageBlocks
        let modelMessage = attachmentInput.userMessage

        // 1. Persist the user turn unless suppressed.
        if !suppressUserAppend {
            try await appendMessage(
                sessionId: resolvedSession,
                role: "user",
                content: message,
                runId: runId,
                attachments: attachments,
                persona: persona,
                source: surface
            )
        }

        // The window cursor must not slide in a turn the autocompactor already
        // rewrote — two rewrites of the same prefix in one turn pays the cache
        // write premium twice for one turn's worth of savings. The text lane
        // carries this the same way; discarding the outcome here let compaction
        // and a cursor advance both reshape the prefix on the same turn.
        var compactionRanThisTurn = false
        do {
            compactionRanThisTurn = try await prepareSessionHistoryForTurn(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch {
            // Two turns died silently on 2026-09-05 (00:34, 10:12) with no trace
            // after their last tool; a cancellation left nothing on paper.
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object(["where": .string("structured_chat.\(#line)")])
            )
            throw CancellationError()
        }

        // 2. Build wrapped tool dispatcher: fileAccess gate → autonomy gate → real tools.
        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        let boundTurnId = StructuredTurnTraceIdentity.currentOrMint()
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "structured_chat.entry",
            turnId: boundTurnId,
            on: turnTraceBus
        )
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            fileAccess: fileAccess
        )
        // TURN START: advance the session turn clock and batch-drop tools that
        // went unused for two completed turns, before anything reads the
        // catalog. Drops only ever happen here — never mid-turn.
        async let sessionActiveToolsTask = activeToolsStore.beginTurn(sessionId: resolvedSession)

        // 3. Pre-resolve the context with history threading so the engine call
        //    inherits prior turns. We THREAD this into executeTurnWithToolLoop
        //    via preBuiltContext — otherwise the loop would rebuild a fresh
        //    context without history and discard our prior-turn work.
        //    PROPAGATE failures: the history reader inside already degrades
        //    gracefully on its own, so a throw here means persona/router is
        //    broken — swallowing it (try?) ran the turn with amnesia on the
        //    default model with no signal (audit 2026-06-09). The user turn
        //    is already persisted above, so give the failure the same
        //    persist-then-rethrow treatment the engine call below gets.
        // Mind-into-circulation follow-up (2026-07-10): mint the turn id
        // BEFORE the context build and bind it around build + engine alike.
        // The old binding started at the engine call, so `context.summary`
        // (emitted inside buildTurnContext) fired with NO bound turnId and was
        // silently dropped on every non-streaming turn — bridge/claude turns
        // had no context trace at all, blinding the Observatory fallback chip
        // and the attention trace counts on exactly those turns.
        let threadedCtx: TurnContext
        do {
            threadedCtx = try await HistoryWindowTurnFacts
                .$compactionRanThisTurn.withValue(compactionRanThisTurn) {
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: modelMessage,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    // The /new carry-over: on this session's FIRST turn only,
                    // two lines naming the previous session on THIS surface
                    // and the call that reopens it. Same data root as the
                    // history reader, so a fixture-rooted test never reads
                    // the live index.
                    sessionDigest: SessionDigestProvider(dataRoot: history.dataRoot),
                    imageBlocks: imageBlocks
                )
            }
            }
            }
        } catch is CancellationError {
            // Two turns died silently on 2026-09-05 (00:34, 10:12) with no trace
            // after their last tool; a cancellation left nothing on paper.
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object(["where": .string("structured_chat.\(#line)")])
            )
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    persona: persona
                )
            }
            throw ChatOrchestrationError.underlying(message)
        }
        let residentPreparation = await residentPreparationTask
        let turnPlan = residentPreparation.turnPlan
        let threadedCtxWithTurnPlan = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            threadedCtx,
            turnPlan: turnPlan
        )
        let threadedCtxWithOverrides = Self.applyChatOverrides(
            to: threadedCtxWithTurnPlan,
            model: model,
            reasoningEffort: reasoningEffort
        )
        if let turnPlan {
            await TurnPlanTraceRecorder.append(
                turnPlan,
                runId: runId,
                surface: surface,
                dataRoot: dataRoot,
                turnId: boundTurnId,
                turnTraceBus: turnTraceBus
            )
        }
        let (threadedCtxWithCognition, pendingProjectionCommit) = await contextByAppendingCognitiveCapsule(
            to: threadedCtxWithOverrides,
            surface: surface,
            userMessage: message,
            runId: runId,
            sessionId: resolvedSession,
            fileAccess: fileAccess,
            projection: residentPreparation.cognitiveProjection
        )
        let sessionLoadout = await sessionActiveToolsTask
        let sessionActiveTools = sessionLoadout.activeTools
        let preloadPrediction = turnPlan?.preloadPrediction
            ?? ToolPreloadHeuristics.predict(userMessage: message, surface: surface)
        // Predictive tool preload now consumes the per-turn plan's cached
        // mechanical prediction. The same gates still apply: candidates
        // intersect context toolSchemas and Mac Integration policy before
        // a request-scoped active set is unioned.
        let preloadOutcome = await ToolPreloadHeuristics.preloadOutcome(
            prediction: preloadPrediction,
            sessionId: resolvedSession,
            activeTools: sessionActiveTools,
            availableToolNames: Set((threadedCtxWithCognition?.toolSchemas ?? []).map(\.name)),
            surface: surface,
            dataRoot: dataRoot
        )
        // Still TURN START, still before the prefix is built: snapshot MCP
        // membership, freeze a descriptor per slot, and let a confident route
        // prediction join the load order exactly as a tool_load would — so its
        // schemas are ADVERTISED on this turn's first call (no discovery round)
        // and byte-stable on every turn after it.
        let contractCommit = await activeToolsStore.commitTurnStartContract(
            sessionId: resolvedSession,
            promoting: preloadOutcome.promotable,
            catalog: threadedCtxWithCognition?.toolSchemas ?? []
        )
        // A name that was NOT admitted (no headroom, or the write failed) must
        // not be reported or authorized as loaded: leave it discovery-only so
        // tool_load stays the honest recovery path.
        let preloadedActiveTools = preloadOutcome.activeTools.subtracting(
            preloadOutcome.promotable.subtracting(contractCommit?.promoted ?? [])
        )
        let turnContract = (contractCommit?.state ?? sessionLoadout).toolContract
        // preloadedActiveTools authorizes DISPATCH (it is bound through
        // LLMCallContext.turnActiveTools below). The advertised set is the
        // frozen contract — which now already contains this turn's promoted
        // preload and its pinned MCP membership.
        let lazyFilteredCtx = Self.applyLazyToolFilter(
            to: threadedCtxWithCognition,
            activeTools: preloadedActiveTools,
            contract: turnContract
        )
        let providerCtx = lazyFilteredCtx
        // Mid-conversation tool changes (Anthropic api-key structured lane
        // only). The `tools` array becomes the session's full pinned catalog —
        // byte-stable across turns — and THIS turn's offered set moves into
        // `tool_addition` / `tool_removal` blocks behind the cache breakpoint.
        // nil on every other provider/model, which keeps their wire identical.
        let toolChangePlan = Self.makeToolChangePlan(
            offered: providerCtx?.toolSchemas ?? [],
            contract: turnContract,
            modelId: providerCtx?.modelId ?? "",
            providerId: providerCtx?.providerId
        )
        let toolProgressRecorder = persistToolMessages ? ToolProgressPersistenceBuffer() : nil
        let effectiveProgress: ChatOrchestrationProgressHandler?
        if progress != nil || toolProgressRecorder != nil {
            effectiveProgress = { event in
                let redactedEvent = Self.redactedProgressEvent(event)
                if let toolProgressRecorder,
                   let record = await toolProgressRecorder.recordableToolResult(from: event) {
                    let inputJSON = (try? ChatSecretRedactor.redactValue(record.input).serialize(pretty: false)) ?? "{}"
                    let resultJSON = (try? ChatSecretRedactor.redactValue(record.output).serialize(pretty: false)) ?? "null"
                    do {
                        try await self.appendToolMessage(
                            sessionId: resolvedSession,
                            runId: runId,
                            toolName: record.name,
                            inputJSON: inputJSON,
                            resultSummary: resultJSON,
                            ok: record.ok,
                            cognitiveResult: ChatToolOutcome.cognitiveResult(
                                tool: record.name,
                                output: record.output
                            ),
                            source: surface
                        )
                    } catch {
                        // M2 (2026-07-09): a swallowed failure here dropped the
                        // tool receipt from the persisted transcript while the
                        // live pill still rendered — on reload the user saw a
                        // reply with no evidence of the tool that produced it.
                        await Self.reportTranscriptWriteFailure(
                            label: "appendToolMessage(\(record.name))",
                            path: self.dataRoot,
                            error: error,
                            userText: "Couldn't save the receipt for tool '\(record.name)' - it won't appear in the saved transcript.",
                            onNotice: noticeSink
                        )
                    }
                }
                if case .delta = redactedEvent,
                   await outputMilestoneGate.claim() {
                    TurnLifecycleTelemetry.emit(
                        .surfaceOutputEnqueued,
                        surface: surface,
                        sessionId: resolvedSession,
                        observedBy: "structured_chat.progress"
                    )
                }
                await self.observeCognitiveProgressEvent(
                    sessionId: resolvedSession,
                    runId: runId,
                    surface: surface,
                    event: redactedEvent,
                    toolResultAlreadyPersisted: toolProgressRecorder != nil
                )
                await progress?(redactedEvent)
            }
        } else {
            effectiveProgress = nil
        }

        // 4. Execute the turn (with tool loop), passing the history-threaded
        //    context so prior user/assistant turns reach the LLM.
        let result: TurnEngineResult
        do {
            // Turn Inspector W1: bind the per-turn trace id around the engine
            // call so every event the tool loop emits (llm.call, tool.dispatch,
            // memory.commit) inherits one turnId. Non-streaming chat path.
            // Same turnId as the context build above — one spine per turn.
            result = try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await LLMCallContext.$turnActiveTools.withValue(preloadedActiveTools) {
                try await StructuredToolChangeContext.$plan.withValue(toolChangePlan) {
                    try await engine.executeTurnWithToolLoop(
                        surface: surface,
                        userMessage: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        maxIterations: toolLoopMaxIterations(for: surface),
                        turnWallClockSecondsOverride: turnWallClockSecondsOverride,
                        llm: llm,
                        tools: gated,
                        preBuiltContext: providerCtx,
                        progress: effectiveProgress,
                        cancelFlagPath: cancelFlagPath
                    )
                }
                }
            }
            }
        } catch let e as ChatOrchestrationError {
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: Self.errorText(e),
                    persona: persona,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw e
        } catch let e as TurnEngineError {
            let message = (e as LocalizedError).errorDescription ?? String(describing: e)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    persona: persona,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw ChatOrchestrationError.underlying(message)
        } catch is CancellationError {
            // B7: a cross-process Stop (cancelled.flag) or Task cancel is NOT a
            // failure — don't persist a "Chat error: CancellationError" row;
            // just propagate. Mirrors the streaming sibling's #19 handling.
            // (Ordered before the bare `catch` so it isn't shadowed.)
            // 2026-09-05: but say so in the trace; silent deaths are unfindable.
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object(["where": .string("structured_chat.\(#line)")])
            )
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    persona: persona,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw ChatOrchestrationError.underlying(message)
        }

        // R-F1: the provider accepted the turn (every thrown path above rethrows,
        // so this line is unreachable on failure) — only now consume the felt
        // Body-line suppress window and update the Observatory live capsule.
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession
        )

        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: result.toolDispatches,
            dataRoot: dataRoot
        )

        // 5. Persist the assistant turn.
        try await appendMessage(
            sessionId: resolvedSession,
            role: "assistant",
            content: result.reply,
            runId: runId,
            attachments: generatedAttachments,
            persona: persona,
            source: surface,
            recalledMemoryIds: result.recalledIds,
            canonicalAssistantCompletion: true,
            outcomeResult: result,
            outcomeContext: providerCtx,
            outcomeTurnID: boundTurnId
        )
        if !result.reply.isEmpty, await outputMilestoneGate.claim() {
            TurnLifecycleTelemetry.emit(
                .surfaceOutputEnqueued,
                surface: surface,
                sessionId: resolvedSession,
                observedBy: "structured_chat.return",
                turnId: boundTurnId,
                on: turnTraceBus
            )
        }
        emitMetacognitiveTerminalTrace(
            turnId: boundTurnId,
            sessionId: resolvedSession,
            surface: surface,
            context: providerCtx,
            result: result
        )
        // 6. After-turn memory-promotion hook: REMOVED 2026-06-03.
        // executeTurnWithToolLoop already calls AdaptiveMemoryPromoter.shared
        // .observeTurn() on the no-tool-call branch (the only path that
        // returns here). Calling promoter.observeTurn again at this layer
        // produced DUPLICATE proposals — same (user, assistant) pair staged
        // twice, surfacing as two identical entries in the proposal queue
        // after every chat turn. The loop is the single owner of the hook.

        var response = ChatResponse(
            runId: runId,
            model: result.modelUsed,
            requestedModel: model.isEmpty ? nil : model,
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
            output: result.reply,
            sessionId: resolvedSession,
            personaFingerprint: Self.personaFingerprint(dataRoot: dataRoot),
            contextFingerprint: Self.contextFingerprint(recalledIds: result.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: result.providerCallCount
        )
        if result.completionState == .incomplete { response.runtimeStatus = "interrupted" }
        return StructuredChatExecution(response: response, turn: result)
    }

    func executeStructuredChatStreaming(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        persistToolMessages: Bool,
        progress: ChatOrchestrationProgressHandler?,
        noticeSink: @escaping @Sendable (String, String) async -> Void
    ) async throws -> StructuredChatExecution {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Suppressed-append turns adopt the enqueue-time runId (see
        // ChatPersistenceContext.pinnedTurnRunID) so history exclusion and
        // user/assistant row correlation match the normal path exactly.
        let runId = (suppressUserAppend ? ChatPersistenceContext.pinnedTurnRunID : nil)
            ?? UUID().uuidString
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        // #19 + B7 review round 2 (MED): derive + clear the per-session cancel
        // flag AT TURN ACCEPT — before the user append / autocompact awaits —
        // so the window where a Stop meant for THIS turn could be wiped is
        // effectively zero, while a stale flag from a prior turn still cannot
        // kill this one. Kept in lockstep with the non-streaming sibling.
        let cancelFlagPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(resolvedSession, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
        try? FileManager.default.removeItem(at: cancelFlagPath)

        // 2026-09-06: same Trust ▸ Multimodal gates as the non-streaming lane —
        // vision off means the images never become blocks, and an attached
        // PDF's text rides in `modelMessage` (model-facing only; the persisted
        // user row below keeps `message`).
        let attachmentInput = Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot)
        let imageBlocks = attachmentInput.imageBlocks
        let modelMessage = attachmentInput.userMessage

        if !suppressUserAppend {
            try await appendMessage(
                sessionId: resolvedSession,
                role: "user",
                content: message,
                runId: runId,
                attachments: attachments,
                persona: persona,
                source: surface
            )
        }

        // The window cursor must not slide in a turn the autocompactor already
        // rewrote — two rewrites of the same prefix in one turn pays the cache
        // write premium twice for one turn's worth of savings. The text lane
        // carries this the same way; discarding the outcome here let compaction
        // and a cursor advance both reshape the prefix on the same turn.
        var compactionRanThisTurn = false
        do {
            compactionRanThisTurn = try await prepareSessionHistoryForTurn(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch {
            // Two turns died silently on 2026-09-05 (00:34, 10:12) with no trace
            // after their last tool; a cancellation left nothing on paper.
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object(["where": .string("structured_chat.\(#line)")])
            )
            throw CancellationError()
        }

        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        let boundTurnId = StructuredTurnTraceIdentity.currentOrMint()
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "structured_stream.entry",
            turnId: boundTurnId,
            on: turnTraceBus
        )
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            fileAccess: fileAccess
        )
        // TURN START: advance the session turn clock and batch-drop tools that
        // went unused for two completed turns, before anything reads the
        // catalog. Drops only ever happen here — never mid-turn.
        async let sessionActiveToolsTask = activeToolsStore.beginTurn(sessionId: resolvedSession)

        // PROPAGATE failures — see the non-streaming sibling's comment: a
        // throw here is persona/router breakage, and try? silently degraded
        // the turn to no-history + default model/persona (audit 2026-06-09).
        // Same persist-then-rethrow treatment as the engine call below.
        // Mind-into-circulation follow-up (2026-07-10): mint the turn id
        // BEFORE the context build and bind it around build + engine alike.
        // The old binding started at the engine call, so `context.summary`
        // (emitted inside buildTurnContext) fired with NO bound turnId and was
        // silently dropped on every non-streaming turn — bridge/claude turns
        // had no context trace at all, blinding the Observatory fallback chip
        // and the attention trace counts on exactly those turns.
        let threadedCtx: TurnContext
        do {
            threadedCtx = try await HistoryWindowTurnFacts
                .$compactionRanThisTurn.withValue(compactionRanThisTurn) {
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: modelMessage,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    // The /new carry-over: on this session's FIRST turn only,
                    // two lines naming the previous session on THIS surface
                    // and the call that reopens it. Same data root as the
                    // history reader, so a fixture-rooted test never reads
                    // the live index.
                    sessionDigest: SessionDigestProvider(dataRoot: history.dataRoot),
                    imageBlocks: imageBlocks
                )
            }
            }
            }
        } catch is CancellationError {
            // Two turns died silently on 2026-09-05 (00:34, 10:12) with no trace
            // after their last tool; a cancellation left nothing on paper.
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object(["where": .string("structured_chat.\(#line)")])
            )
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    persona: persona
                )
            }
            throw ChatOrchestrationError.underlying(message)
        }
        let residentPreparation = await residentPreparationTask
        let turnPlan = residentPreparation.turnPlan
        let threadedCtxWithTurnPlan = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            threadedCtx,
            turnPlan: turnPlan
        )
        let threadedCtxWithOverrides = Self.applyChatOverrides(
            to: threadedCtxWithTurnPlan,
            model: model,
            reasoningEffort: reasoningEffort
        )
        if let turnPlan {
            await TurnPlanTraceRecorder.append(
                turnPlan,
                runId: runId,
                surface: surface,
                dataRoot: dataRoot,
                turnId: boundTurnId,
                turnTraceBus: turnTraceBus
            )
        }
        let (threadedCtxWithCognition, pendingProjectionCommit) = await contextByAppendingCognitiveCapsule(
            to: threadedCtxWithOverrides,
            surface: surface,
            userMessage: message,
            runId: runId,
            sessionId: resolvedSession,
            fileAccess: fileAccess,
            projection: residentPreparation.cognitiveProjection
        )
        let sessionLoadout = await sessionActiveToolsTask
        let sessionActiveTools = sessionLoadout.activeTools
        let preloadPrediction = turnPlan?.preloadPrediction
            ?? ToolPreloadHeuristics.predict(userMessage: message, surface: surface)
        // Predictive tool preload consumes the per-turn plan's cached
        // mechanical prediction; union-only, policy-gate-reusing, no-match
        // stays a no-op. The union is request-scoped, not session-persisted.
        let preloadOutcome = await ToolPreloadHeuristics.preloadOutcome(
            prediction: preloadPrediction,
            sessionId: resolvedSession,
            activeTools: sessionActiveTools,
            availableToolNames: Set((threadedCtxWithCognition?.toolSchemas ?? []).map(\.name)),
            surface: surface,
            dataRoot: dataRoot
        )
        // Still TURN START, still before the prefix is built: snapshot MCP
        // membership, freeze a descriptor per slot, and let a confident route
        // prediction join the load order exactly as a tool_load would — so its
        // schemas are ADVERTISED on this turn's first call (no discovery round)
        // and byte-stable on every turn after it.
        let contractCommit = await activeToolsStore.commitTurnStartContract(
            sessionId: resolvedSession,
            promoting: preloadOutcome.promotable,
            catalog: threadedCtxWithCognition?.toolSchemas ?? []
        )
        // A name that was NOT admitted (no headroom, or the write failed) must
        // not be reported or authorized as loaded: leave it discovery-only so
        // tool_load stays the honest recovery path.
        let preloadedActiveTools = preloadOutcome.activeTools.subtracting(
            preloadOutcome.promotable.subtracting(contractCommit?.promoted ?? [])
        )
        let turnContract = (contractCommit?.state ?? sessionLoadout).toolContract
        // preloadedActiveTools authorizes DISPATCH (it is bound through
        // LLMCallContext.turnActiveTools below). The advertised set is the
        // frozen contract — which now already contains this turn's promoted
        // preload and its pinned MCP membership.
        let lazyFilteredCtx = Self.applyLazyToolFilter(
            to: threadedCtxWithCognition,
            activeTools: preloadedActiveTools,
            contract: turnContract
        )
        let providerCtx = lazyFilteredCtx

        // Mid-conversation tool changes (Anthropic api-key structured lane
        // only). The `tools` array becomes the session's full pinned catalog —
        // byte-stable across turns — and THIS turn's offered set moves into
        // `tool_addition` / `tool_removal` blocks behind the cache breakpoint.
        // nil on every other provider/model, which keeps their wire identical.
        let toolChangePlan = Self.makeToolChangePlan(
            offered: providerCtx?.toolSchemas ?? [],
            contract: turnContract,
            modelId: providerCtx?.modelId ?? "",
            providerId: providerCtx?.providerId
        )

        let toolProgressRecorder = persistToolMessages ? ToolProgressPersistenceBuffer() : nil
        let effectiveProgress: ChatOrchestrationProgressHandler?
        if progress != nil || toolProgressRecorder != nil {
            effectiveProgress = { event in
                let redactedEvent = Self.redactedProgressEvent(event)
                if let toolProgressRecorder,
                   let record = await toolProgressRecorder.recordableToolResult(from: event) {
                    let inputJSON = (try? ChatSecretRedactor.redactValue(record.input).serialize(pretty: false)) ?? "{}"
                    let resultJSON = (try? ChatSecretRedactor.redactValue(record.output).serialize(pretty: false)) ?? "null"
                    do {
                        try await self.appendToolMessage(
                            sessionId: resolvedSession,
                            runId: runId,
                            toolName: record.name,
                            inputJSON: inputJSON,
                            resultSummary: resultJSON,
                            ok: record.ok,
                            cognitiveResult: ChatToolOutcome.cognitiveResult(
                                tool: record.name,
                                output: record.output
                            ),
                            source: surface
                        )
                    } catch {
                        // M2 (2026-07-09): a swallowed failure here dropped the
                        // tool receipt from the persisted transcript while the
                        // live pill still rendered — on reload the user saw a
                        // reply with no evidence of the tool that produced it.
                        await Self.reportTranscriptWriteFailure(
                            label: "appendToolMessage(\(record.name))",
                            path: self.dataRoot,
                            error: error,
                            userText: "Couldn't save the receipt for tool '\(record.name)' - it won't appear in the saved transcript.",
                            onNotice: noticeSink
                        )
                    }
                }
                if case .delta = redactedEvent,
                   await outputMilestoneGate.claim() {
                    TurnLifecycleTelemetry.emit(
                        .surfaceOutputEnqueued,
                        surface: surface,
                        sessionId: resolvedSession,
                        observedBy: "structured_stream.progress"
                    )
                }
                await self.observeCognitiveProgressEvent(
                    sessionId: resolvedSession,
                    runId: runId,
                    surface: surface,
                    event: redactedEvent,
                    toolResultAlreadyPersisted: toolProgressRecorder != nil
                )
                await progress?(redactedEvent)
            }
        } else {
            effectiveProgress = nil
        }

        let result: TurnEngineResult
        do {
            result = try await LLMCallContext.$turnActiveTools.withValue(preloadedActiveTools) {
                try await StructuredToolChangeContext.$plan.withValue(toolChangePlan) {
                try await engine.executeTurnWithStreamingToolLoop(
                    surface: surface,
                    userMessage: message,
                    sessionId: resolvedSession,
                    runId: runId,
                    maxIterations: toolLoopMaxIterations(for: surface),
                        turnWallClockSecondsOverride: turnWallClockSecondsOverride,
                    llm: llm,
                    tools: gated,
                    preBuiltContext: providerCtx,
                    progress: effectiveProgress,
                    cancelFlagPath: cancelFlagPath
                )
                }
            }
        } catch let e as ChatOrchestrationError {
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: Self.errorText(e),
                    persona: persona,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw e
        } catch let e as TurnEngineError {
            let message = (e as LocalizedError).errorDescription ?? String(describing: e)
            // #5: persist the visible partial the stream produced before failing
            // so it survives the reload like the compat path's partial (the
            // structured path used to drop it entirely).
            if case .streamInterrupted(let partial, _) = e {
                await persistPartialIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    text: partial,
                    cancelled: false,
                    source: surface,
                    outcomeContext: providerCtx,
                    onNotice: noticeSink
                )
            }
            // 2026-07-21 audit fix: a user stop carries its visible partial
            // through streamCancelled — persist it with cancelled:true (the
            // row must not read as a failure), skip the failure-message row,
            // and propagate CancellationError semantics upstream.
            if case .streamCancelled(let partial, _) = e {
                await persistPartialIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    text: partial,
                    cancelled: true,
                    source: surface,
                    outcomeContext: providerCtx,
                    onNotice: noticeSink
                )
                // User, 2026-09-06: this catch persisted the partial and threw
                // without a terminal row, so a mid-stream Stop on the
                // structured lane left the trace looking like an unexplained
                // death. Every other cancellation catch already fires this.
                TurnTraceBus.fireFromContext(
                    kind: "turn.cancelled", surface: surface,
                    payload: .object(["where": .string("structured_chat.\(#line)")])
                )
                throw CancellationError()
            }
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    persona: persona,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw ChatOrchestrationError.underlying(message)
        } catch is CancellationError {
            // A cancel (Task stop or cancelled.flag) is NOT a failure — don't
            // persist a "Chat error: CancellationError" row; just propagate
            // (gpt-5.5 review of #19, 2026-06-14). It still needs a terminal
            // row, or the turn reads as an unexplained death (2026-09-06).
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object(["where": .string("structured_chat.\(#line)")])
            )
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    persona: persona,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw ChatOrchestrationError.underlying(message)
        }

        // R-F1: the provider accepted the turn (every thrown path above rethrows,
        // so this line is unreachable on failure) — only now consume the felt
        // Body-line suppress window and update the Observatory live capsule.
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession
        )

        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: result.toolDispatches,
            dataRoot: dataRoot
        )

        try await appendMessage(
            sessionId: resolvedSession,
            role: "assistant",
            content: result.reply,
            runId: runId,
            attachments: generatedAttachments,
            persona: persona,
            source: surface,
            recalledMemoryIds: result.recalledIds,
            canonicalAssistantCompletion: true,
            outcomeResult: result,
            outcomeContext: providerCtx,
            outcomeTurnID: boundTurnId
        )
        if !result.reply.isEmpty, await outputMilestoneGate.claim() {
            TurnLifecycleTelemetry.emit(
                .surfaceOutputEnqueued,
                surface: surface,
                sessionId: resolvedSession,
                observedBy: "structured_stream.return",
                turnId: boundTurnId,
                on: turnTraceBus
            )
        }
        emitMetacognitiveTerminalTrace(
            turnId: boundTurnId,
            sessionId: resolvedSession,
            surface: surface,
            context: providerCtx,
            result: result
        )
        var response = ChatResponse(
            runId: runId,
            model: result.modelUsed,
            requestedModel: model.isEmpty ? nil : model,
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
            output: result.reply,
            sessionId: resolvedSession,
            personaFingerprint: Self.personaFingerprint(dataRoot: dataRoot),
            contextFingerprint: Self.contextFingerprint(recalledIds: result.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: result.providerCallCount
        )
        if result.completionState == .incomplete { response.runtimeStatus = "interrupted" }
        return StructuredChatExecution(response: response, turn: result)
    }

    /// Build the turn's mid-conversation tool-change plan, or nil to keep
    /// today's churning-`tools`-array behavior.
    ///
    /// GATED THREE WAYS, all fail-closed:
    ///   1. the ANTHROPIC API-KEY structured lane (`providerId == "anthropic"`)
    ///      — the only transport whose adapter emits `defer_loading` and the
    ///      tool-change blocks. OAuth-direct, kimi-code, OpenAI and xAI keep
    ///      their existing shape byte for byte. The OpenAI Responses lane has
    ///      NO equivalent feature — there is no way to declare a tool without
    ///      offering it — so it keeps a churn-on-load `tools` array with its
    ///      drops batched at turn start, and pays a prefix rebuild per load;
    ///   2. `supportsMidConversationToolChanges(forModel:)` — an unknown or
    ///      unsupported model answers false and falls back;
    ///   3. a session contract carrying a non-empty FROZEN DECLARATION.
    ///
    /// THE ARRAY IS THE SESSION'S PINNED DECLARATION, NOT THIS TURN'S CATALOG.
    /// `contract.declaredToolSchemas` was frozen — names and descriptors —
    /// at first declaration by `commitTurnStartContract`, so Full-Mac posture,
    /// activity capture, registry readiness flaps and MCP cache churn cannot
    /// move a byte of it. They still move what is OFFERED and what may
    /// DISPATCH, which is exactly where they belong. A genuinely new built-in
    /// joins by an explicit turn-start re-pin, which bumps
    /// `declarationGeneration` and is reported as an array change.
    ///
    /// ORDER: floor sorted by name (those are the array's own defaults), then
    /// the rest in DECLARATION APPEND ORDER — so a re-pin appends at the tail
    /// instead of reshuffling every row ahead of it.
    ///
    /// NO EMPTY-DELTA BAILOUT: the plan stands whenever the gates pass, even on
    /// a floor-only turn. Returning nil there would ship the lazy-filtered
    /// array on that turn and the full deferred declaration on the next one,
    /// which is the array moving — the whole failure this lane prevents. It is
    /// the tool-change MESSAGE that may be nil.
    ///
    /// VALIDATION: referencing a name that is not declared in `tools` is a
    /// 400, so the offered set is checked against the array here. A name that
    /// is not declared is dropped from the addition list and recorded in
    /// `droppedUnknown` — never sent.
    /// NOTE the absent `catalog:` parameter. This function deliberately cannot
    /// see the live catalog — that is the guarantee, not an omission.
    static func makeToolChangePlan(
        offered: [LLMToolSchema],
        contract: SessionToolContract?,
        modelId: String,
        providerId: String?
    ) -> StructuredToolChangePlan? {
        let provider = (providerId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard provider == "anthropic",
              supportsMidConversationToolChanges(forModel: modelId),
              // No pinned declaration means no stable array — fall back rather
              // than ship one derived from live, policy-gated catalog state.
              let contract, !contract.declaredOrder.isEmpty else { return nil }

        let floor = SwiftToolDispatcher.alwaysOnCoreNames
        let declaredSchemas = contract.declaredSchemas
        let declaredNames = contract.declaredOrder.filter { declaredSchemas[$0] != nil }
        let orderedNames = declaredNames.filter { floor.contains($0) }.sorted()
            + declaredNames.filter { !floor.contains($0) }
        let array = orderedNames.compactMap { name -> LLMToolSchema? in
            guard let pinned = declaredSchemas[name] else { return nil }
            // Floor tools are offered from the start of the conversation;
            // everything else waits for a `tool_addition` block.
            return pinned.schema(named: name).deferringLoad(!floor.contains(name))
        }
        guard !array.isEmpty else { return nil }
        let declared = Set(array.map(\.name))

        let offeredNames = offered.map(\.name)
        let droppedUnknown = offeredNames.filter { !declared.contains($0) }
        let offeredDeclared = Set(offeredNames).intersection(declared)
        // Re-declared in FULL every turn, relative to the array's own
        // defaults, because history is rebuilt from the transcript each turn
        // and there is no ledger of what an earlier turn declared.
        let additions = orderedNames.filter {
            offeredDeclared.contains($0) && !floor.contains($0)
        }
        // Only an array DEFAULT can need withdrawing. A deferred tool that is
        // not offered simply never gets its addition block.
        let removals = orderedNames.filter {
            floor.contains($0) && !offeredDeclared.contains($0)
        }
        return StructuredToolChangePlan(
            array: array,
            offered: offeredNames.filter { offeredDeclared.contains($0) },
            additions: additions,
            removals: removals,
            droppedUnknown: droppedUnknown,
            declarationGeneration: contract.declarationGeneration
        )
    }

    /// Lazy-tool-loading filter AND the single owner of the advertised tool
    /// order. With a `contract` the admitted set is
    /// `alwaysOnCoreNames ∪ contract.order ∪ the Full-Mac resident family`,
    /// and `mcp__*` passes only if the turn-start snapshot pinned it — being
    /// merely ACTIVE admits nothing, and neither does the `mcp__` prefix.
    /// Without a contract (no session) the legacy rule still applies: anything
    /// `normalModelToolNames` authorizes, plus every `mcp__*` row.
    /// Returns nil if the input ctx was nil so callers can short-circuit
    /// the same as before. See docs/build_plans/lazy-tool-skill-loading.md.
    /// C3: promoted from `private` to `internal` so the engine's
    /// `lazyFilteredTurnContext` (the deriving variant used by both structured
    /// loops + `streamTurn`) reuses this ONE filter+rebuild instead of
    /// hand-inlining it. The 15-field rebuild now routes through
    /// `TurnContext.withToolSchemas(_:)` (the single manual-copy site).
    ///
    /// ORDER (2026-09-01): the surviving schemas come back in
    /// `SwiftToolDispatcher.canonicalToolOrder` — always-on floor sorted by
    /// name, then everything else in the session's LOAD order. The structured
    /// lane's `tools` array and the text lane's rendered catalog both derive
    /// from this one array, so the two lanes cannot disagree about the
    /// contract and a load can only APPEND to it.
    ///
    /// `contract` is the session's FROZEN contract, and passing it makes this
    /// the ADVERTISING boundary. What gets advertised is the floor, the
    /// Full-Mac resident family, the pinned MCP members, and the session's
    /// loaded tools IN CONTRACT ORDER — nothing else, and nothing read live
    /// from a catalog that can change underneath a session.
    ///
    /// Three things are deliberately NOT trusted here:
    ///   * `mcp__*` no longer passes on prefix. MCP schemas come from a
    ///     detached-refresh disk cache, so prefix admission let membership
    ///     change between two turns that loaded nothing. Only names in the
    ///     turn-start snapshot are advertised.
    ///   * A slot missing from THIS turn's catalog is re-materialized from its
    ///     pinned descriptor. A registry tool whose readiness flaps keeps its
    ///     row; dispatch still rereads readiness and answers honestly.
    ///   * A confident preload is advertised only because turn start actually
    ///     promoted it into the contract — never because it was predicted.
    ///
    /// nil keeps the legacy behavior (advertise everything authorized, MCP by
    /// prefix) for callers that have no session.
    ///
    /// The Full-Mac resident family is admitted from the CATALOG rather than
    /// from any session row: it is derived purely from the available tool names
    /// and the Trust Center posture, so it is already identical turn to turn,
    /// and persisting ~30 speculative names would consume the whole per-session
    /// budget. It sorts ahead of the contract run so a later `tool_load` still
    /// appends at the tail.
    static func applyLazyToolFilter(
        to context: TurnContext?,
        activeTools: Set<String>,
        contract: SessionToolContract? = nil
    ) -> TurnContext? {
        guard let context else { return nil }
        let allowed = SwiftToolDispatcher.normalModelToolNames(activeTools: activeTools)
        let resident = ToolPreloadHeuristics.immediateFullMacTools(
            availableToolNames: Set(context.toolSchemas.map(\.name))
        ).subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
        // MCP membership is pinned by the turn-start SNAPSHOT (declarationGeneration
        // > 0). A store-derived contract that has never taken one carries an
        // empty MCP set that means "not yet snapshotted", not "no MCP": treat it
        // like the no-contract arm so the pinned and unpinned turn-start paths
        // agree (LazyFilterPinnedActiveToolsTests.turnStartEquivalence…).
        let pinnedMCP: Set<String>? = (contract?.declarationGeneration ?? 0) > 0
            ? contract?.pinnedMCPNames
            : nil
        // `order` IS the contract. A name that is merely ACTIVE — a live load
        // row that turn start never admitted into the advertised order — stays
        // dispatch-only. Advertising it would add a row the contract never
        // declared, and as an UNRANKED slot it would land ahead of the whole
        // load run, shifting every row the prefix already cached.
        let advertisable: Set<String>? = contract.map { pinned in
            SwiftToolDispatcher.alwaysOnCoreNames
                .union(pinned.order)
                .union(resident)
        }
        var bySlot: [String: LLMToolSchema] = [:]
        for schema in context.toolSchemas where bySlot[schema.name] == nil {
            if schema.name.hasPrefix("mcp__") {
                guard pinnedMCP?.contains(schema.name) ?? true else { continue }
                bySlot[schema.name] = schema
                continue
            }
            guard allowed.contains(schema.name) else { continue }
            guard advertisable?.contains(schema.name) ?? true else { continue }
            bySlot[schema.name] = schema
        }
        // A pinned slot whose schema is absent from this turn's catalog is
        // restored from the descriptor it entered the contract with, so a
        // readiness flap or a cache rewrite cannot silently shrink the prefix.
        //
        // 2026-09-06: through the MODEL-VISIBILITY boundary, the same one the
        // catalog walk above applies via `normalModelToolNames`. A legacy
        // `mac_*` organ left in an old session's load order is excluded from
        // that walk, which left `bySlot[name] == nil` and made this restore
        // declare it to the model — the retired organ arriving by the pin
        // route the walk had just refused. Readiness and policy-catalogue
        // flaps are untouched: this set is the fixed four-verb cutover list,
        // not anything that moves turn to turn, so a legitimately pinned tool
        // missing from THIS catalog is still restored.
        if let contract {
            let restorable = SwiftToolDispatcher.modelVisibleCatalogToolNames(Set(contract.order))
            for name in contract.order where bySlot[name] == nil {
                guard restorable.contains(name) else { continue }
                guard let pinned = contract.pinnedSchemas[name] else { continue }
                bySlot[name] = pinned.schema(named: name)
            }
        }
        // Deterministic input order matters: `canonicalToolOrder` breaks ties
        // on it for anything the contract does not rank, and a Set's iteration
        // order would make that vary run to run. Catalog walk order first,
        // then any slot restored purely from its pin.
        var admittedNames = context.toolSchemas.map(\.name).filter { bySlot[$0] != nil }
        let fromCatalog = Set(admittedNames)
        admittedNames += (contract?.order ?? [])
            .filter { bySlot[$0] != nil && !fromCatalog.contains($0) }
        let residentOrder = resident.sorted()
        // Pinned MCP members are deliberately left OUT of the rank list:
        // `canonicalToolOrder` ranks anything unranked at -1, which keeps MCP
        // ahead of both the resident family and the session load run. They are
        // present from a session's first turn, so a later resident flip or a
        // tool_load must append behind them, never shift them.
        let ordering = SwiftToolDispatcher.canonicalToolOrder(
            admittedNames,
            loadOrder: residentOrder
                + (contract?.order ?? []).filter {
                    !resident.contains($0) && !(pinnedMCP?.contains($0) ?? false)
                }
        )
        let ordered = ordering.advertised.compactMap { bySlot[$0] }
        return context.withToolSchemas(ordered)
    }

    func prepareCognitiveTurnProjection(
        surface: String,
        userMessage: String,
        sessionId: String
    ) async -> CognitiveTurnProjection? {
        guard let cognitiveContextProvider else { return nil }
        return await cognitiveContextProvider.prepareTurnProjection(
            cognitiveTurnProjectionRequest(
                surface: surface,
                userMessage: userMessage,
                sessionId: sessionId
            )
        )
    }

    /// The user message has already crossed the canonical transcript and
    /// cognition-ingestion boundary before this helper runs. Planning and the
    /// frozen resident projection are independent preparation reads, so the
    /// caller can overlap them with ContextFlow/history assembly. The result
    /// remains turn-scoped and the projection is committed only after it is
    /// actually appended to provider input.
    func prepareResidentTurnInputs(
        message: String,
        surface: String,
        sessionId: String,
        fileAccess: String
    ) async -> ResidentTurnPreparation {
        async let turnPlanTask = makeTurnPlan(
            message: message,
            surface: surface,
            sessionId: sessionId,
            fileAccess: fileAccess
        )
        async let cognitiveProjectionTask = prepareCognitiveTurnProjection(
            surface: surface,
            userMessage: message,
            sessionId: sessionId
        )
        let (turnPlan, cognitiveProjection) = await (
            turnPlanTask,
            cognitiveProjectionTask
        )
        return ResidentTurnPreparation(
            turnPlan: turnPlan,
            cognitiveProjection: cognitiveProjection
        )
    }

    func cognitiveTurnProjectionRequest(
        surface: String,
        userMessage: String,
        sessionId: String
    ) -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            mode: .inject,
            // Sweep R4 W3: window-aware, floored at the former 4,000 literal.
            // The substrate additionally clamps with its own configured
            // `maximumCapsuleCharacters`, so this can only ever RAISE the
            // request's own ceiling, never the substrate's.
            maximumCharacters: ContextBudgetPolicy.resolve(
                model: LLMCallContext.admittedModel,
                providerID: LLMCallContext.providerId,
                dataRoot: dataRoot,
                surface: surface
            ).capsuleChars,
            allowNonLiveProjection: Self.shouldProjectCognitiveStateForTrustedBridgeEnvelope(
                userMessage
            ),
            turnKind: Self.cognitiveMessageTurnKind(
                role: "user",
                source: surface,
                redactedContent: ChatSecretRedactor.redactText(userMessage),
                origin: ChatPersistenceContext.originProvenance
            )
        )
    }

    func contextByAppendingCognitiveCapsule(
        to context: TurnContext?,
        surface: String,
        userMessage: String,
        runId: String,
        sessionId: String,
        fileAccess: String,
        projection: CognitiveTurnProjection?
    ) async -> (context: TurnContext?, pendingProjectionCommit: CognitiveTurnProjection?) {
        guard let context else { return (nil, nil) }
        guard let runtimeContext = Self.cognitiveRuntimeContext(
            runId: runId,
            sessionId: sessionId,
            surface: surface,
            fileAccess: fileAccess,
            capsule: projection?.capsule,
            posture: projection?.posture
        ) else {
            return (context, nil)
        }
        let projectedContext = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
            context,
            runtimeContext: runtimeContext
        )
        // R-F1 (2026-07-17): the commit used to fire here, at ASSEMBLY — before
        // the provider ever saw the turn. A 529 on the first provider call then
        // consumed the 20-min Body-line suppress window for a felt line the
        // model never received, and the Observatory labeled a never-delivered
        // capsule `.liveInjected`. The projection is handed back instead; the
        // turn executor commits it once, only after the engine call succeeds.
        return (projectedContext, projection)
    }

    /// Commits presentation-only projection bookkeeping (Body-line suppress
    /// window, Observatory live-capsule cache) AFTER the provider actually
    /// accepted the turn. Called exactly once per successful turn regardless
    /// of how many provider round-trips the tool loop made; never called on a
    /// thrown turn, so a failed delivery leaves the felt line available to the
    /// retry.
    func commitDeliveredCognitiveTurnProjection(
        _ projection: CognitiveTurnProjection?,
        surface: String,
        userMessage: String,
        sessionId: String
    ) async {
        guard let projection, let cognitiveContextProvider else { return }
        await cognitiveContextProvider.commitTurnProjection(
            projection,
            request: cognitiveTurnProjectionRequest(
                surface: surface,
                userMessage: userMessage,
                sessionId: sessionId
            )
        )
    }

    private static func applyChatOverrides(
        to context: TurnContext?,
        model: String,
        reasoningEffort: String
    ) -> TurnContext? {
        guard let context else { return nil }
        let modelOverride = (LLMCallContext.admittedModel ?? model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effortOverride = (LLMCallContext.reasoningEffort ?? reasoningEffort)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelOverride.isEmpty || !effortOverride.isEmpty else {
            return context
        }
        return TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            recalled: context.recalled,
            modelId: modelOverride.isEmpty ? context.modelId : modelOverride,
            reasoningEffort: effortOverride.isEmpty ? context.reasoningEffort : effortOverride,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: context.systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: context.systemSegments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: context.naturalExpressionCue,
            historyMessages: context.historyMessages,
            turnVolatileBlock: context.turnVolatileBlock,
            historyWindowReceipt: context.historyWindowReceipt
        )
    }

    // REMOVED 2026-07-25: cleanupTransientActiveTools. It subtracted the
    // turn-start store snapshot from the turn-end store — but preload never
    // persists (preloadIfConfident discards the store on purpose), so the
    // ONLY thing this could ever remove was the model's explicit tool_load
    // results: the exact state ActiveToolsStore exists to keep. The effect
    // was self-perpetuating session amnesia — store empty -> baseline empty
    // -> every load "transient" -> wiped at turn end -> store empty — which
    // forced a tool_load round-trip (a full extra LLM call) before nearly
    // every action on tool-heavy days (live finding 2026-07-25: 30 re-loads,
    // "already_active": [] all day, only .lock files ever on disk). Decay is
    // owned by the store's 24h TTL and the explicit tool_unload path.

    func makeTurnPlan(
        message: String,
        surface: String,
        sessionId: String,
        fileAccess: String
    ) async -> TurnPlan? {
        do {
            return try await TurnPlanner(dataRoot: dataRoot).plan(
                message: message,
                surface: surface,
                sessionId: sessionId,
                fileAccess: fileAccess,
                approvalAvailable: true
            )
        } catch {
            FileHandle.standardError.write(
                Data("TurnPlanner: plan failed (\(surface)/\(sessionId)): \(error)\n".utf8)
            )
            return nil
        }
    }

    static func cognitiveRuntimeContext(
        runId: String,
        sessionId: String,
        surface: String,
        fileAccess: String,
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?
    ) -> String? {
        var sections: [String] = []
        if let capsule,
           !capsule.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // One functional line, no disclaimers: her guardrails live in her soul
            // (persona), and actions are hard-gated by TrustCenter regardless of
            // prompt text (User, 2026-07-01: "she has those guardrails in her
            // soul... no disclaimer is needed"). The line below only keeps her from
            // narrating the block itself.
            sections.append("""
            [CognitiveSubstrate]
            run_id: \(runId)
            session_id: \(sessionId)
            surface: \(surface)
            file_access: \(fileAccess)

            Her private inner state — it colors her, she never quotes or mentions it.

            \(capsule.combined)
            """)
        }
        if let posture {
            sections.append(posture.privateRuntimeContext(
                runId: runId,
                sessionId: sessionId,
                surface: surface,
                fileAccess: fileAccess
            ))
        }
        let combined = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    nonisolated static func shouldProjectCognitiveStateForTrustedBridgeEnvelope(
        _ userMessage: String
    ) -> Bool {
        let normalized = userMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("[from: codex, via bridge]")
            || normalized.hasPrefix("[from: claude, via bridge]")
    }
}
