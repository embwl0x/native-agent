import Foundation
import ProviderRouting
import NativeAgentShared
import MacControl
import StandingBots
import PersistenceCore
import TurnTrace
import Transcripts
import AgentWorkspace
import ToolRegistry
// Blueprint: | `MacChatTurnStreamSettlement.swift` | Mac stream completion, joined persistence and lifecycle settlement; helper conversations enter their own runner with the existing Mac admission |

public protocol MacChatRenderedMessage: MacChatRetryMessage {
    var sessionId: String? { get }
    var macChatHasMetadata: Bool { get }
    var macChatPartial: Bool { get }
    var macChatCancelled: Bool { get }
}

public struct MacChatStreamCompletion: Sendable {
    public let text: String
    /// Where `text`'s working commentary ends, when the core's final reply is
    /// the text and it said so.
    public var workingCommentaryCharacters: Int? = nil
}

public struct MacChatStreamSettlement: Sendable {
    public let proof: MacChatTurnTranscriptTerminalProof
    public let state: MacChatTurnLifecycleState?

    public var hasCanonicalReceipt: Bool {
        proof != .absent && proof != .unavailable
    }

    public var hasAssistantReceipt: Bool {
        hasCanonicalReceipt && proof != .canceled
    }
}

public extension MacChatTurnPresentationPort {
    /// Join producer settlement before presenting its result.
    func completeMacChatStream(
        execution: ChatStreamExecution,
        sessionId: String,
        generation: Int,
        streamedText: String
    ) async throws -> MacChatStreamCompletion? {
        // AsyncThrowingStream cancellation may end iteration cleanly.
        try Task.checkCancellation()
        let result = await execution.waitForProducerTermination()
        guard macChatTurns.taskGenerations[sessionId] == generation else { return nil }
        let final = try? result.get()
        let reply = final.flatMap { $0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.output }
        return MacChatStreamCompletion(
            text: reply ?? streamedText,
            workingCommentaryCharacters: reply == nil ? nil : final?.workingCommentaryCharacters
        )
    }

    /// A cancelled consumer still joins persistence. This deliberately does
    /// not throw on cancellation and never advances a replacement generation.
    func joinFailedMacChatStream(
        execution: ChatStreamExecution,
        sessionId: String,
        generation: Int
    ) async -> Bool {
        _ = await execution.waitForProducerTermination()
        return macChatTurns.taskGenerations[sessionId] == generation
    }

    func settleMacChatStream(
        identity: MacChatTurnIdentity,
        result: Result<ChatResponse, any Error>?
    ) async -> MacChatStreamSettlement {
        let proof: MacChatTurnTranscriptTerminalProof
        let kind: MacChatTurnLifecycleInput.Kind
        if case .success(let response)? = result {
            switch response.terminalState {
            case .completed: proof = .completed; kind = .completed
            case .stopped, .failed:
                proof = response.output.isEmpty && response.attachments?.isEmpty != false
                    && (response.terminalState == .stopped || SessionConversation.isHelper(identity.sessionId, dataRoot: macChatTurns.dataRoot))
                    ? .absent : (response.terminalState == .stopped ? .canceled : .failed)
                kind = response.terminalState == .stopped ? .cancellationConfirmed : .failed(reason: response.statusDetail)
            case .waiting, .interrupted, nil:
                proof = .incomplete
                kind = .outcomeUnknown(reason: response.statusDetail ?? "This reply was saved, but the turn did not finish.")
            }
        } else {
            // Restart and ambiguous persistence failures require exact disk evidence.
            proof = await readCanonicalChatTurnTerminalProof(identity: identity)
            switch proof {
            case .completed: kind = .completed
            case .incomplete: kind = .outcomeUnknown(reason: "This reply was saved, but the turn did not finish.")
            case .failed: kind = .failed(reason: nil)
            case .canceled: kind = .cancellationConfirmed
            case .absent:
                if case .failure(let error)? = result {
                    kind = error is CancellationError ? .cancellationConfirmed : .failed(reason: error.localizedDescription)
                } else {
                    kind = .outcomeUnknown(reason: "This turn's outcome could not be confirmed.")
                }
            case .unavailable: kind = .outcomeUnknown(reason: "This turn's outcome could not be confirmed.")
            }
        }
        let state = await settleChatTurnLifecycle(identity: identity, kind: kind, at: Date())
        return MacChatStreamSettlement(proof: proof, state: state)
    }

}

