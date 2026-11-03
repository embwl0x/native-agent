import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Dispatcher
// Blueprint: | `BotTurnRunner.swift` | `BotTurnRunner` owns helper-only model/tool rounds over the shared prefix layout supplied by its adapter; conditioned final rounds decode `JobResult` into reply and optional Boolean verdict before progress or persistence; injected wire codecs, gated dispatch and row writer reuse their existing owners; Stop saves partial output through settle |

/// Helpers think on their own history and instructions, never the resident's turn engine.
package enum BotTurnRunner {
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
    package struct Call: Sendable {
        package let id: String
        package let name: String
        package let input: [String: JSONValue]
        package init(id: String, name: String, input: [String: JSONValue]) {
            self.id = id; self.name = name; self.input = input
        }
    }

    package static func run(
        bot: BotDefinition, messages initialMessages: [LLMMessage], system: String,
        model: String, llm: any LLMClient, schemas: [LLMToolSchema]?,
        admitRequest: @Sendable ([LLMMessage]) async throws -> Void,
        visible: @Sendable (String) -> String,
        release: @Sendable (inout String) -> String,
        progress: @Sendable (String) async -> Void,
        decode: @Sendable (String, [LLMStreamToolCall]) throws -> [Call],
        feedback: @Sendable (String, [Call], [JSONValue], [LLMContentBlock]) throws -> [LLMMessage],
        dispatch: @Sendable (Call, LocalToolImage.Round) async throws -> (JSONValue, [LLMContentBlock]),
        waiting: @Sendable (JSONValue) -> BotTurnReply?,
        attachments: @Sendable () -> [MultimodalAttachment],
        save: @escaping @Sendable (BotTurnReply, [MultimodalAttachment]) async throws -> Void
    ) async throws -> BotTurnReply {
        var messages = initialMessages
        var output = ""
        var text = ""
        var outcome = BotTurnReply(reply: "", model: model)
        let judgesCondition = BotRunner.conditionSessionID == bot.sessionID
        do {
            while true {
                try Task.checkCancellation()
                LocalToolImage.boundConversation(&messages)
                try await admitRequest(messages)
                text = ""
                var pending = ""
                var calls: [LLMStreamToolCall] = []
                var boundary: LLMToolBoundaryReason?
                for try await event in llm.streamMessages(messages: messages, system: system,
                    model: model, surface: "bot", tools: schemas) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        text += delta; pending += delta
                        let safe = release(&pending)
                        if !judgesCondition, !safe.isEmpty { await progress(safe) }
                    case .toolCall(let call): calls.append(call)
                    case .toolBoundary(let reason): boundary = boundary ?? reason
                    case .keepAlive, .replyTextSettled: break
                    }
                }
                var prose = visible(text)
                let tail = visible(pending)
                if !judgesCondition, !tail.isEmpty { await progress(tail) }
                // Only the final, call-free round is the job's result. Tool
                // narration and tool output cannot supply a verdict.
                let decoded: [Call]
                if boundary == nil { decoded = try decode(text, calls) }
                else { decoded = [] }
                if judgesCondition, boundary == nil, decoded.isEmpty {
                    do {
                        let result = try JSONDecoder().decode(JobResult.self, from: Data(prose.utf8))
                        prose = result.reply
                        outcome.conditionMet = result.conditionMet
                    } catch {
                        // Keep what the helper actually returned as partial evidence.
                        // An unreadable condition result cannot complete its contract.
                        outcome.status = .failed
                        outcome.detail = "The helper's condition result could not be decoded: \(error). Repair its structured reply before judging the condition."
                    }
                }
                if !output.isEmpty && !prose.isEmpty { output += "\n\n" }
                output += prose
                let roundText = text
                text = ""
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
                    let (result, pixels) = try await dispatch(call, imageRound)
                    results.append(result)
                    images += pixels
                    if let held = waiting(result) { outcome = held; break }
                }
                if outcome.status != .completed { break }
                messages += try feedback(roundText, decoded, results, images)
            }
        } catch {
            outcome.status = Task.isCancelled || error is CancellationError || LLMCallContext.turnTokenBudget?.exhausted == true ? .stopped : .failed
            outcome.detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            output += visible(text)
        }
        outcome.reply = output
        if judgesCondition, !output.isEmpty { await progress(output) }
        outcome.model = model
        let attachments = attachments()
        outcome.artifacts = attachments.map {
            var artifact = BotArtifact(name: $0.name ?? "Artifact", path: $0.path ?? "")
            artifact.type = $0.type; artifact.mime = $0.mime; artifact.byteSize = $0.byteSize
            return artifact
        }
        let saved = outcome
        let persisted = await settle { () -> Result<Void, Error> in
            do { try await save(saved, attachments); return .success(()) }
            catch { return .failure(error) }
        }
        try persisted.get()
        return outcome
    }
}
