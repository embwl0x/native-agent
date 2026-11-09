import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MemoryV2
import ProviderRouting
// Blueprint: | `SessionContextRequest.swift` | SessionContextRequest owner. |

public struct SessionContextRequest: Sendable {
    public let characters: Int
    public let historyCharacters: Int
    public let rowCharacters: [String: Int]
    public init(messages: [LLMMessage], system: String?, tools: [LLMToolSchema],
                historyCharacters: Int, rowCharacters: [String: Int]) throws {
        try self.init(messages: messages,
            systemAndToolsCharacters: LLMMessage.inputCharacters([], system: system, tools: tools),
            historyCharacters: historyCharacters, rowCharacters: rowCharacters)
    }
    package init(messages: [LLMMessage], systemAndToolsCharacters: Int,
                 historyCharacters: Int, rowCharacters: [String: Int]) throws {
        let (count, overflow) = LLMMessage.inputCharacters(messages, system: nil, tools: [])
            .addingReportingOverflow(systemAndToolsCharacters)
        guard !overflow, systemAndToolsCharacters >= 0 else {
            throw ProviderRoutingError.configurationFailed("The built request size is not representable.")
        }
        characters = count
        self.historyCharacters = historyCharacters
        self.rowCharacters = rowCharacters
    }
    public typealias Builder = @Sendable ([JSONValue], Int, Data?) async throws -> SessionContextRequest

    package static func transcript(_ rows: [JSONValue]) throws -> Data {
        var bytes = Data()
        for row in rows {
            bytes.append(try row.serializedData(pretty: false))
            bytes.append(10)
        }
        return bytes
    }
}

/// Capture replay inputs at the real history builder; Regenerate's question cut belongs here, never in measurement.
package struct SessionReplaySpec: Codable, Sendable {
    package let historyLimit: Int
    package let excludedRunID: String?
    package let replacementUserMessageID: String?
    // Only replay inputs persist; the live request holds the already-read snapshot for fitting.
    package var historySnapshot: SessionHistoryTail? = nil
    /// One transcript/query snapshot selects leads against the bodies each composed request actually holds.
    package var historyLeads: (@Sendable (Set<String>) -> String?)? = nil
    private enum CodingKeys: String, CodingKey { case historyLimit, excludedRunID, replacementUserMessageID }
    package init(historyLimit: Int, excludedRunID: String?, replacementUserMessageID: String?) {
        self.historyLimit = historyLimit; self.excludedRunID = excludedRunID
        self.replacementUserMessageID = replacementUserMessageID
    }

    package func messages(_ rows: [JSONValue], sessionId: String, dataRoot: URL) throws -> [ChatMessage] {
        let selected = SessionHistoryReader(dataRoot: dataRoot).promptMessagesWithStats(
            transcript: try SessionContextRequest.transcript(rows), excludingRunId: nil).prompt
        return SessionHistoryTail.select(
            try selected.checkedMessages(), beforeQuestionID: replacementUserMessageID, excludingRunID: excludedRunID)
    }
}

package enum SessionRequestMessages {
    package struct Seed: Sendable {
        package let messages: [LLMMessage]
        package let sent: SentTurnContext
        package let currentUserIndex: Int
    }
    /// Public moment context leads user words; live assembly adds private choices after capturing this evidence.
    package static func seed(history: [LLMMessage], block: String,
        model: String, provider: String?, userText: String, images: [LLMContentBlock]) -> Seed {
        let sent = SentTurnContext(block: block, model: model, provider: provider, userText: userText)
        var blocks: [LLMContentBlock] = []
        if !sent.block.isEmpty { blocks.append(.text(sent.block)) }
        blocks += images.isEmpty ? [.text(userText)] : LLMMessage.userWithImages(userText, images: images).content
        var messages = history
        let index: Int
        if let last = messages.last, last.role == .user {
            index = messages.count - 1
            messages[index] = LLMMessage(role: .user, content: last.content + blocks)
        } else {
            index = messages.count
            messages.append(LLMMessage(role: .user, content: blocks))
        }
        return Seed(messages: messages, sent: sent, currentUserIndex: index)
    }
}

