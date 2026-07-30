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
        let failed = result.toolDispatches.filter {
            !ChatToolOutcome.outputLooksSuccessful($0.result)
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
        progress: ChatOrchestrationProgressHandler?
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
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "structured_chat.entry"
        )

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
        let imageBlocks = Self.imageBlocksFromAttachments(attachments)

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

        do {
            _ = try await compactSessionBeforeContextIfNeeded(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: "Autocompact failed before context assembly: \(message)",
                    persona: persona
                )
            }
            throw ChatOrchestrationError.underlying("autocompact failed before context assembly: \(message)")
        }

        // 2. Build wrapped tool dispatcher: fileAccess gate → autonomy gate → real tools.
        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        let boundTurnId = StructuredTurnTraceIdentity.currentOrMint()
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            fileAccess: fileAccess
        )
        async let sessionActiveToolsTask = activeToolsStore.load(sessionId: resolvedSession)

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
            threadedCtx = try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: message,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    imageBlocks: imageBlocks
                )
            }
            }
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
        let sessionActiveTools = await sessionActiveToolsTask.activeTools
        let preloadPrediction = turnPlan?.preloadPrediction
            ?? ToolPreloadHeuristics.predict(userMessage: message)
        // Predictive tool preload now consumes the per-turn plan's cached
        // mechanical prediction. The same gates still apply: candidates
        // intersect context toolSchemas and Mac Integration policy before
        // a request-scoped active set is unioned.
        let preloadedActiveTools = await ToolPreloadHeuristics.preloadIfConfident(
            prediction: preloadPrediction,
            sessionId: resolvedSession,
            activeTools: sessionActiveTools,
            availableToolNames: Set((threadedCtxWithCognition?.toolSchemas ?? []).map(\.name)),
            surface: surface,
            dataRoot: dataRoot
        )
        let lazyFilteredCtx = Self.applyLazyToolFilter(
            to: threadedCtxWithCognition,
            activeTools: preloadedActiveTools
        )
        let providerCtx = lazyFilteredCtx
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
                            onNotice: { kind, text in await progress?(.notice(kind: kind, text: text)) }
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
                    try await engine.executeTurnWithToolLoop(
                        surface: surface,
                        userMessage: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        maxIterations: toolLoopMaxIterations(for: surface),
                        llm: llm,
                        tools: gated,
                        preBuiltContext: providerCtx,
                        progress: effectiveProgress,
                        cancelFlagPath: cancelFlagPath
                    )
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

        let response = ChatResponse(
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
        progress: ChatOrchestrationProgressHandler?
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
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "structured_stream.entry"
        )

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

        let imageBlocks = Self.imageBlocksFromAttachments(attachments)

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

        do {
            _ = try await compactSessionBeforeContextIfNeeded(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: "Autocompact failed before context assembly: \(message)",
                    persona: persona
                )
            }
            throw ChatOrchestrationError.underlying("autocompact failed before context assembly: \(message)")
        }

        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        let boundTurnId = StructuredTurnTraceIdentity.currentOrMint()
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            fileAccess: fileAccess
        )
        async let sessionActiveToolsTask = activeToolsStore.load(sessionId: resolvedSession)

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
            threadedCtx = try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: message,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    imageBlocks: imageBlocks
                )
            }
            }
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
        let sessionActiveTools = await sessionActiveToolsTask.activeTools
        let preloadPrediction = turnPlan?.preloadPrediction
            ?? ToolPreloadHeuristics.predict(userMessage: message)
        // Predictive tool preload consumes the per-turn plan's cached
        // mechanical prediction; union-only, policy-gate-reusing, no-match
        // stays a no-op. The union is request-scoped, not session-persisted.
        let preloadedActiveTools = await ToolPreloadHeuristics.preloadIfConfident(
            prediction: preloadPrediction,
            sessionId: resolvedSession,
            activeTools: sessionActiveTools,
            availableToolNames: Set((threadedCtxWithCognition?.toolSchemas ?? []).map(\.name)),
            surface: surface,
            dataRoot: dataRoot
        )
        let lazyFilteredCtx = Self.applyLazyToolFilter(
            to: threadedCtxWithCognition,
            activeTools: preloadedActiveTools
        )
        let providerCtx = lazyFilteredCtx

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
                            onNotice: { kind, text in await progress?(.notice(kind: kind, text: text)) }
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
                try await engine.executeTurnWithStreamingToolLoop(
                    surface: surface,
                    userMessage: message,
                    sessionId: resolvedSession,
                    runId: runId,
                    maxIterations: toolLoopMaxIterations(for: surface),
                    llm: llm,
                    tools: gated,
                    preBuiltContext: providerCtx,
                    progress: effectiveProgress,
                    cancelFlagPath: cancelFlagPath
                )
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
                    outcomeContext: providerCtx
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
                    outcomeContext: providerCtx
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
            // (gpt-5.5 review of #19, 2026-06-14).
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
        emitMetacognitiveTerminalTrace(
            turnId: boundTurnId,
            sessionId: resolvedSession,
            surface: surface,
            context: providerCtx,
            result: result
        )
        let response = ChatResponse(
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
        return StructuredChatExecution(response: response, turn: result)
    }

    /// Lazy-tool-loading filter. Drops built-in tool schemas that aren't in
    /// `alwaysOnCoreNames ∪ activeTools`. MCP schemas (mcp__*) always pass.
    /// Returns nil if the input ctx was nil so callers can short-circuit
    /// the same as before. See docs/build_plans/lazy-tool-skill-loading.md.
    /// C3: promoted from `private` to `internal` so the engine's
    /// `lazyFilteredTurnContext` (the deriving variant used by both structured
    /// loops + `streamTurn`) reuses this ONE filter+rebuild instead of
    /// hand-inlining it. The 15-field rebuild now routes through
    /// `TurnContext.withToolSchemas(_:)` (the single manual-copy site).
    static func applyLazyToolFilter(
        to context: TurnContext?,
        activeTools: Set<String>
    ) -> TurnContext? {
        guard let context else { return nil }
        let allowed = SwiftToolDispatcher.alwaysOnCoreNames.union(activeTools)
        let filtered = context.toolSchemas.filter { schema in
            if allowed.contains(schema.name) { return true }
            if schema.name.hasPrefix("mcp__") { return true }
            return false
        }
        return context.withToolSchemas(filtered)
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
            maximumCharacters: 4_000,
            allowNonLiveProjection: Self.shouldProjectCognitiveStateForTrustedBridgeEnvelope(
                userMessage
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
            fluidContextTurn: context.fluidContextTurn
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
