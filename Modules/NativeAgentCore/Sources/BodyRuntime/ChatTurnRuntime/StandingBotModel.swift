import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import MindCore
import MacNerves
import SenseCore
import DeskCore
// Blueprint: | `StandingBotModel.swift` | Helper rounds consume the shared model stream and keep the helper's condition, budget and waiting state |

extension SwiftNativeChatOrchestrationClient {
    func standingBotExecution(
        _ bot: BotDefinition, choice: ProviderTurnChoice, progress: TurnEventSink?, run: String, deliverySurface: String,
        execution: ChatTurnExecution, schemas: [LLMToolSchema], codec: ToolCallCodec, providerNames: ProviderToolNameMap,
        windowTokens: Int, context: TurnContext, seed: ConversationPrefixSeeding.Seed,
        system: String, dispatcher: any ToolDispatchClient,
        turn: Turn, call: LLMCall, work: ChatTurnWork
    ) async -> BotTurnReply {
        func publish(_ text: String) async {
            self.liveTurns?.emit(sessionId: bot.sessionID, surface: deliverySurface, runId: run, .delta(text))
            await progress?(.delta(text))
        }
        func decode(_ text: String, _ streamed: [LLMStreamToolCall]) throws -> [ParsedToolCall] {
            if codec == .textMarkers,
               let violation = TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"], turn: turn).malformedCall(in: text) {
                throw LLMError.providerError(message: violation.modelFeedback)
            }
            let parsed = try streamed.compactMap { try codec.decode($0) }
            return try codec.roundCalls(streamed: parsed, text: text, schemas: schemas, turn: turn).map { call in
                guard call.undeclaredKeys.isEmpty else {
                    throw LLMError.providerError(message: "streamed tool batch contains invalid object arguments")
                }
                return ParsedToolCall(id: call.id.isEmpty ? UUID().uuidString : call.id,
                    name: providerNames.internalName(forProviderName: call.name), input: call.input)
            }
        }
        var messages = seed.messages
        var previousContext = context, previousSeed = seed
        var output = ""
        var round = ModelRoundKernel.Stream()
        var outcome = BotTurnReply(reply: "", model: choice.model)
        let judgesCondition = work.botOptions.conditionSessionID == bot.sessionID
        do {
            while true {
                try Task.checkCancellation()
                LocalToolImage.boundConversation(&messages)
                let records = execution.toolRecords
                let additional = try ConversationPrefixSeeding.additionalMessages(in: messages, after: previousSeed)
                let encoded = try codec.providerMessages(additional, records: records, schemas: schemas, turn: turn)
                previousContext = try await fitSessionRequest(previousContext, codec: codec, additionalMessages: encoded,
                    sessionId: bot.sessionID, surface: "bot", turn: turn)
                let request = try ConversationPrefixSeeding.request(previousContext, codec: codec).appending(additional)
                previousSeed = request.seed
                let tools = codec.requestTools(providerNames.schemas)
                let fitted = try await ModelRoundKernel.fitAndMeasure(request.messages, codec: codec, records: records,
                    context: previousContext, system: system, tools: tools, window: windowTokens, root: dataRoot,
                    surface: "bot", session: bot.sessionID, owner: bot.sessionID, turn: turn, call: call)
                messages = fitted.conversation
                round = ModelRoundKernel.Stream()
                var calls: [LLMStreamToolCall] = []
                var boundary: LLMToolBoundaryReason?
                try await ModelRoundKernel.streamRound(llm: llm, messages: fitted.wire, system: system,
                    model: choice.model, tools: tools, call: call.with(\.currentUserIndex, previousSeed.currentUserIndex),
                    codec: codec, round: round, stop: nil) { event, safe in
                    switch event {
                    case .textDelta: if !judgesCondition, !safe.isEmpty { await publish(safe) }
                    case .toolCall(let call): calls.append(call)
                    case .toolBoundary(let reason): boundary = boundary ?? reason
                    case .keepAlive, .callInput, .replyTextSettled: break
                    }
                }
                var prose = round.visiblePartial(codec)
                let tail = codec.visiblePrefix(in: round.pendingProtocolDelta)
                if !judgesCondition, !tail.isEmpty { await publish(tail) }
                let decoded = try boundary == nil ? decode(round.iterAccumulated, calls) : []
                if judgesCondition, boundary == nil, decoded.isEmpty {
                    do {
                        let result = try JSONDecoder().decode(JobResult.self, from: Data(prose.utf8))
                        prose = result.reply
                        outcome.conditionMet = result.conditionMet
                    } catch {
                        outcome.status = .failed
                        outcome.detail = """
                            The helper's condition result could not be decoded: \(error). Repair its structured reply before judging the condition.
                            """
                    }
                }
                if !output.isEmpty && !prose.isEmpty { output += "\n\n" }
                output += prose
                let roundText = round.iterAccumulated
                round.iterAccumulated = ""
                if let boundary {
                    outcome.status = .failed
                    outcome.detail = "The reply is incomplete (\(boundary.rawValue)); no calls from this round were dispatched."
                    break
                }
                if decoded.isEmpty { break }
                var results: [JSONValue] = []
                var images: [LLMContentBlock] = []
                let imageRound = LocalToolImage.Round()
                for call in decoded {
                    try Task.checkCancellation()
                    let (result, pixels) = try await dispatchStandingBotCall(call, bot: bot, run: run, imageRound: imageRound,
                        providerNames: providerNames, dispatcher: dispatcher, execution: execution, progress: progress,
                        turn: turn, work: work)
                    results.append(result)
                    images += pixels
                    if ChatToolOutcome.isWaitingApproval(result) {
                        outcome = BotTurnReply(reply: "", status: .waitingForApproval, approvalID: execution.pendingApprovalID)
                        break
                    }
                    if ToolResult(result).isWaitingInteraction {
                        outcome = BotTurnReply(reply: "", status: .waitingOnPerson)
                        break
                    }
                }
                if outcome.status != .completed { break }
                let marker = codec == .textMarkers ? TextMarkerCodec(schemas: schemas, turnActiveTools: ["app"], turn: turn) : nil
                let prepared = decoded.map { ParsedToolCall(id: $0.id,
                    name: providerNames.providerName(forInternalName: $0.name) ?? $0.name, input: $0.input) }
                let blocks: [LLMContentBlock] = try zip(decoded, results).map { call, result in
                    let reply = ToolResult(result)
                    return .toolResult(toolUseId: call.id, content: try reply.payload.serialize(pretty: false),
                        isError: !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome))
                }
                messages += [try ToolCallCodec.assistantMessage(prose: [.text(roundText)], calls: prepared,
                    pairedIDs: decoded.map(\.id), markerCodec: marker),
                    LLMMessage(role: .user, content: blocks + images)]
            }
        } catch {
            outcome.status = Task.isCancelled || error is CancellationError || turn.tokenBudget?.exhausted == true ? .stopped : .failed
            outcome.detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            output += round.visiblePartial(codec)
        }
        outcome.reply = output
        if judgesCondition, !output.isEmpty { await publish(output) }
        outcome.model = choice.model
        return outcome
    }

    private struct JobResult: Decodable {
        let reply: String
        let conditionMet: Bool?
        enum CodingKeys: String, CodingKey { case reply; case conditionMet = "condition_met" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reply = try c.decode(String.self, forKey: .reply)
            guard c.contains(.conditionMet) else {
                throw DecodingError.keyNotFound(CodingKeys.conditionMet,
                    .init(codingPath: decoder.codingPath, debugDescription: "The job result requires condition_met (boolean or null)."))
            }
            conditionMet = try c.decodeIfPresent(Bool.self, forKey: .conditionMet)
        }
    }
}
