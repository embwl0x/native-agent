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
// Blueprint: | `StandingBotModel.swift` | Helper adapter supplies the existing provider codec, checked tool chain and transcript writer to StandingBots' own model loop, without resident context or after-turn work; its own session compacts through the shared compactor at the shared threshold, and its thread with their is its memory of it |

extension SwiftNativeChatOrchestrationClient {
    func runStandingBot(_ bot: BotDefinition, message: String, choice: ProviderTurnChoice,
                        attachments: [MultimodalAttachment], fileAccess: String, runID: String?,
                        progress: ChatOrchestrationProgressHandler?) async throws -> BotTurnReply {
        let run = runID ?? UUID().uuidString
        let started = DispatchTime.now().uptimeNanoseconds
        let turnID = runID == nil ? run : TurnTraceContext.turnId ?? run
        let answerID = TurnTraceContext.replyRow.flatMap { $0.turnId == TurnTraceContext.turnId ? $0.messageId : nil } ?? UUID().uuidString
        let input = try Self.turnAttachmentInput(message: message, attachments: attachments, dataRoot: dataRoot, runId: run)
        let execution = ChatTurnExecution(mechanicalRow: .botReceipt)
        let choices = ReplyChoices()
        let envelope = ChatToolSessionContext.envelope
        let deliverySurface = ChatToolSessionContext.replyRoute?.surface ?? "bot"
        let taint = PeerDataTaint.current
        let dispatcher = makeTracedGatedDispatcher(fileAccess: fileAccess, verifiedSessionId: bot.sessionID)
        let schemas = try await dispatcher.listAvailableToolSchemas(named: ["app"])
        let codec = ToolCallCodec.forProvider(choice.provider)
        let providerNames = ProviderToolNameMap(schemas)
        // Its own session compacts the way hers do, with the same compactor and
        // threshold, so a long-lived helper carries its context into a
        // recollection instead of outgrowing the model. Never a failed turn.
        _ = try? await compactSession(sessionId: bot.sessionID, model: choice.model, surface: "bot",
                                      providerID: choice.provider, force: false)
        // A regenerate replaces the tail turn: its question is already on disk
        // and its old answer is not history for the new one.
        let replacing = ChatPersistenceContext.replacementAssistantMessageID != nil
        var rows = try await history.messagesWithStats(forSessionId: bot.sessionID, limit: historyLimit, strictEvidence: true).messages
        if replacing, let asked = rows.lastIndex(where: { $0.role == "user" }) { rows.removeSubrange(asked...) }
        let messages = SessionHistoryMessageProjection.project(messages: rows, historyLimit: historyLimit).messages
        var system = BotChatContract.instructions(for: bot)
        // Its conversation with her is the helper's memory of it: its own rows
        // keep what it asked for, never the words that passed (10-24: a helper
        // re-asked her the same questions on its second run).
        let herName = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
        if let thread = try? ContactThread.lines(dataRoot: dataRoot, owner: bot.sessionID, tailBytes: 96_000) {
            let said = thread.suffix(30).compactMap { line -> String? in
                let words = line.text.components(separatedBy: "\n").drop { $0.hasPrefix("[") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { return nil }
                return (line.role == "assistant" ? herName : "You") + ": " + String(words.prefix(800))
            }
            if !said.isEmpty {
                system += "\n\nWhat has passed between you and \(herName) so far, oldest first. She sees only what you send her"
                    + " with agent.message; this run's own reply goes to whoever ran you, not to her:\n" + said.joined(separator: "\n\n")
            }
        }
        if codec == .textMarkers {
            let context = TurnContext(surface: "bot", personaDocs: [:], personaFingerprint: "", recalled: [],
                modelId: choice.model, reasoningEffort: choice.reasoningEffort, toolsAvailable: schemas.map(\.name),
                userMessage: message, toolSchemas: schemas, turnReach: TurnReach())
            system = TextMarkerCodec.systemLayout(baseSystem: system, segments: nil, context: context).system
        }
        let wireSystem = system
        if !replacing {
            _ = try await appendMessage(sessionId: bot.sessionID, role: "user", content: message,
                runId: run, attachments: attachments, source: "bot", mechanicalRow: .botReceipt)
        }
        let flag = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: bot.sessionID, runId: run,
            turnId: turnID)
        let admission = TurnRouteAdmission(routingSurface: "chat", modelId: choice.model,
            reasoningEffort: choice.reasoningEffort, providerId: choice.provider, serviceTier: choice.fast ? "priority" : nil)
        let execute: @Sendable () async throws -> BotTurnReply = { [self] in
            try await BotTurnRunner.run(bot: bot, input: .userWithImages(input.userMessage, images: input.imageBlocks),
                history: messages, system: wireSystem,
                model: choice.model, llm: llm, schemas: codec.requestTools(providerNames.schemas),
                visible: { codec.visiblePrefix(in: $0) }, release: { codec.releasableProse(holding: &$0) },
                progress: { text in
                    ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run, .delta(text))
                    await progress?(.delta(text))
                }, decode: { text, streamed in
                    let parsed = try streamed.compactMap { try codec.decode($0) }
                    return try codec.roundCalls(streamed: parsed, text: text, schemas: schemas).map { call in
                        guard call.undeclaredKeys.isEmpty else {
                            throw LLMError.providerError(message: "streamed tool batch contains invalid object arguments")
                        }
                        return BotTurnRunner.Call(id: call.id.isEmpty ? UUID().uuidString : call.id,
                            name: providerNames.internalName(forProviderName: call.name), input: call.input)
                    }
                }, feedback: { text, calls, results, images in
                    if codec == .textMarkers {
                        var carrier = ""
                        let marker = TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"])
                        for (index, call) in calls.enumerated() {
                            marker.appendResult(index: index, toolName: call.name,
                                ok: ChatToolOutcome.outputLooksSuccessful(try JSONValue.parse(Data(results[index].utf8))), content: results[index], to: &carrier)
                        }
                        marker.closeRound(&carrier)
                        return [.assistantText(text), .userWithImages(carrier, images: images)]
                    }
                    return [LLMMessage(role: .assistant, content: [.text(text)] + (try calls.map {
                        .toolUse(id: $0.id, name: providerNames.providerName(forInternalName: $0.name) ?? $0.name,
                            inputJSON: try JSONValue.object($0.input).serializedData(pretty: false))
                    })), LLMMessage(role: .user, content: (try zip(calls, results).map {
                        .toolResult(toolUseId: $0.0.id, content: $0.1,
                            isError: !ChatToolOutcome.outputLooksSuccessful(try JSONValue.parse(Data($0.1.utf8))))
                    }) + images)]
                }, dispatch: { call, imageRound in
                    await progress?(.toolUse(name: call.name, input: .object(call.input)))
                    let result: JSONValue
                    let sink = LocalToolImage.pixelCapableTools.contains(call.name) ? LocalToolImage.Sink(round: imageRound) : nil
                    do {
                        result = try await LocalToolImage.$sink.withValue(sink) {
                            try await dispatcher.dispatch(tool: call.name, input: call.input, surface: "bot")
                        }
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch { result = ChatToolOutcome.failure(error: error, tool: call.name) }
                    let ran = ToolNameAliases.ranCall(call.name, input: call.input)
                    execution.keepTools([ToolDispatchRecord(id: call.id, name: call.name, input: call.input, ranCall: ran, result: result)])
                    let saved = await settle { () -> Result<Void, Error> in
                        do {
                            try await ChatToolSessionContext.$envelope.withValue(envelope) {
                            try await PeerDataTaint.$current.withValue(taint) {
                            try await self.appendToolMessage(sessionId: bot.sessionID, runId: run, toolName: call.name,
                                inputJSON: JSONValue.object(call.input).serialize(pretty: false), ranCall: ran,
                                resultSummary: result.serialize(pretty: false), ok: ChatToolOutcome.outputLooksSuccessful(result), source: "bot")
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
                }, artifacts: {
                    ChatGeneratedImageArtifacts.attachments(from: execution.toolRecords, chosen: choices.paths, dataRoot: self.dataRoot).map {
                        var artifact = BotArtifact(name: $0.name ?? "Artifact", path: $0.path ?? "")
                        artifact.type = $0.type; artifact.mime = $0.mime; artifact.byteSize = $0.byteSize
                        return artifact
                    }
                }, save: { outcome in
                    defer { ChatCancelFlag.finish(flag) }
                    let attachments = ChatGeneratedImageArtifacts.attachments(
                        from: execution.toolRecords, chosen: choices.paths, dataRoot: self.dataRoot)
                    try await ChatToolSessionContext.$envelope.withValue(envelope) {
                    try await PeerDataTaint.$current.withValue(taint) {
                    if outcome.status == .stopped || outcome.status == .failed {
                        _ = try await TurnTraceContext.$turnId.withValue(turnID) {
                            try await self.persistPartialIfNeeded(sessionId: bot.sessionID, runId: run, text: outcome.reply,
                                attachments: attachments,
                                cancelled: outcome.status == .stopped,
                                failure: BotRunnerError.cannotRun(outcome.detail ?? outcome.status.rawValue), source: "bot", onNotice: { _, _ in })
                        }
                        ChatLiveTap.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run,
                            .incomplete(outcome.reply, status: outcome.status.rawValue), savedPartial: outcome.reply)
                        return
                    }
                    let completion: TurnEngineResult.CompletionState = outcome.status == .completed ? .completed : .incomplete
                    let result = TurnEngineResult(reply: outcome.reply, modelUsed: choice.model, recalledIds: [],
                        toolDispatches: execution.toolRecords,
                        elapsedMs: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000),
                        rawLLMResponse: "", completionState: completion)
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
        return try await ProviderTurnChoice.$current.withValue(choice) {
        try await ReplyChoices.$current.withValue(choices) {
        try await TurnTraceContext.$turnId.withValue(turnID) {
        try await ChatPersistenceContext.$pinnedTurnRunID.withValue(run) {
        try await LLMCallContext.$toolCapabilityNote.withValue({ execution.keepCapabilityNote($0) }) {
        try await withModelContext(admission, surface: "bot") {
        try await LLMCallContext.$sessionId.withValue(bot.sessionID) {
        try await LLMCallContext.$systemSegments.withValue(nil) {
        try await LLMCallContext.$turnTokenBudget.withValue(TurnTokenBudget(tokens: bot.budget.tokens)) {
        try await LLMCallContext.$turnActiveTools.withValue(["app"]) {
        try await ChatTurnExecution.$current.withValue(execution) {
            try await SwiftNativeTurnEngine.untilStopped(flag, execute)
        } } } } } } } } } } }
    }
}
