import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

/// Joinable ownership for one core streaming producer. Surface adapters that
/// cancel a consumer must wait for this execution before treating the turn as
/// settled: the producer owns cancellation/failure transcript persistence and
/// can emit its terminal event before that write has completed.
public struct ChatStreamExecution: @unchecked Sendable {
    public let events: AsyncThrowingStream<TurnStreamEvent, Error>
    private let control: ChatStreamProducerControl

    fileprivate init(
        events: AsyncThrowingStream<TurnStreamEvent, Error>,
        control: ChatStreamProducerControl
    ) {
        self.events = events
        self.control = control
    }

    public func cancel() { control.cancel() }
    public func waitForProducerTermination() async { await control.wait() }
}

/// Lock-backed instead of actor-backed so cancellation can synchronously reach
/// the producer from `AsyncStream.Continuation.onTermination`.
final class ChatStreamProducerControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false
    private var resolved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if !resolved { self.task = task }
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func resolve() {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        task = nil
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !resolved else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

extension SwiftNativeChatOrchestrationClient {
    // MARK: chatStream
    //
    // The narrower legacy shapes (no persona; persona but no surface) are
    // served by upward-forwarding defaults on the `ChatOrchestrationClient`
    // protocol (see +Types.swift) — they add only default arguments, so no
    // concrete override lives here. This surface-bearing overload is the sole
    // protocol requirement's concrete witness; it defaults
    // `replacementAssistantMessageID` and forwards to the request-scoped
    // overload below where the real streaming turn is built.

    public nonisolated func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool
    ) -> AsyncThrowingStream<TurnStreamEvent, Error> {
        chatStream(
            message: message,
            sessionId: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess,
            attachments: attachments,
            persona: persona,
            surface: surface,
            suppressUserAppend: suppressUserAppend,
            replacementAssistantMessageID: nil
        )
    }

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
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        replacementAssistantMessageID: String?,
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
        /// producer below is an unstructured Task, so a synchronous
        /// `ProviderTurnChoice.$current.withValue { chatStream(…) }` popped the
        /// task-local the instant it returned while the producer still read it
        /// — the same swift_task_dealloc_specific shape the turn-trace comment
        /// below describes. Bound inside the producer instead.
        choice: ProviderTurnChoice? = nil,
        /// The turn's immutable return route. A PARAMETER for the same reason
        /// as `choice`: a synchronous
        /// `ChatToolSessionContext.$replyRoute.withValue { chatStream(…) }`
        /// popped the task-local the instant it returned, while the producer
        /// Task it had just spawned still read it
        /// (swift_task_dealloc_specific). Bound inside the producer below.
        replyRoute: ChatToolSessionContext.ReplyRoute? = nil,
        /// The turn's provider service tier, same parameter-not-wrapper rule.
        serviceTier: String? = nil,
        /// Does the thing CONSUMING this stream draw inline cards?
        ///
        /// Declared by the mounted UI that renders the transcript — and by
        /// nothing else. Consuming a stream used to be taken as proof of it,
        /// which made every stream consumer a card renderer: iCloud/iOS
        /// forwarding, ChatDrive.runStream, the Claude bridge, Telegram and
        /// Slack all read a stream and all draw nothing, so a turn parked on a
        /// card withheld its prose and reached them as silence (Agent's bridge
        /// session, 2026-09-13: "stream ended without final reply").
        ///
        /// False by default, so a new consumer is text-only until it says
        /// otherwise — the safe direction, because the cost of being wrong here
        /// is a card said twice, not a reply that never arrives.
        consumerRendersInlineCards: Bool = false
    ) -> ChatStreamExecution {
        // Turn Inspector W1: bind the per-turn trace id ONCE around the whole
        // streaming turn. runStream branches to the text-compat loop OR the
        // structured tool loop; both (and the streamTurn / engine calls nested
        // under them) inherit this id so the entire turn is one story.
        //
        // MEMORY-SAFETY (2026-07-04): the binding is done INSIDE the Task with
        // the ASYNC withValue overload — NOT a synchronous withValue wrapping
        // the Task creation. The old shape `withValue(turnId) { Task { … } }`
        // pushed the task-local on THIS (parent) task and popped it the instant
        // the sync withValue returned, while the spawned child task had already
        // inherited a reference into that same task-local storage. The child
        // then tore down freed storage → swift_task_dealloc_specific fatalError
        // (crash on first chat, G4-5; the VM's timing exposed a latent race
        // that can bite real hardware). Binding inside the Task keeps push/pop
        // LIFO on the child's own stack. Same fix pattern as StructuredChat.
        let turnId = TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
        let control = ChatStreamProducerControl()
        let events = AsyncThrowingStream<TurnStreamEvent, Error> { continuation in
            let task = Task { [self] in
                defer { control.resolve() }
                if surface == "chat", let sessionId, !sessionId.isEmpty {
                    await TurnFirstRenderRegistry.shared.register(
                        turnId: turnId,
                        sessionId: sessionId,
                        surface: surface
                    )
                }
                await ChatPersistenceContext.$replacementAssistantMessageID
                    .withValue(replacementAssistantMessageID) {
                        await TurnTraceContext.$bus.withValue(turnTraceBus) {
                        await TurnTraceContext.$turnId.withValue(turnId) {
                            func run() async {
                                await self.runStream(
                                    message: message,
                                    sessionId: sessionId,
                                    model: model,
                                    reasoningEffort: reasoningEffort,
                                    fileAccess: fileAccess,
                                    attachments: attachments,
                                    persona: persona,
                                    surface: surface,
                                    suppressUserAppend: suppressUserAppend,
                                    continuation: continuation
                                )
                            }
                            // Each binding is installed inside the producer,
                            // for the producer's whole life, and left UNBOUND
                            // when this turn carries no value — so an ordinary
                            // turn still resolves its own route/tier.
                            func runWithChoice() async {
                                if let choice {
                                    await ProviderTurnChoice.$current.withValue(choice) { await run() }
                                } else {
                                    await run()
                                }
                            }
                            func runWithTier() async {
                                if let serviceTier {
                                    await LLMCallContext.$serviceTier.withValue(serviceTier) { await runWithChoice() }
                                } else {
                                    await runWithChoice()
                                }
                            }
                            // A chat view consuming this stream is the only kind
                            // of consumer that can draw an inline card, and it
                            // is the CONSUMER that says so (see the parameter).
                            // A turn parked on a card does not restate the card
                            // in prose there — the card itself is the reply.
                            // Everywhere else the card's copy is spoken.
                            func runAsRenderedStream() async {
                                await ChatToolSessionContext
                                    .$replyStreamRendersCards
                                    .withValue(consumerRendersInlineCards) {
                                        await runWithTier()
                                    }
                            }
                            // A turn that parks on a card needs somewhere to
                            // RECORD that it did. Without this the tool loop's
                            // `waitForInteraction` wrote to nil, the waiting
                            // terminal below it was unreachable, and the turn
                            // ended with no final at all — the card was raised
                            // and the reply never came (2026-09-13). Only the
                            // bot entry used to bind one; every lane needs it.
                            // A nested call keeps the outer turn's execution.
                            func runWithExecution() async {
                                // Peer provenance is entered INDEPENDENTLY of
                                // the execution — see PeerDataTaint. A caller
                                // that bound an execution first used to skip
                                // the taint box entirely, and a turn with no
                                // box cannot latch a peer's words at all.
                                // `withScope` is a no-op when one is bound.
                                await PeerDataTaint.withScope {
                                    if ChatTurnExecution.current != nil {
                                        await runAsRenderedStream()
                                    } else {
                                        await ChatTurnExecution.$current
                                            .withValue(ChatTurnExecution()) {
                                                await runAsRenderedStream()
                                            }
                                    }
                                }
                            }
                            if let replyRoute {
                                // The trace rows of this turn carry the same
                                // delivery identity the route does, so a later
                                // knock can be returned to THIS conversation
                                // instead of falling back to the phone for
                                // want of a destination (2026-09-13).
                                await ChatToolSessionContext.withReplyRoute(replyRoute) {
                                    await runWithExecution()
                                }
                            } else {
                                await runWithExecution()
                            }
                        }
                        }
                }
            }
            control.install(task)
            continuation.onTermination = { termination in
                if case .cancelled = termination { control.cancel() }
            }
        }
        return ChatStreamExecution(events: events, control: control)
    }

    private func runStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            continuation.yield(.error("empty_message"))
            continuation.finish()
            return
        }
        let admission: TurnRouteAdmission
        do {
            admission = try await engine.checkedRouteAdmission(
                for: surface,
                requestedModel: model,
                requestedReasoningEffort: reasoningEffort
            )
        } catch {
            continuation.finish(throwing: ProviderFailure.report(error) ?? error)
            return
        }
        await LLMCallContext.$admittedModel.withValue(admission.modelId) {
        await LLMCallContext.$providerId.withValue(admission.providerId) {
        await LLMCallContext.$reasoningEffort.withValue(admission.reasoningEffort) {
        await LLMCallContext.$serviceTier.withValue(admission.serviceTier) {
            await runAdmittedStream(
                message: message,
                sessionId: sessionId,
                model: admission.modelId,
                reasoningEffort: admission.reasoningEffort,
                fileAccess: fileAccess,
                attachments: attachments,
                persona: persona,
                surface: surface,
                suppressUserAppend: suppressUserAppend,
                continuation: continuation
            )
        }
        }
        }
        }
    }

    private func runAdmittedStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async {
        let useTextCompatibility: Bool
        do {
            useTextCompatibility = try await shouldUseAnthropicTextStreamingCompatibility(
                model: model,
                surface: surface
            )
        } catch {
            continuation.finish(throwing: ProviderFailure.report(error) ?? error)
            return
        }
        // v2Prefix (2026-09-01): resolve the conversation-prefix shape ONCE per
        // turn and bind it for the whole turn — same discipline as the pinned
        // turn clock. A shape that could change between the context build and
        // the message seeding, or between two tool-loop iterations, would emit
        // a half-v1/half-v2 request; binding it here makes that unreachable.
        let prefixShape = ConversationPrefixShape.effective
        // Bound EMPTY here; the lane fills it once the seeded prefix exists, so
        // every `llm.call` row this turn emits carries the same receipts.
        let prefixTelemetrySink = ConversationPrefixTelemetrySink()
        await ConversationPrefixTelemetry.$sink.withValue(prefixTelemetrySink) {
        await ConversationPrefixShape.$override.withValue(prefixShape) {
        if useTextCompatibility {
            guard let streamingLLM = self.streamingLLM else {
                continuation.yield(.error("no streaming LLM client wired"))
                continuation.finish()
                return
            }
            await runTextStreamingCompatibility(
                message: message,
                sessionId: sessionId,
                model: model,
                reasoningEffort: reasoningEffort,
                fileAccess: fileAccess,
                attachments: attachments,
                persona: persona,
                surface: surface,
                suppressUserAppend: suppressUserAppend,
                streamingLLM: streamingLLM,
                emitTextDeltas: true,
                continuation: continuation
            )
            return
        }
        do {
            // App/iOS streaming must use the same structured tool loop as
            // chat()/Telegram while still yielding provider text deltas.
            // OpenAI OAuth emits structured SSE tool-call events; providers
            // without that support fall back through completeMessages.
            let execution = try await executeStructuredChatStreaming(
                message: message,
                sessionId: sessionId,
                model: model,
                reasoningEffort: reasoningEffort,
                fileAccess: fileAccess,
                attachments: attachments,
                persona: persona,
                surface: surface,
                suppressUserAppend: suppressUserAppend,
                persistToolMessages: true,
                progress: { event in
                    continuation.yield(event)
                },
                noticeSink: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
            )
            // A card-lane sentence the model never wrote reaches the terminal
            // result only; a consumer that rebuilds the reply from deltas has
            // to see it as one.
            if let suffix = ChatTurnExecution.takeStreamSuffix(), !suffix.isEmpty {
                continuation.yield(.delta(suffix))
            }
            continuation.yield(.final(execution.turn))
        } catch let e as ChatOrchestrationError {
            switch e {
            case .emptyMessage:
                continuation.yield(.error("empty_message"))
            default:
                continuation.yield(.error((e as LocalizedError).errorDescription ?? String(describing: e)))
            }
        } catch {
            continuation.finish(throwing: ProviderFailure.report(error) ?? error)
            return
        }
        continuation.finish()
        } // ConversationPrefixShape.$override.withValue
        } // ConversationPrefixTelemetry.$sink.withValue
    }
}
