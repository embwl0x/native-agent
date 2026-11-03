import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MemoryV2
import ProviderRouting
// Blueprint: | `SessionContextRequest.swift` | Canonical pure replay/seed builder reports final request characters; saved sizing clears turn-only replay cuts, includes completed answers/receipts and never seeds the saved user words twice |

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

/// The replay owner's inputs, captured by the real resident/helper history
/// builder. Regenerate's question cut belongs here, never in measurement.
package struct SessionReplaySpec: Codable, Sendable {
    let historyLimit: Int
    let excludedRunID: String?
    package let replacementUserMessageID: String?
    var carryAnchor = false
    var admittedPriorSessionID: String? = nil
    package init(historyLimit: Int, excludedRunID: String?, replacementUserMessageID: String?,
                 carryAnchor: Bool = false, admittedPriorSessionID: String? = nil) {
        self.historyLimit = historyLimit; self.excludedRunID = excludedRunID
        self.replacementUserMessageID = replacementUserMessageID
        self.carryAnchor = carryAnchor; self.admittedPriorSessionID = admittedPriorSessionID
    }

    package static func beforeQuestion(_ messages: [ChatMessage], id: String?) -> [ChatMessage] {
        guard let id, let index = messages.firstIndex(where: { $0.extras?.objectValue?["id"] == .string(id) }) else {
            return messages
        }
        return Array(messages[..<index])
    }

    package func project(_ rows: [JSONValue], sessionId: String, dataRoot: URL,
                         windowTokens: Int) async throws -> SessionHistoryMessages.Result {
        guard historyLimit > 0 else { return .empty }
        let selected = SessionHistoryReader(dataRoot: dataRoot).promptMessagesWithStats(
            transcript: try SessionContextRequest.transcript(rows), excludingRunId: excludedRunID).prompt
        let prior = Self.beforeQuestion(try selected.checkedMessages(), id: replacementUserMessageID)
        var carried = prior
        if carryAnchor, try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) {
            carried = try CarriedAnchorRecollection.seeded(prior, sessionId: sessionId, dataRoot: dataRoot,
                admittedPriorSessionId: admittedPriorSessionID)
        }
        return try SessionHistoryMessages.project(messages: carried, historyLimit: historyLimit,
            windowTokens: windowTokens)
    }
}

package enum SessionRequestMessages {
    package struct Seed: Sendable {
        package let messages: [LLMMessage]
        package let sent: SentTurnContext
        package let currentUserIndex: Int
    }
    /// Both live request assembly and saved-plan sizing use these exact blocks.
    package static func seed(history: [LLMMessage], replayed: [SentTurnContext], fullBlock: String,
        model: String, provider: String?, window: String, userText: String, images: [LLMContentBlock]) -> Seed {
        let sent = SentTurnContext.delivery(full: fullBlock, replayed: replayed,
            model: model, provider: provider, window: window, userText: userText)
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

/// A payload-free recipe for sizing the next replay from an admitted request.
/// Its changing words/context stay with their existing user-row owner.
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
                       windowTokens: Int) async throws -> SessionContextRequest {
        guard systemAndToolsCharacters >= 0, additionalCharacters >= 0, !currentRunID.isEmpty,
              let row = rows.last(where: {
                  guard let fields = $0.objectValue else { return false }
                  return SentTurnContext.matches(fields, runID: currentRunID, userMessageID: currentUserMessageID)
              })?.objectValue,
              let sent = SentTurnContext(metadata: row["metadata"]?.objectValue),
              sent.model == model, sent.provider == provider,
              let full = sent.fullBlock, sent.userText != nil else {
            throw ProviderRoutingError.configurationFailed("The admitted request's exact user context is unavailable. Repair its saved user-row delivery before compacting this conversation.")
        }
        // A saved plan sizes the next replay, not the request that produced
        // its receipt. That turn's answer and tool receipts now belong to
        // history, including after Regenerate. Its user words already replay
        // from their row; only the context state may need a new keyframe.
        let nextReplay = SessionReplaySpec(historyLimit: replay.historyLimit,
            excludedRunID: nil, replacementUserMessageID: nil,
            carryAnchor: replay.carryAnchor, admittedPriorSessionID: replay.admittedPriorSessionID)
        let history = try await nextReplay.project(rows, sessionId: sessionId, dataRoot: dataRoot, windowTokens: windowTokens)
        let request = SessionRequestMessages.seed(history: history.messages, replayed: history.replayedContexts,
            fullBlock: full, model: model, provider: provider, window: history.contextWindow, userText: "", images: [])
        let (fixedCharacters, overflow) = systemAndToolsCharacters.addingReportingOverflow(additionalCharacters)
        guard !overflow else { throw ProviderRoutingError.configurationFailed("The admitted request size is not representable.") }
        return try SessionContextRequest(messages: request.messages, systemAndToolsCharacters: fixedCharacters,
            historyCharacters: history.characters, rowCharacters: history.rowCharacters)
    }
}
