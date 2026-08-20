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
        replacementAssistantMessageID: String?
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
            replacementAssistantMessageID: replacementAssistantMessageID
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
        replacementAssistantMessageID: String? = nil
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
            continuation.yield(.error("provider routing unavailable"))
            continuation.finish()
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
            continuation.yield(.error("provider routing unavailable"))
            continuation.finish()
            return
        }
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
                }
            )
            continuation.yield(.final(execution.turn))
        } catch let e as ChatOrchestrationError {
            switch e {
            case .emptyMessage:
                continuation.yield(.error("empty_message"))
            default:
                continuation.yield(.error((e as LocalizedError).errorDescription ?? String(describing: e)))
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            continuation.yield(.error(message))
        }
        continuation.finish()
    }
}
