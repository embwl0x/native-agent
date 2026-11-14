import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import ChatTurnContracts
import ChatSessionWork
import ChatToolParsing
import ChatToolRuntime
import Transcripts
import ToolRegistry
import TurnTrace
import Dispatcher
import PersonaEngine
import AgentWorkspace
import os
// Blueprint: | `StandingBotModel.swift` | `Expansion.withTurn`; Helper-owned measured conversation replay |

extension SwiftNativeChatOrchestrationClient {
    func runStandingBot(_ bot: BotDefinition, message: String, choice: ProviderTurnChoice,
                        attachments: [MultimodalAttachment], fileAccess: String, runID: String?,
                        progress: TurnEventSink?, turn: Turn, work: ChatTurnWork) async throws -> BotTurnReply {
        let admission = TurnRouteAdmission(routingSurface: "chat", modelId: choice.model,
            reasoningEffort: choice.reasoningEffort, providerId: choice.provider, serviceTier: choice.fast ? "priority" : nil)
        return try await holding(turn.with(\.providerChoice, choice)) { turn in
        try await withModelContext(admission, surface: "bot", turn: turn) { turn in
        try await holding(turn.with(\.tokenBudget, TurnTokenBudget(tokens: bot.budget.tokens))) { turn in
        let run = runID ?? turn.run
        let started = DispatchTime.now().uptimeNanoseconds
        let turnID = turn.id
        let answerID = turn.replyRow?.messageId(turn: turn.id, session: bot.sessionID) ?? UUID().uuidString
        let input = try Self.turnAttachmentInput(message: message, attachments: attachments, dataRoot: dataRoot, runId: run)
        let execution = ChatTurnExecution(mechanicalRow: .botReceipt)
        let choices = ReplyChoices()
        let turn = turn.with(\.execution, execution).with(\.replyChoices, choices).with(\.run, run)
            .with(\.session, bot.sessionID).with(\.userText, message).with(\.fileAccess, fileAccess)
        return try await ProviderToolResultPage.holding(turn: turn, sessionId: bot.sessionID) { turn in
        let envelope = turn.envelope
        let deliverySurface = turn.replyRoute?.surface ?? "bot"
        let taint = turn.peerSteering
        let dispatcher = await makeTracedGatedDispatcher(fileAccess: fileAccess, verifiedSessionId: bot.sessionID, work: work)
        let schemas = try await dispatcher.listAvailableToolSchemas(named: ["app"], turn: turn, surface: "bot")
        let codec = try ToolCallCodec.forProvider(choice.provider)
        let providerNames = ProviderToolNameMap(schemas)
        let replacing = turn.rows.replacementAssistantMessageID != nil
            || turn.rows.replacementUserMessageID != nil
        // Like resident chat, admission saves the current words before the
        // shared measurement, so the trigger includes this turn's added text.
        if !replacing {
            _ = try await appendMessage(sessionId: bot.sessionID, role: "user", content: message,
                runId: run, attachments: attachments, source: "bot", mechanicalRow: .botReceipt,
                messageId: turn.rows.pinnedUserMessageID ?? UUID().uuidString, turn: turn)
        }
        // A regenerate replaces the tail turn: its question is already on disk
        // and its old answer is not history for the new one.
        let historyRead = history.promptMessagesWithStats(
            transcript: try await history.transcriptBytes(forSessionId: bot.sessionID).bytes,
            excludingRunId: nil
        ).prompt
        var rows = try historyRead.checkedMessages()
        var replacingUserID = turn.rows.replacementUserMessageID
        if replacing, let asked = rows.lastIndex(where: { $0.role == "user" }) {
            guard case .object(let row)? = rows[asked].extras, case .string(let id)? = row["id"] else {
                throw ProviderRoutingError.configurationFailed("The helper's saved question has no readable identity.")
            }
            replacingUserID = id
        }
        rows = SessionHistoryTail.select(rows,
            beforeQuestionID: replacing ? replacingUserID : nil, excludingRunID: replacing ? nil : run)
        let historyBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: dataRoot)
        guard let windowTokens = historyBudget.windowTokens else {
            throw ProviderRoutingError.configurationFailed("The helper model's default window is unavailable.")
        }
        var messages: [LLMMessage] = []
        var historyRowCharacters: [String: Int] = [:]
        var historySnapshot: SessionHistoryTail?
        var contextWindow = "0:"
        if let admitted = SessionHistoryMessages.admission(
            messages: rows, historyLimit: historyLimit, budget: historyBudget) {
            let projected = SessionHistoryMessages.project(admitted)
            messages = projected.messages
            historyRowCharacters = projected.rowCharacters
            historySnapshot = SessionHistoryTail(admitted, rowCharacters: projected.rowCharacters)
            contextWindow = projected.contextWindow
        }
        let system = try BotChatContract.instructions(for: bot)
        var contactThread = ""
        // Keep each helper's requested words in its own transcript so its conversation remains its memory.
        let agentName = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
        let thread = try ContactThread.lines(dataRoot: dataRoot, owner: bot.sessionID, tailBytes: 96_000)
        do {
            let said = thread.suffix(30).compactMap { line -> String? in
                let words = line.text.components(separatedBy: "\n").drop { $0.hasPrefix("[") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { return nil }
                return (line.role == "assistant" ? agentName : "You") + ": " + String(words.prefix(800))
            }
            if !said.isEmpty {
                contactThread = "What has passed between you and \(agentName) so far, oldest first. \(agentName) sees only what you send"
                    + " with agent.message; this run's own reply goes to whoever ran you, not to \(agentName):\n" + said.joined(separator: "\n\n")
            }
        }
        var context = TurnContext(surface: "bot", personaDocs: [:], personaFingerprint: "", recalled: [],
            modelId: choice.model, reasoningEffort: choice.reasoningEffort, providerId: choice.provider,
            toolsAvailable: schemas.map(\.name), userMessage: input.userMessage, toolSchemas: schemas,
            imageBlocks: input.imageBlocks, historyMessages: messages,
            turnReach: TurnReach())
            .composing(SystemPromptSegments(stable: system, dynamic: contactThread), tools: nil)
        context.historyContextWindow = contextWindow
        context.historyRowCharacters = historyRowCharacters
        context.historyReplaySpec = SessionReplaySpec(historyLimit: historyLimit,
            excludedRunID: replacing ? nil : run,
            replacementUserMessageID: replacing ? replacingUserID : nil)
        context.historyReplaySpec?.historySnapshot = historySnapshot
        context = try await fitSessionRequest(context, codec: codec, sessionId: bot.sessionID,
            surface: "bot", runId: run, progress: progress, turn: turn)
        let request = try ConversationPrefixSeeding.request(context, codec: codec, turn: turn)
        let seed = request.seed
        let layout = (system: request.system ?? "", segments: request.segments)
        let requestPlan = try request.plan(runID: run, userMessageID: replacingUserID).encoded
        let prefix = ConversationPrefixTelemetrySink()
        let work = work.with(\.prefixTelemetry, prefix)
        prefix.set(ConversationPrefixSeeding.telemetry(seed,
            toolSchemaFingerprint: SwiftNativeTurnEngine.toolSchemaFingerprint(schemas)))
        await seed.sentContext.persist(sessionID: bot.sessionID, runID: run,
            userMessageID: replacingUserID, dataRoot: dataRoot)
        let flag = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: bot.sessionID, runId: run,
            turnId: turnID)
        defer { ChatCancelFlag.finish(flag) }
        var modelCall = LLMCall(turn: turn, surface: "bot", purpose: "other", session: bot.sessionID)
        modelCall.systemSegments = layout.segments
        modelCall.currentUserIndex = seed.currentUserIndex
        modelCall.requestPlan = requestPlan
        modelCall.conversationRequest = true
        modelCall.withinTurnReuse = true
        modelCall.prefixMeasurement = prefix
        let call = modelCall
        let roundPrefix = OSAllocatedUnfairLock(initialState: (context, seed))
        let execute: @Sendable (Turn, LLMCall, ChatTurnWork) async -> BotTurnReply = { [self] turn, call, work in
            await BotTurnRunner.run(bot: bot, messages: seed.messages, system: layout.system,
                model: choice.model, llm: llm, schemas: codec.requestTools(providerNames.schemas),
                turn: turn, call: call.with(\.turn, turn), options: work.botOptions,
                admitRequest: { messages in
                    let records = execution.toolRecords
                    let (previousContext, previousSeed) = roundPrefix.withLock { $0 }
                    let additional = try ConversationPrefixSeeding.additionalMessages(in: messages, after: previousSeed)
                    let encoded = try codec.providerMessages(additional, records: records, schemas: schemas, turn: turn)
                    let nextContext = try await self.fitSessionRequest(previousContext, codec: codec,
                        additionalMessages: encoded, sessionId: bot.sessionID, surface: "bot", runId: run, progress: progress, turn: turn)
                    let nextRequest = try ConversationPrefixSeeding.request(nextContext, codec: codec, turn: turn).appending(additional)
                    roundPrefix.withLock { $0 = (nextContext, nextRequest.seed) }
                    let measure: @Sendable ([LLMMessage]) async throws -> SessionContextMeasurement = { candidate in
                        let wire = try codec.providerMessages(candidate, records: records, schemas: schemas, turn: turn)
                        let request = try SessionContextRequest(messages: wire, system: layout.system,
                            tools: codec.requestTools(providerNames.schemas) ?? [], historyCharacters: 0, rowCharacters: [:])
                        return try await SessionContextMeasurement.measure(request, sessionId: bot.sessionID,
                            model: choice.model, providerID: choice.provider, dataRoot: self.dataRoot,
                            windowTokens: windowTokens, call: call)
                    }
                    let fitted = try await TurnToolResultPointers.fit(nextRequest.messages, window: windowTokens, dataRoot: self.dataRoot,
                        surface: "bot", sessionID: bot.sessionID, turn: turn, measure: measure)
                    let wire = try codec.providerMessages(fitted, records: records, schemas: schemas, turn: turn)
                    let request = try SessionContextRequest(messages: wire, system: layout.system,
                        tools: codec.requestTools(providerNames.schemas) ?? [], historyCharacters: 0, rowCharacters: [:])
                    try await SessionContextMeasurement.requireFits(request, sessionId: bot.sessionID,
                        model: choice.model, providerID: choice.provider, dataRoot: self.dataRoot,
                        windowTokens: windowTokens, call: call)
                    return BotTurnRunner.Request(conversation: fitted, wire: wire, currentUserIndex: nextRequest.seed.currentUserIndex)
                },
                visible: { codec.visiblePrefix(in: $0) }, release: { codec.releasableProse(holding: &$0) },
                progress: { text in
                    ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run, .delta(text))
                    await progress?(.delta(text))
                }, decode: { text, streamed in
                    if codec == .textMarkers,
                       let violation = TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"], turn: turn).malformedCall(in: text) {
                        throw LLMError.providerError(message: violation.modelFeedback)
                    }
                    let parsed = try streamed.compactMap { try codec.decode($0) }
                    return try codec.roundCalls(streamed: parsed, text: text, schemas: schemas, turn: turn).map { call in
                        guard call.undeclaredKeys.isEmpty else {
                            throw LLMError.providerError(message: "streamed tool batch contains invalid object arguments")
                        }
                        return BotTurnRunner.Call(id: call.id.isEmpty ? UUID().uuidString : call.id,
                            name: providerNames.internalName(forProviderName: call.name), input: call.input)
                    }
                }, feedback: { text, calls, results, images in
                    guard calls.count == results.count else {
                        throw BotRunnerError.cannotRun("The tool round is missing one or more recorded results.")
                    }
                    let marker = codec == .textMarkers ? TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"], turn: turn) : nil
                    let prepared = calls.map { ParsedToolCall(id: $0.id,
                        name: providerNames.providerName(forInternalName: $0.name) ?? $0.name, input: $0.input) }
                    let blocks: [LLMContentBlock] = try zip(calls, results).map { call, result in
                        let reply = ToolResult(result)
                        return .toolResult(toolUseId: call.id, content: try reply.payload.serialize(pretty: false),
                            isError: !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome))
                    }
                    return [try ToolCallCodec.assistantMessage(prose: [.text(text)], calls: prepared,
                        pairedIDs: calls.map(\.id), markerCodec: marker),
                        LLMMessage(role: .user, content: blocks + images)]
                }, dispatch: { call, imageRound, turn in
                    let invocationID = UUID().uuidString
                    let turn = turn.with(\.invocationID, invocationID)
                    await progress?(.toolUse(name: call.name, input: .object(call.input)))
                    let result: JSONValue
                    let sink = LocalToolImage.pixelCapableTools.contains(ToolNameAliases.canonical(call.name)) ? LocalToolImage.Sink(round: imageRound) : nil
                    if let refusal = SwiftNativeTurnEngine.modelCallRefusal(
                        name: CanonicalToolNameDispatcher.canonical(call.name), input: call.input,
                        providerTools: providerNames) {
                        result = await ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: call.name, input: call.input,
                            surface: "bot", result: refusal, dataRoot: dataRoot)
                    } else {
                        do {
                            result = try await holding(work.with(\.imageSink, sink)) { work in
                                return try await dispatcher.dispatch(tool: call.name, input: call.input, surface: "bot", turn: turn,
                                    invocation: work.invocation)
                            }
                        }
                        catch is CancellationError { throw CancellationError() }
                        catch { result = ChatToolOutcome.failure(error: error, tool: call.name) }
                    }
                    // Use the same model-receipt owner as resident turns before keeping this call in the turn's records.
                    let translated = ToolNameAliases.appCallPointers(result)
                    let reply = ToolResult(SwiftNativeTurnEngine.repeatedReceipt(translated, name: call.name, input: call.input,
                        priorDispatches: execution.toolRecords, appDoor: true))
                    SwiftNativeTurnEngine.traceRepeatedReceipt(reply.payload, original: translated, tool: call.name, turn: turn)
                    let ran = ToolNameAliases.ranCall(call.name, input: call.input)
                    execution.keepTools([ToolDispatchRecord(id: call.id, name: call.name, input: call.input, ranCall: ran, result: reply.payload)])
                    let saved = await settle { () -> Result<Void, Error> in
                        do {
                            try await holding(turn.with(\.envelope, envelope)) { turn in
                            try await holding(turn.with(\.peerSteering, taint)) { turn in
                            try await self.appendToolMessage(sessionId: bot.sessionID, runId: run, toolName: call.name,
                                invocationID: invocationID,
                                input: .object(call.input), ranCall: ran,
                                result: reply.payload, ok: ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome), source: "bot",
                                    turn: turn)
                            } }
                            return .success(())
                        } catch { return .failure(error) }
                    }
                    try saved.get()
                    await progress?(.toolResult(name: call.name, output: reply.payload))
                    return (reply.payload, sink?.finish(success: ChatToolOutcome.outputLooksSuccessful(reply.payload,
                        verdict: reply.outcome) && !Task.isCancelled) ?? [])
                }, waiting: { result in
                    let reply = ToolResult(result)
                    if ChatToolOutcome.isWaitingApproval(result) {
                        return BotTurnReply(reply: "", status: .waitingForApproval, approvalID: execution.pendingApprovalID)
                    }
                    if reply.isWaitingInteraction { return BotTurnReply(reply: "", status: .waitingOnPerson) }
                    return nil
                })
        }
        var reply = try await withSessionContextMeasurement(sessionId: bot.sessionID, model: choice.model,
            providerID: choice.provider, surface: "bot", runId: run, progress: progress,
            nextTurnOutputBudgetTokens: bot.budget.tokens, turn: turn, work: work) { work in
            try await Expansion.withTurn(dataRoot: dataRoot, turn: turn) {
                try await SwiftNativeTurnEngine.untilStopped(flag) {
                    await execute(turn.with(\.offeredTools, ["app"])
                        .with(\.capabilityNote, { execution.keepCapabilityNote($0) }), call, work)
                }
            }
        }
        let stopReadFailure = ChatCancelFlag.readFailure(flag)
        if let reason = stopReadFailure {
            reply.status = .stopped
            reply.detail = reason
        }
        let attachments = ChatGeneratedImageArtifacts.attachments(from: execution.toolRecords, chosen: choices.paths, dataRoot: dataRoot)
        reply.artifacts = attachments.map {
            var artifact = BotArtifact(name: $0.name ?? "Artifact", path: $0.path ?? "")
            artifact.type = $0.type; artifact.mime = $0.mime; artifact.byteSize = $0.byteSize
            return artifact
        }
        let outcome = reply
        let persisted = await settle { [self] () -> Result<Void, Error> in
            do {
                try await holding(turn.with(\.envelope, envelope)) { turn in
                try await holding(turn.with(\.peerSteering, taint)) { turn in
                if let reason = stopReadFailure {
                    await progress?(.notice(kind: "stop_marker_unreadable", text: reason))
                }
                if outcome.status == .stopped || outcome.status == .failed {
                    _ = try await TurnTraceContext.$turnId.withValue(turnID) {
                        try await self.persistPartialIfNeeded(sessionId: bot.sessionID, runId: run, text: outcome.reply,
                            attachments: attachments, cancelled: outcome.status == .stopped,
                            failure: BotRunnerError.cannotRun(outcome.detail ?? outcome.status.rawValue), source: "bot", replyRowID: answerID,
                            onNotice: { _, _ in }, turn: turn)
                    }
                    ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run,
                        .incomplete(outcome.reply, status: outcome.status.rawValue), savedPartial: outcome.reply)
                    return
                }
                let completion: TurnEngineResult.CompletionState = outcome.status == .completed ? .completed : .incomplete
                let result = TurnEngineResult(reply: outcome.reply, modelUsed: choice.model, recalledIds: [],
                    toolDispatches: execution.toolRecords,
                    elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000),
                    completionState: completion)
                _ = try await self.appendMessage(sessionId: bot.sessionID, role: "assistant", content: outcome.reply,
                    runId: run, attachments: attachments, source: "bot", canonicalAssistantCompletion: true,
                    outcomeResult: result, outcomeTurnID: turnID, responseOutcomeStatus: "persisted",
                    mechanicalRow: .botReceipt, messageId: answerID, turn: turn)
                ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run,
                    outcome.status == .completed ? .answered(outcome.reply) : .incomplete(outcome.reply, status: outcome.status.rawValue))
                } }
                return .success(())
            } catch { return .failure(error) }
        }
        try persisted.get()
        return reply
        } } } }
    }
}