public extension MacChatTurnRuntime {
    nonisolated static let syntheticErrorIDPrefix = "na-synthetic-error-"

    nonisolated static func restoredUnpersistedChatRequest<Message: MacChatRenderedMessage>(
        originalUser: Message, predecessor: Message?, notice: Message,
        canonicalMessages: [Message], syntheticPrefix: String,
        markUnpersisted: (Message) -> Message
    ) -> [Message]? {
        guard let sessionID = originalUser.sessionId, !sessionID.isEmpty,
              notice.sessionId == sessionID, originalUser.role == "user",
              notice.id.hasPrefix(syntheticPrefix), notice.macChatHasMetadata else { return nil }
        let unpersistedNotice = markUnpersisted(notice)
        let local = [predecessor].compactMap { $0 } + [originalUser, unpersistedNotice]
        guard let snapshot = MacChatRetrySnapshot.capture(
            target: unpersistedNotice, messages: local, sessionId: sessionID, isSyntheticNotice: true
        ), snapshot.matchesCanonical(canonicalMessages) else { return nil }
        return canonicalMessages + [originalUser, unpersistedNotice]
    }

    nonisolated static func isCompletedAssistant<Message: MacChatRenderedMessage>(_ message: Message?) -> Bool {
        guard let message, message.role == "assistant" else { return false }
        return !message.macChatPartial && !message.macChatCancelled
    }

    nonisolated static func normalizeStreamErrorForChat(_ error: Error, advice: (Error) -> String) -> String {
        if let person = ProviderRecoveryPolicy.personMessage(error) { return person }
        let raw = error.localizedDescription
        let text = ChatStreamErrorText.normalize(raw)
        return text == "Chat error: \(raw)" ? advice(error) : text
    }
}

public extension ChatStreamExecution {
    static func macChatStream(
        client: SwiftNativeChatOrchestrationClient,
        text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, activityIdentity: MacChatTurnIdentity, replyRowId: String,
        hideUserBubble: Bool, serviceTier: @escaping @Sendable () -> String?,
        onScreenPreview: @escaping @Sendable (MacScreenPreviewUpdate) async -> Void,
        helperSession: @escaping @Sendable (TurnEventSink?) -> BotRunnerSession,
        dataRoot: URL
    ) -> ChatStreamExecution {
        let message = text.isEmpty ? "(see attachments)" : text
        if SessionConversation.isHelper(sessionId, dataRoot: dataRoot) {
            let (events, continuation) = AsyncThrowingStream<TurnStreamEvent, Error>.makeStream()
            let producer = Task<Result<ChatResponse, any Error>, Never> {
                do {
                    guard let helperID = BotDefinition.id(forSession: sessionId) else {
                        throw ChatOrchestrationError.underlying("invalid helper session id")
                    }
                    let bot = try BotDefinitionStore(dataRoot: dataRoot).get(helperID)
                    let session = helperSession { continuation.yield($0) }
                    let reply = try await TurnTraceContext.$turnId.withValue(activityIdentity.turnId) {
                        try await TurnTraceContext.$replyRow.withValue(.init(turnId: activityIdentity.turnId, messageId: replyRowId)) {
                        try await session(bot, message)
                        }
                    }
                    if reply.status == .failed || reply.status == .interrupted {
                        let error = NSError(domain: "NativeAgentStream", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: reply.detail ?? reply.status.rawValue])
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                    return .success(StandingBotContinuity.response(reply,
                        sessionID: sessionId, runID: activityIdentity.turnId))
                } catch {
                    continuation.finish(throwing: error)
                    return .failure(error)
                }
            }
            return ChatStreamExecution(events: events, producer: producer)
        }
        return TurnTraceContext.$turnId.withValue(activityIdentity.turnId) {
            // The producer owns the service-tier binding for its whole life.
            client.chatStreamExecution(
                message: message, sessionId: sessionId,
                model: "", reasoningEffort: "", fileAccess: "auto",
                attachments: attachments, persona: nil, surface: "chat",
                suppressUserAppend: hideUserBubble, choice: nil, serviceTier: serviceTier(),
                consumerRendersInlineCards: true, replyRowID: replyRowId, onScreenPreview: onScreenPreview
            )
        }
    }
}
