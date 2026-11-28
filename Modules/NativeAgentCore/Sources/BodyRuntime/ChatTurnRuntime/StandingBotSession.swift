import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import MindCore
import MacNerves
import SenseCore
import DeskCore
// Blueprint: | `StandingBotSession.swift` | Helper admission, instructions, replay, tool receipts and reply settlement |

struct StandingBotReplySaveFailure: Error {
    let underlying: any Error
}

extension SwiftNativeChatOrchestrationClient {
    func runStandingBot(_ bot: BotDefinition, message: String, choice: ProviderTurnChoice,
                        attachments: [MultimodalAttachment], fileAccess: String, runID: String?,
                        progress: TurnEventSink?, turn: Turn, work: ChatTurnWork) async throws -> BotTurnReply {
        let admission = TurnRouteAdmission(routingSurface: "chat", modelId: choice.model,
            reasoningEffort: choice.reasoningEffort, providerId: choice.provider, serviceTier: choice.fast ? "priority" : nil)
        return try await holding(turn.with(\.providerChoice, choice)) { turn in
        try await withModelContext(admission, turn: turn) { turn in
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
        let (context, windowTokens, replacingUserID) = try await standingBotContext(bot, choice: choice, turn: turn,
            run: run, replacing: replacing, input: input, schemas: schemas, codec: codec)
        let request = try ConversationPrefixSeeding.request(context, codec: codec)
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
        let reply = try await withSessionContextMeasurement(sessionId: bot.sessionID, surface: "bot",
            turn: turn, work: work) { work in
            try await TurnDispatchClosure.withTurn(dataRoot: dataRoot, turn: turn) {
                try await SwiftNativeTurnEngine.untilStopped(flag) {
                    let active = turn.with(\.offeredTools, ["app"])
                        .with(\.capabilityNote, { execution.keepCapabilityNote($0) })
                    return await self.standingBotExecution(bot, choice: choice, progress: progress, run: run,
                        deliverySurface: deliverySurface, execution: execution, schemas: schemas, codec: codec,
                        providerNames: providerNames, windowTokens: windowTokens, context: context, seed: seed, system: layout.system,
                        dispatcher: dispatcher,
                        turn: active, call: call.with(\.turn, active), work: work)
                }
            }
        }
        return try await persistStandingBotReply(reply, bot: bot, choice: choice, progress: progress, turn: turn,
            flag: flag, execution: execution, choices: choices, envelope: envelope, taint: taint, run: run,
            turnID: turnID, answerID: answerID, deliverySurface: deliverySurface, started: started)
        } } }
    }

    /// The helper's replayed conversation and contact thread, fitted to its model's window.
    private func standingBotContext(
        _ bot: BotDefinition, choice: ProviderTurnChoice, turn: Turn, run: String, replacing: Bool,
        input: TurnAttachmentInput, schemas: [LLMToolSchema], codec: ToolCallCodec
    ) async throws -> (context: TurnContext, windowTokens: Int, replacingUserID: String?) {
        // A regenerate replaces the tail turn: its question is already on disk
        // and its old answer is not history for the new one.
        let historyRead = history.promptMessagesWithStats(
            transcript: try await history.transcriptBytes(forSessionId: bot.sessionID).bytes
        )
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
            surface: "bot", turn: turn)
        return (context, windowTokens, replacingUserID)
    }

    func dispatchStandingBotCall(_ call: ParsedToolCall, bot: BotDefinition, run: String, imageRound: LocalToolImage.Round,
                                 providerNames: ProviderToolNameMap, dispatcher: any ToolDispatchClient,
                                 execution: ChatTurnExecution, progress: TurnEventSink?,
                                 turn activeTurn: Turn, work: ChatTurnWork) async throws -> (JSONValue, [LLMContentBlock]) {
        let prepared = SwiftNativeTurnEngine.PreparedToolCall(pairedId: call.id, requestedName: call.name,
            internalName: CanonicalToolNameDispatcher.canonical(call.name), dispatchInput: call.input,
            ranCall: ToolNameAliases.ranCall(call.name, input: call.input))
        let invocationID = prepared.invocationID
        let turn = activeTurn.with(\.invocationID, invocationID)
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
                result = try await SwiftNativeTurnEngine.runSingleDispatch(prepared: prepared, watchName: call.name,
                    surface: "bot", tools: dispatcher, imageSink: sink, turn: turn, work: work) { _, dispatch in
                    try await dispatch()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let ended = CallBound.ended(error, name: call.name) { result = ended }
                else { result = ChatToolOutcome.failure(error: error, tool: call.name) }
            }
        }
        let translated = ToolNameAliases.appCallPointers(result)
        let reply = ToolResult(SwiftNativeTurnEngine.repeatedReceipt(translated, name: call.name, input: call.input,
            priorDispatches: execution.toolRecords, appDoor: true))
        SwiftNativeTurnEngine.traceRepeatedReceipt(reply.payload, original: translated, tool: call.name, turn: turn)
        let ran = ToolNameAliases.ranCall(call.name, input: call.input)
        execution.keepTools([ToolDispatchRecord(id: call.id, name: call.name, input: call.input, ranCall: ran, result: reply.payload)])
        let saved = await settle { () -> Result<Void, Error> in
            do {
                try await self.appendToolMessage(sessionId: bot.sessionID, runId: run, toolName: prepared.requestedName,
                    invocationID: invocationID,
                    input: .object(prepared.dispatchInput), ranCall: ran,
                    result: reply.payload, ok: ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome), source: "bot",
                    turn: turn)
                return .success(())
            } catch { return .failure(error) }
        }
        try saved.get()
        await progress?(.toolResult(name: call.name, output: reply.payload))
        return (reply.payload, sink?.finish(success: ChatToolOutcome.outputLooksSuccessful(reply.payload,
            verdict: reply.outcome) && !Task.isCancelled) ?? [])
    }

    /// Saves the helper's reply as its turn ends: a stopped or failed reply as its partial, any other as its answer.
    private func persistStandingBotReply(
        _ executed: BotTurnReply, bot: BotDefinition, choice: ProviderTurnChoice, progress: TurnEventSink?, turn: Turn,
        flag: URL, execution: ChatTurnExecution, choices: ReplyChoices, envelope: TurnEnvelope?, taint: PeerDataTaint?,
        run: String, turnID: String, answerID: String, deliverySurface: String, started: UInt64
    ) async throws -> BotTurnReply {
        var reply = executed
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
                    self.liveTurns?.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run,
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
                self.liveTurns?.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run,
                    outcome.status == .completed ? .answered(outcome.reply) : .incomplete(outcome.reply, status: outcome.status.rawValue))
                } }
                return .success(())
            } catch { return .failure(error) }
        }
        if case .failure(let error) = persisted {
            if turn.replyRow?.messageId(turn: turn.id, session: bot.sessionID) != nil {
                throw StandingBotReplySaveFailure(underlying: error)
            }
            throw error
        }
        return reply
    }
}
