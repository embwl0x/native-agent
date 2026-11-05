import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import AgentWorkspace
// Blueprint: | `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`,`chatStream`,`chatStreamExecution`,`ChatStreamExecution` |

/// Join the producer before declaring settlement: terminal events can precede its cancellation/failure transcript write.
public struct ChatStreamExecution: Sendable {
    public let events: AsyncThrowingStream<TurnStreamEvent, Error>
    private let producer: Task<Result<ChatResponse, any Error>, Never>

    init(
        events: AsyncThrowingStream<TurnStreamEvent, Error>,
        producer: Task<Result<ChatResponse, any Error>, Never>
    ) {
        self.events = events
        self.producer = producer
    }

    public func cancel() { producer.cancel() }
    @discardableResult
    public func waitForProducerTermination() async -> Result<ChatResponse, any Error> { await producer.value }
}

extension SwiftNativeChatOrchestrationClient {
    // MARK: chatStream

    /// The producer captures the accepted turn and its exact transcript choices.
    public nonisolated func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String? = nil,
        surface: String = "chat",
        suppressUserAppend: Bool,
        replacementAssistantMessageID: String? = nil,
        /// The producer holds the helper's saved provider choice.
        choice: ProviderTurnChoice? = nil,
        /// Bind the immutable return route inside the producer for its full lifetime.
        replyRoute: ChatToolSessionContext.ReplyRoute? = nil,
        /// Bind the service tier inside the producer for its full lifetime.
        serviceTier: String? = nil,
        /// Stream consumption alone does not prove card rendering, so the default stays text-only.
        consumerRendersInlineCards: Bool = false,
        turn: Turn
    ) -> AsyncThrowingStream<TurnStreamEvent, Error> {
        chatStreamExecution(
            message: message,
            sessionId: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess,
            attachments: attachments,
            persona: persona,
            surface: surface,
            suppressUserAppend: suppressUserAppend,
            replacementAssistantMessageID: replacementAssistantMessageID,
            choice: choice,
            replyRoute: replyRoute,
            serviceTier: serviceTier,
            consumerRendersInlineCards: consumerRendersInlineCards, turn: turn
        ).events
    }

    /// Lifecycle owners join producer persistence before claiming terminal truth; stream-only consumers retain ordinary cancellation.
    public nonisolated func chatStreamExecution(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        replacementAssistantMessageID: String? = nil,
        /// Pass the route as a parameter so the producer holds the value for its full lifetime.
        choice: ProviderTurnChoice? = nil,
        /// Pass the reply route as a parameter so the producer holds the value for its full lifetime.
        replyRoute: ChatToolSessionContext.ReplyRoute? = nil,
        /// Pass the service tier as a parameter so the producer holds the value for its full lifetime.
        serviceTier: String? = nil,
        /// Only the mounted transcript UI declares inline-card rendering; every other consumer defaults to text-only.
        consumerRendersInlineCards: Bool = false,
        /// Capture the user's takeover location at ingress; carry it on the captured turn.
        macContinuation: MacWorkContinuation? = nil,
        /// Save under the surface's existing reply-row identity; carry it on the captured turn.
        replyRowID: String? = nil,
        onScreenPreview: (@Sendable (MacScreenPreviewUpdate) async -> Void)? = nil,
        turn: Turn
    ) -> ChatStreamExecution {
        let request = TurnRequest(message: message, sessionID: sessionId, model: model,
            reasoningEffort: reasoningEffort, fileAccess: fileAccess, attachments: attachments,
            persona: persona, surface: surface, suppressUserAppend: suppressUserAppend)
        var held = turn
        held.rows.replacementAssistantMessageID = replacementAssistantMessageID
        held.replyStreamRendersCards = consumerRendersInlineCards
        if let replyRoute { held.envelope = held.envelope?.withDeliveryRoute(replyRoute) }
        if let macContinuation {
            held.macContinuation = macContinuation
            held.envelope = held.envelope?.withMacContinuation(macContinuation)
        }
        if let choice { held.providerChoice = choice }
        if let serviceTier { held.requestedServiceTier = serviceTier }
        if let onScreenPreview { held.screenPreview = onScreenPreview }
        // Omission clears a parent's mounted row; this stream owns only the row its caller supplied.
        held.replyRow = replyRowID.flatMap { row in
            sessionId.map { TurnTraceContext.ReplyRow(turnId: held.id, sessionId: $0, messageId: row) }
        }
        let turn = held
        let (events, continuation) = AsyncThrowingStream<TurnStreamEvent, Error>.makeStream()
        // Consumer termination detaches; the producer holds the accepted turn until settlement.
        let producer = Task { [self, turn] in
            if surface == "chat", let sessionId, !sessionId.isEmpty {
                await TurnFirstRenderRegistry.shared.register(turnId: turn.id, sessionId: sessionId, surface: surface)
            }
            return await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(turn.id) {
                    await TurnTraceContext.$destinationId.withValue(turn.replyRoute?.destinationId) {
                        await TurnTraceContext.$threadId.withValue(turn.replyRoute?.threadId) {
                            await self.runStream(request: request, continuation: continuation, turn: turn)
                        }
                    }
                }
            }
        }
        return ChatStreamExecution(events: events, producer: producer)
    }

    private func runStream(
        request: TurnRequest,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation,
        turn: Turn
    ) async -> Result<ChatResponse, any Error> {
        let trimmed = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && request.attachments.isEmpty {
            continuation.yield(.error("empty_message"))
            continuation.finish()
            return .failure(ChatOrchestrationError.emptyMessage)
        }
        let execution: StructuredChatExecution
        let runID = turn.run
        // Resolve mounted session delivery through its owner, including on resumed turns.
        let lease = request.sessionID.map {
            SessionTurnDelivery.mount(dataRoot: dataRoot, sessionID: $0, runID: runID,
                recipient: .init(progress: { event in continuation.yield(event) }))
        }
        defer {
            if let session = request.sessionID, let lease {
                SessionTurnDelivery.unmount(dataRoot: dataRoot, sessionID: session, runID: runID, lease: lease)
            }
        }
        do {
            execution = try await chatExecution(
                message: request.message,
                sessionId: request.sessionID,
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                fileAccess: request.fileAccess,
                attachments: request.attachments,
                persona: request.persona,
                surface: request.surface,
                suppressUserAppend: request.suppressUserAppend,
                progress: nil, turn: turn)
        } catch {
            continuation.finish(throwing: ProviderFailure.report(error) ?? error)
            return .failure(error)
        }
        do {
            let turn = try execution.turn.get()
            continuation.yield(.final(turn))
        } catch let e as ChatOrchestrationError {
            switch e {
            case .emptyMessage:
                continuation.yield(.error("empty_message"))
            default:
                continuation.yield(.error((e as LocalizedError).errorDescription ?? String(describing: e)))
            }
        } catch {
            continuation.finish(throwing: ProviderFailure.report(error) ?? error)
            return .success(execution.response)
        }
        continuation.finish()
        return .success(execution.response)
    }
}