/// Keep the sizing recipe payload-free; changing words and context remain with their user-row owner.
package struct SessionContextPlan: Codable, Sendable {
    let replay: SessionReplaySpec
    let currentRunID: String
    let currentUserMessageID: String?
    let systemAndToolsCharacters: Int
    let additionalCharacters: Int
    let model: String
    let provider: String?

    package init(replay: SessionReplaySpec, currentRunID: String, currentUserMessageID: String?,
                 systemAndToolsCharacters: Int, additionalCharacters: Int, model: String, provider: String?) {
        self.replay = replay; self.currentRunID = currentRunID; self.currentUserMessageID = currentUserMessageID
        self.systemAndToolsCharacters = systemAndToolsCharacters; self.additionalCharacters = additionalCharacters; self.model = model; self.provider = provider
    }
    package var encoded: Data { get throws { try JSONEncoder().encode(self) } }
    package func build(_ rows: [JSONValue], sessionId: String, dataRoot: URL,
                       windowTokens: Int, outputTokens: Int, charactersPerToken: Double) throws -> SessionContextRequest {
        guard systemAndToolsCharacters >= 0, additionalCharacters >= 0, !currentRunID.isEmpty,
              let row = rows.last(where: {
                  guard let fields = $0.objectValue else { return false }
                  return SentTurnContext.matches(fields, runID: currentRunID, userMessageID: currentUserMessageID)
              })?.objectValue,
              let sent = SentTurnContext(metadata: row["metadata"]?.objectValue),
              sent.model == model, sent.provider == provider, sent.userText != nil else {
            throw ProviderRoutingError.configurationFailed(
                "The admitted request's exact user context is unavailable. Repair its saved user-row delivery before measuring this conversation.")
        }
        // Size the next replay including the producing turn's answer and tool receipts; user words replay from their row.
        let nextReplay = SessionReplaySpec(historyLimit: replay.historyLimit,
            excludedRunID: nil, replacementUserMessageID: nil)
        let messages = try nextReplay.messages(rows, sessionId: sessionId, dataRoot: dataRoot)
        let admission = try SessionHistoryMessages.admission(messages: messages, historyLimit: replay.historyLimit,
            budget: ContextBudgetPolicy.resolve(windowTokens: windowTokens))
        let (fixedCharacters, overflow) = systemAndToolsCharacters.addingReportingOverflow(additionalCharacters)
        guard !overflow else { throw ProviderRoutingError.configurationFailed("The admitted request size is not representable.") }
        func request(_ history: SessionHistoryMessages.Result) throws -> SessionContextRequest {
            let seed = SessionRequestMessages.seed(history: history.messages, block: sent.block,
                model: model, provider: provider, userText: "", images: [])
            return try SessionContextRequest(messages: seed.messages, systemAndToolsCharacters: fixedCharacters,
                historyCharacters: history.characters, rowCharacters: history.rowCharacters)
        }
        guard let admission else { return try request(.empty) }
        let history = SessionHistoryMessages.project(admission)
        var built = try request(history)
        let inputBudget = Double(ContextBudgetPolicy.inputTokens(windowTokens: windowTokens, outputTokens: outputTokens)) * charactersPerToken
        if Double(built.characters) > inputBudget {
            let tail = SessionHistoryTail(admission, rowCharacters: history.rowCharacters)
            let halfBudget = SessionHistoryTail.halfBudgetCharacters(windowTokens: windowTokens, outputTokens: outputTokens)
            let fixed = built.characters - history.characters
            for checkpoint in tail.fittingCheckpoints(halfBudgetCharacters: halfBudget,
                maximumRetainedCharacters: inputBudget - Double(fixed)) {
                built = try request(tail.project(after: checkpoint))
                if Double(built.characters) <= inputBudget { break }
            }
        }
        return built
    }
}
