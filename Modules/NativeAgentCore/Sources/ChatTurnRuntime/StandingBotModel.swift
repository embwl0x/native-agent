import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import ChatTurnContracts
import ChatSessionWork
import ChatToolParsing
import Transcripts
import ToolRegistry
import TurnTrace
import Dispatcher
import PersonaEngine
import AgentWorkspace
// Blueprint: | `StandingBotModel.swift` | Helper adapter uses shared whole-transcript replay, measured recollection fit, prefix seeding and cache markers with its own instructions/history; checked codecs, tools and transcript writer feed StandingBots' own loop without resident context or after-turn work; `Expansion.withTurn` closes its predictions on every exit; contact thread rides the shared paragraph delta/keyframe block stored and replayed on its user row |

extension SwiftNativeChatOrchestrationClient {
    func runStandingBot(_ bot: BotDefinition, message: String, choice: ProviderTurnChoice,
                        attachments: [MultimodalAttachment], fileAccess: String, runID: String?,
                        progress: TurnEventSink?) async throws -> BotTurnReply {
        let admission = TurnRouteAdmission(routingSurface: "chat", modelId: choice.model,
            reasoningEffort: choice.reasoningEffort, providerId: choice.provider, serviceTier: choice.fast ? "priority" : nil)
        return try await ProviderTurnChoice.$current.withValue(choice) {
        try await withModelContext(admission, surface: "bot") {
        try await LLMCallContext.$turnTokenBudget.withValue(TurnTokenBudget(tokens: bot.budget.tokens)) {
        let run = runID ?? UUID().uuidString
        let started = DispatchTime.now().uptimeNanoseconds
        let turnID = runID == nil ? run : TurnTraceContext.turnId ?? run
        let answerID = TurnTraceContext.replyRow?.messageId(turn: TurnTraceContext.turnId, session: bot.sessionID) ?? UUID().uuidString
        let input = try Self.turnAttachmentInput(message: message, attachments: attachments, dataRoot: dataRoot, runId: run)
        let execution = ChatTurnExecution(mechanicalRow: .botReceipt)
        let choices = ReplyChoices()
        let envelope = ChatToolSessionContext.envelope
        let deliverySurface = ChatToolSessionContext.replyRoute?.surface ?? "bot"
        let taint = PeerDataTaint.current
        let dispatcher = makeTracedGatedDispatcher(fileAccess: fileAccess, verifiedSessionId: bot.sessionID)
        let schemas = try await dispatcher.listAvailableToolSchemas(named: ["app"])
        let codec = try ToolCallCodec.forProvider(choice.provider)
        let providerNames = ProviderToolNameMap(schemas)
        let replacing = ChatPersistenceContext.replacementAssistantMessageID != nil
            || ChatPersistenceContext.replacementUserMessageID != nil
        // Like resident chat, admission saves the current words before the
        // shared measurement, so the trigger includes this turn's added text.
        if !replacing {
            _ = try await appendMessage(sessionId: bot.sessionID, role: "user", content: message,
                runId: run, attachments: attachments, source: "bot", mechanicalRow: .botReceipt,
                messageId: ChatPersistenceContext.pinnedUserMessageID ?? UUID().uuidString)
        }
        _ = try await preparePendingSessionHistoryForTurn(sessionId: bot.sessionID,
            model: choice.model, surface: "bot", runId: run, progress: progress)
        // A regenerate replaces the tail turn: its question is already on disk
        // and its old answer is not history for the new one.
        let historyRead = history.promptMessagesWithStats(
            transcript: try await history.transcriptBytes(forSessionId: bot.sessionID),
            excludingRunId: replacing ? nil : run
        ).prompt
        var rows = try historyRead.checkedMessages()
        var replacingUserID = ChatPersistenceContext.replacementUserMessageID
        if replacing, let asked = rows.lastIndex(where: { $0.role == "user" }) {
            guard case .object(let row)? = rows[asked].extras, case .string(let id)? = row["id"] else {
                throw ProviderRoutingError.configurationFailed("The helper's saved question has no readable identity.")
            }
            replacingUserID = id
            rows = SessionReplaySpec.beforeQuestion(rows, id: id)
        }
        let windowTokens = ContextBudgetPolicy.windowTokens(
            forModel: choice.model, providerID: choice.provider, dataRoot: dataRoot)
        var messages: [LLMMessage] = []
        var replayedContexts: [SentTurnContext] = []
        var historyRowCharacters: [String: Int] = [:]
        var contextWindow = "0:"
        if let admitted = try SessionHistoryMessages.admission(
            messages: rows, historyLimit: historyLimit, windowTokens: windowTokens) {
            let projected = SessionHistoryMessages.project(admitted)
            messages = projected.messages
            replayedContexts = projected.replayedContexts
            historyRowCharacters = projected.rowCharacters
            contextWindow = projected.contextWindow
        }
        let system = try BotChatContract.instructions(for: bot)
        var contactThread = ""
        // Its conversation with her is the helper's memory of it: its own rows
        // keep what it asked for, never the words that passed.
        let herName = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
        let thread = try ContactThread.lines(dataRoot: dataRoot, owner: bot.sessionID, tailBytes: 96_000)
        do {
            let said = thread.suffix(30).compactMap { line -> String? in
                let words = line.text.components(separatedBy: "\n").drop { $0.hasPrefix("[") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { return nil }
                return (line.role == "assistant" ? herName : "You") + ": " + String(words.prefix(800))
            }
            if !said.isEmpty {
                contactThread = "What has passed between you and \(herName) so far, oldest first. She sees only what you send her"
                    + " with agent.message; this run's own reply goes to whoever ran you, not to her:\n" + said.joined(separator: "\n\n")
            }
        }
        var context = TurnContext(surface: "bot", personaDocs: [:], personaFingerprint: "", recalled: [],
            modelId: choice.model, reasoningEffort: choice.reasoningEffort, providerId: choice.provider,
            toolsAvailable: schemas.map(\.name), userMessage: input.userMessage, toolSchemas: schemas,
            imageBlocks: input.imageBlocks, historyMessages: messages,
            turnReach: TurnReach())
            .composing(SystemPromptSegments(stable: system, dynamic: contactThread), tools: nil)
        context.replayedTurnContexts = replayedContexts
        context.historyContextWindow = contextWindow
        context.historyRowCharacters = historyRowCharacters
        context.historyReplaySpec = SessionReplaySpec(historyLimit: historyLimit,
            excludedRunID: replacing ? nil : run,
            replacementUserMessageID: replacing ? replacingUserID : nil)
        context = try await fitSessionRequest(context, codec: codec, sessionId: bot.sessionID,
            surface: "bot", runId: run, progress: progress)
        let request = try ConversationPrefixSeeding.request(context, codec: codec)
        let seed = request.seed
        let layout = (system: request.system ?? "", segments: request.segments)
        let requestPlan = try request.plan(runID: run, userMessageID: replacingUserID).encoded
        let prefix = ConversationPrefixTelemetrySink()
        prefix.set(ConversationPrefixSeeding.telemetry(seed,
            toolSchemaFingerprint: SwiftNativeTurnEngine.toolSchemaFingerprint(schemas)))
        await seed.sentContext.persist(sessionID: bot.sessionID, runID: run,
            userMessageID: replacingUserID, dataRoot: dataRoot)
        let flag = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: bot.sessionID, runId: run,
            turnId: turnID)
        let execute: @Sendable () async throws -> BotTurnReply = { [self] in
            try await BotTurnRunner.run(bot: bot, messages: seed.messages, system: layout.system,
                model: choice.model, llm: llm, schemas: codec.requestTools(providerNames.schemas),
                admitRequest: { messages in
                    let request = try SessionContextRequest(messages: messages, system: layout.system,
                        tools: codec.requestTools(providerNames.schemas) ?? [], historyCharacters: 0, rowCharacters: [:])
                    try await SessionContextMeasurement.requireFits(request, sessionId: bot.sessionID,
                        model: choice.model, providerID: choice.provider, dataRoot: self.dataRoot,
                        windowTokens: windowTokens)
                },
                visible: { codec.visiblePrefix(in: $0) }, release: { codec.releasableProse(holding: &$0) },
                progress: { text in
                    ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run, .delta(text))
                    await progress?(.delta(text))
                }, decode: { text, streamed in
                    if codec == .textMarkers,
                       let violation = TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"]).malformedCall(in: text) {
                        throw LLMError.providerError(message: violation.modelFeedback)
                    }
                    let parsed = try streamed.compactMap { try codec.decode($0) }
                    return try codec.roundCalls(streamed: parsed, text: text, schemas: schemas).map { call in
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
                    let marker = codec == .textMarkers ? TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"]) : nil
                    let prepared = calls.map { ParsedToolCall(id: $0.id,
                        name: providerNames.providerName(forInternalName: $0.name) ?? $0.name, input: $0.input) }
                    let blocks: [LLMContentBlock] = try zip(calls, results).map { call, result in
                        .toolResult(toolUseId: call.id, content: try result.serialize(pretty: false),
                            isError: !ChatToolOutcome.outputLooksSuccessful(result))
                    }
                    let feedback = ToolCallCodec.resultBlocks(blocks, toolNames: calls.map(\.name), markerCodec: marker)
                    return [try ToolCallCodec.assistantMessage(prose: [.text(text)], calls: prepared,
                        pairedIDs: calls.map(\.id), markerCodec: marker),
                        LLMMessage(role: .user, content: marker == nil ? feedback + images : images + feedback)]
                }, dispatch: { call, imageRound in
                    let invocationID = UUID().uuidString
                    await ToolReceipt.$currentInvocationID.withValue(invocationID) {
                        await progress?(.toolUse(name: call.name, input: .object(call.input)))
                    }
                    let result: JSONValue
                    let sink = LocalToolImage.pixelCapableTools.contains(ToolNameAliases.canonical(call.name)) ? LocalToolImage.Sink(round: imageRound) : nil
                    if let refusal = SwiftNativeTurnEngine.modelCallRefusal(
                        name: CanonicalToolNameDispatcher.canonical(call.name), input: call.input,
                        providerTools: providerNames) {
                        result = refusal
                        ChatToolDispatchTracer.traceUndispatched(tool: call.name, input: call.input,
                            surface: "bot", result: refusal)
                    } else {
                        do {
                            result = try await LocalToolImage.$sink.withValue(sink) {
                                try await dispatcher.dispatch(tool: call.name, input: call.input, surface: "bot")
                            }
                        }
                        catch is CancellationError { throw CancellationError() }
                        catch { result = ChatToolOutcome.failure(error: error, tool: call.name) }
                    }
                    let ran = ToolNameAliases.ranCall(call.name, input: call.input)
                    execution.keepTools([ToolDispatchRecord(id: call.id, name: call.name, input: call.input, ranCall: ran, result: result)])
                    let saved = await settle { () -> Result<Void, Error> in
                        do {
                            try await ChatToolSessionContext.$envelope.withValue(envelope) {
                            try await PeerDataTaint.$current.withValue(taint) {
                            try await self.appendToolMessage(sessionId: bot.sessionID, runId: run, toolName: call.name,
                                invocationID: invocationID,
                                input: .object(call.input), ranCall: ran,
                                result: result, ok: ChatToolOutcome.outputLooksSuccessful(result), source: "bot")
                            } }
                            return .success(())
                        } catch { return .failure(error) }
                    }
                    try saved.get()
                    await progress?(.toolResult(name: call.name, output: result))
                    return (result, sink?.finish(success: ChatToolOutcome.outputLooksSuccessful(result) && !Task.isCancelled) ?? [])
                }, waiting: { result in
                    if ChatToolOutcome.isWaitingApproval(result) {
                        return BotTurnReply(reply: "", status: .waitingForApproval, approvalID: execution.pendingApprovalID)
                    }
                    if ChatToolOutcome.isWaitingOnPerson(result) { return BotTurnReply(reply: "", status: .waitingOnPerson) }
                    return nil
                }, attachments: {
                    ChatGeneratedImageArtifacts.attachments(from: execution.toolRecords, chosen: choices.paths, dataRoot: self.dataRoot)
                }, save: { outcome, attachments in
                    defer { ChatCancelFlag.finish(flag) }
                    try await ChatToolSessionContext.$envelope.withValue(envelope) {
                    try await PeerDataTaint.$current.withValue(taint) {
                    if outcome.status == .stopped || outcome.status == .failed {
                        _ = try await TurnTraceContext.$turnId.withValue(turnID) {
                            try await self.persistPartialIfNeeded(sessionId: bot.sessionID, runId: run, text: outcome.reply,
                                attachments: attachments,
                                cancelled: outcome.status == .stopped,
                                failure: BotRunnerError.cannotRun(outcome.detail ?? outcome.status.rawValue), source: "bot", replyRowID: answerID, onNotice: { _, _ in })
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
                        runId: run, attachments: attachments,
                        source: "bot", canonicalAssistantCompletion: true,
                        outcomeResult: result,
                        outcomeTurnID: turnID, responseOutcomeStatus: "persisted",
                        mechanicalRow: .botReceipt, messageId: answerID)
                    ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run,
                        outcome.status == .completed ? .answered(outcome.reply) : .incomplete(outcome.reply, status: outcome.status.rawValue))
                    } }
                })
        }
        return try await ReplyChoices.$current.withValue(choices) {
        try await TurnTraceContext.$turnId.withValue(turnID) {
        try await ChatPersistenceContext.$pinnedTurnRunID.withValue(run) {
        try await LLMCallContext.$toolCapabilityNote.withValue({ execution.keepCapabilityNote($0) }) {
        try await LLMCallContext.$sessionId.withValue(bot.sessionID) {
        try await LLMCallContext.$systemSegments.withValue(layout.segments) {
        try await ConversationPrefixTelemetry.$sink.withValue(prefix) {
        try await ConversationPrefixBoundary.$currentUserIndex.withValue(seed.currentUserIndex) {
        try await AnthropicOAuthTransport.MessagesCacheHint.$withinTurnReuse.withValue(true) {
        try await LLMCallContext.$turnActiveTools.withValue(["app"]) {
        try await ChatTurnExecution.$current.withValue(execution) {
            try await withSessionContextMeasurement(sessionId: bot.sessionID, model: choice.model,
                providerID: choice.provider, surface: "bot", runId: run, progress: progress,
                nextTurnOutputBudgetTokens: bot.budget.tokens) {
            try await LLMCallContext.$sessionRequestPlan.withValue(requestPlan) {
            try await Expansion.withTurn(dataRoot: dataRoot) {
                try await SwiftNativeTurnEngine.untilStopped(flag, execute)
            }
            }
            }
        } } } } } } } } } } } }
        } }
    }
}
