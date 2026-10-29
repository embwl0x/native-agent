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
// Blueprint: | `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`: `chatStream`, `chatStreamExecution`; `ChatStreamExecution` joins or cancels its producer Task's settled result |

/// Joinable ownership for one core streaming producer. Surface adapters that
/// cancel a consumer must wait for this execution before treating the turn as
/// settled: the producer owns cancellation/failure transcript persistence and
/// can emit its terminal event before that write has completed.
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

    /// Concrete request-scoped overload used by signed remote regenerate. The
    /// replacement binding is installed inside the producer Task (the same
    /// memory-safe pattern as TurnTraceContext), never around Task creation.
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
        /// The bot's saved provider tuple when this turn belongs to a bot.
        /// Bound INSIDE the producer task (see chatStreamExecution), never
        /// around this call: a synchronous binding here would pop before the
        /// producer ran.
        choice: ProviderTurnChoice? = nil,
        /// The turn's immutable return route, when the calling surface owns
        /// one. Same reason as `choice`: bound INSIDE the producer task, never
        /// synchronously around this call.
        replyRoute: ChatToolSessionContext.ReplyRoute? = nil,
        /// The turn's provider service tier, when the calling surface resolves
        /// one. Bound inside the producer for the same reason.
        serviceTier: String? = nil,
        /// See `chatStreamExecution`. Defaults to false: consuming a stream is
        /// not by itself evidence that anything can DRAW a card.
        consumerRendersInlineCards: Bool = false
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
            consumerRendersInlineCards: consumerRendersInlineCards
        ).events
    }

    /// Concrete joinable form used by the Mac lifecycle owner. Existing
    /// `chatStream` callers retain their stream-only API and cancellation
    /// behavior; callers that own terminal truth can also join persistence.
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
        /// The turn's bound provider tuple (a bot's saved choice). Passed as a
        /// PARAMETER rather than bound by the caller around this call: the
        /// producer below owns its task-local bindings for its entire lifetime.
        choice: ProviderTurnChoice? = nil,
        /// The turn's immutable return route. A PARAMETER for the same reason
        /// as `choice`: bound inside the producer for its entire lifetime.
        replyRoute: ChatToolSessionContext.ReplyRoute? = nil,
        /// The turn's provider service tier, same parameter-not-wrapper rule.
        serviceTier: String? = nil,
        /// Only the mounted transcript UI declares inline-card rendering; every other consumer defaults to text-only.
        consumerRendersInlineCards: Bool = false,
        /// Where User was when his door received a "take over". Bound inside
        /// the producer, same parameter-not-wrapper rule.
        macContinuation: MacWorkContinuation? = nil,
        /// The row the surface is drawing this reply in: the answer is saved
        /// under it and lands in place. Same parameter-not-wrapper rule.
        replyRowID: String? = nil,
        onScreenPreview: (@Sendable (MacScreenPreviewUpdate) async -> Void)? = nil
    ) -> ChatStreamExecution {
        // Bind task locals inside the producer for its entire lifetime.
        let turnId = TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
        let (events, continuation) = AsyncThrowingStream<TurnStreamEvent, Error>.makeStream()
        // Consumer termination detaches; the producer runs until it ends or Stop is raised.
        let producer = Task { [self] in
            if surface == "chat", let sessionId, !sessionId.isEmpty {
                await TurnFirstRenderRegistry.shared.register(
                    turnId: turnId,
                    sessionId: sessionId,
                    surface: surface
                )
            }
            let request = TurnRequest(
                message: message, sessionID: sessionId, model: model,
                reasoningEffort: reasoningEffort, fileAccess: fileAccess,
                attachments: attachments, persona: persona, surface: surface,
                suppressUserAppend: suppressUserAppend, replyRoute: replyRoute,
                replacementAssistantMessageID: .some(replacementAssistantMessageID),
                serviceTier: serviceTier.map { .some($0) },
                threadKind: ChatPersistenceContext.threadKind,
                ownedSessionID: ChatPersistenceContext.ownedSessionID
            )
            return await request.bind {
                await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(turnId) {
                await TurnTraceContext.$replyRow.withValue(replyRowID.map {
                    TurnTraceContext.ReplyRow(turnId: turnId, messageId: $0)
                }) {
                await ProviderTurnChoice.$current.withValue(choice ?? ProviderTurnChoice.current) {
                await MacWorkContinuation.$current.withValue(macContinuation ?? MacWorkContinuation.current) {
                await ChatToolSessionContext.$replyStreamRendersCards.withValue(consumerRendersInlineCards) {
                await MacScreenPreviewBus.$publish.withValue(onScreenPreview ?? MacScreenPreviewBus.publish) {
                    await self.runStream(request: request, continuation: continuation)
                }
                }
                }
                }
                }
                }
                }
            }
        }
        return ChatStreamExecution(events: events, producer: producer)
    }

    private func runStream(
        request: TurnRequest,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async -> Result<ChatResponse, any Error> {
        let trimmed = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && request.attachments.isEmpty {
            continuation.yield(.error("empty_message"))
            continuation.finish()
            return .failure(ChatOrchestrationError.emptyMessage)
        }
        let execution: StructuredChatExecution
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
                progress: { event in continuation.yield(event) }
            )
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
