import Foundation
import ToolRegistry
import Privacy
import NativeAgentCore
import TurnTrace
import MacControl

public enum MacChatStreamAdapter {
    // S.5: the stream's terminal receipt, read by the surface after the stream
    // is exhausted. Every field is lock-guarded, which is what makes the
    // @unchecked Sendable wrapper safe.
    public final class MetaBox: @unchecked Sendable {
        public init() {}
        private final class ProducerCompletion: @unchecked Sendable {
            private let lock = NSLock()
            private var resolved = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func resolve() {
                lock.lock()
                guard !resolved else {
                    lock.unlock()
                    return
                }
                resolved = true
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

            var isResolved: Bool {
                lock.lock()
                defer { lock.unlock() }
                return resolved
            }
        }

        public enum StreamTerminalEvidence: Sendable, Equatable {
            case finalResponse
            case explicitFailure(String)
            /// Only a TYPED cancellation observed at this adapter's own
            /// boundary may claim this. Provider text can never reach it.
            case cancellationAcknowledged
            /// The stream reported a terminal whose meaning cannot be decided
            /// from its untyped text alone — for example a provider failure
            /// whose entire message happens to read "cancelled". The canonical
            /// receipt decides; absent one, the turn stays outcome-unknown.
            case ambiguousTermination
        }

        private let lock = NSLock()
        private let producerCompletion = ProducerCompletion()
        private var _final: (reply: String, sessionId: String?)?
        private var _terminalEvidence: StreamTerminalEvidence?
        /// The core's final result: its reply, and the session the turn ran on.
        public func recordFinalResponse(reply: String, sessionId: String?) {
            lock.lock()
            _final = (reply, sessionId)
            _terminalEvidence = .finalResponse
            lock.unlock()
        }
        public func finalResponse() -> (reply: String, sessionId: String?)? {
            lock.lock()
            defer { lock.unlock() }
            return _final
        }
        /// Typed cancellation seen by this adapter itself. This is the ONLY
        /// producer of `.cancellationAcknowledged`; it is never inferred from
        /// stream text.
        public func recordCancellationAcknowledged() {
            lock.lock()
            _terminalEvidence = .cancellationAcknowledged
            lock.unlock()
        }
        public func recordExplicitStreamError(_ raw: String) {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let evidence: StreamTerminalEvidence
            if normalized == "cancelled"
                || normalized == "canceled"
                || normalized == "cancellationerror()" {
                // The core emits this marker on cancellation, but a provider
                // failure whose whole message is "cancelled" is byte-identical.
                // Untyped text cannot distinguish them, so refuse to assert a
                // cancel here and let canonical transcript evidence decide.
                evidence = .ambiguousTermination
            } else {
                let safe = TurnPresentationReducer.sanitized(
                    raw,
                    additionalRedactor: { NativeAppSecretRedactor.redactText($0) }
                ) ?? "Turn failed"
                evidence = .explicitFailure(safe)
            }
            lock.lock()
            _terminalEvidence = evidence
            lock.unlock()
        }
        public func terminalEvidence() -> StreamTerminalEvidence? {
            lock.lock()
            defer { lock.unlock() }
            return _terminalEvidence
        }
        public func recordProducerFinished() { producerCompletion.resolve() }
        public func waitForProducerTermination() async { await producerCompletion.wait() }
        public var producerHasFinished: Bool { producerCompletion.isResolved }
    }

    // Slow-network advisory (2026-06-14): the chatStream watchdog and the
    // delta-consumer share this flag across two Tasks; it MUST be lock-guarded
    // (not a bare captured var) to satisfy Swift 6 data-race checking.
    public final class FirstTokenFlag: @unchecked Sendable {
        public init() {}
        private let lock = NSLock()
        private var v = false
        public func mark() { lock.lock(); v = true; lock.unlock() }
        public func seen() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    // Advisory toast delay for a slow-but-alive connection: if no token has
    // arrived within 10s, tell the user the network looks slow. Purely
    // advisory — it NEVER cancels the stream, so a slow-but-alive reply (e.g. an
    // extended-thinking model still reasoning) still renders when it lands. We
    // deliberately do NOT add a tight pre-first-token *cancel* clock: this layer
    // only sees content chunks, not SSE keep-alive pings, so it can't tell a
    // dead socket from a thinking model — any cancel fast enough to be useful
    // would clip legitimate high-reasoning replies. The hard bounds stay
    // URLSession's transport timeout + ProviderStreamGuard's 90s idle clock.
    public static let slowNetworkAdvisoryDelayNanos: UInt64 = 10_000_000_000

    // PATCH-2026-05-06: hotpath-4 streaming chat — yields delta strings via AsyncThrowingStream, done event carries metadata
    // PATCH-2026-05-06: multimodal-ui Sprint 3 — added attachments param
    // S.5: onMetadata replaced by lock-guarded MetaBox; caller reads metadata after stream exhaustion.
    // Wave 16 (2026-06-01): same gate as chat() above — see comment block at chat().
    public static func stream(
        sessionId: String?,
        metaBox: MetaBox,
        activityIdentity: MacChatTurnIdentity,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void,
        onScreenPreview: (@Sendable (MacScreenPreviewUpdate) async -> Void)? = nil,
        makeExecution: @escaping @Sendable () -> ChatStreamExecution
    ) -> AsyncThrowingStream<MacChatStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            // Surface cancellation propagates into the concrete core producer,
            // but this adapter does not resolve its completion receipt until
            // that producer has finished its canonical partial/terminal write.
            let producer = Task {
                defer { metaBox.recordProducerFinished() }
                await TurnTraceContext.$turnId.withValue(activityIdentity.turnId) {
                // The live computer pane's channel, bound for the WHOLE life of
                // this producer with the ASYNC withValue overload, exactly as
                // the turn trace id above is, and for the same reason
                // (MEMORY-SAFETY 2026-07-04, ChatOrchestration+Streaming.swift:339):
                // a synchronous withValue wrapping only the execution's
                // construction pops the task-local the instant it returns, while
                // the tool dispatch that reads it runs later in this task — so
                // the sink would be gone by the time a Mac verb looked for it,
                // and the child would tear down freed task-local storage.
                // Unbound when the surface passed no sink, which is what makes
                // the four-verb path decode and mask nothing for a headless or
                // remote turn.
                await MacScreenPreviewBus.$publish.withValue(onScreenPreview) {
                let swiftExecution = makeExecution()
                // Slow-turn advisory (2026-06-14): if no token arrives within
                // ~10s, post a non-cancelling "still working" notice on the live
                // turn-notice bus. This NEVER interrupts the stream — a slow-but-
                // alive reply (incl. an extended-thinking model reasoning for a
                // while before its first token, or a long tool loop) still
                // renders when it lands. Cancelled on first delta and on every
                // stream exit so it can't fire after a fast reply or leak a
                // timer. Wording is deliberately neutral: at 10s this layer
                // can't tell a slow network from deep reasoning, so it must not
                // falsely blame the network.
                let firstToken = FirstTokenFlag()
                let slowWatch = Task {
                    try? await Task.sleep(nanoseconds: Self.slowNetworkAdvisoryDelayNanos)
                    guard !Task.isCancelled, !firstToken.seen() else { return }
                    await onTurnActivity(
                        MacChatTurnActivityBoundary.notice(
                            kind: "slow_turn",
                            text: "Still working on it - a complex reply can take a moment.",
                            identity: activityIdentity,
                            at: Date()
                        )
                    )
                }
                // Belt-and-suspenders: guarantee the advisory timer is cancelled
                // when the producer unwinds for ANY reason — including outer
                // stream cancellation (Stop) observed mid-await — so it can never
                // post after the turn ends. The explicit cancels below stop it
                // promptly on the first delta; this is the catch-all.
                defer { slowWatch.cancel() }
                await withTaskCancellationHandler {
                    await Self.bridgeChatStreamEvents(
                        swiftExecution.events,
                        sessionId: sessionId,
                        activityIdentity: activityIdentity,
                        metaBox: metaBox,
                        firstToken: firstToken,
                        cancelSlowWatch: { slowWatch.cancel() },
                        onTurnActivity: onTurnActivity,
                        continuation: continuation
                    )
                    await swiftExecution.waitForProducerTermination()
                } onCancel: {
                    swiftExecution.cancel()
                }
                }
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { producer.cancel() }
            }
        }
    }

    /// Adapts the typed core stream while preserving its persistence ordering.
    /// A terminal error closes the surface stream immediately, then this loop
    /// continues draining to core EOF before its caller resolves producer
    /// completion. The seam is internal so tests can gate EOF deterministically.
    public static func bridgeChatStreamEvents(
        _ swiftStream: AsyncThrowingStream<TurnStreamEvent, Error>,
        sessionId: String?,
        activityIdentity: MacChatTurnIdentity,
        metaBox: MetaBox,
        firstToken: FirstTokenFlag,
        cancelSlowWatch: @escaping @Sendable () -> Void,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void,
        continuation: AsyncThrowingStream<MacChatStreamUpdate, Error>.Continuation
    ) async {
        var terminalError: NSError?
        let shown = ShownToolNames()
        do {
            for try await event in swiftStream {
                try Task.checkCancellation()
                if terminalError != nil {
                    // The surface has already closed, but core may still be
                    // committing its partial/cancellation receipt.
                    continue
                }
                switch event {
                case .delta(let text):
                    // Empty liveness deltas must not suppress the existing slow
                    // advisory; only user-visible text is a first token.
                    if !text.isEmpty {
                        firstToken.mark()
                        cancelSlowWatch()
                    }
                    continuation.yield(.text(text))
                case .replyTextSettled(let settled):
                    continuation.yield(.replyTextSettled(settled))
                case .toolUse, .toolResult, .notice:
                    if let activity = MacChatTurnActivityBoundary.activity(
                        from: event,
                        identity: activityIdentity,
                        shown: shown,
                        at: Date()
                    ) {
                        await onTurnActivity(activity)
                    }
                case .final(let result):
                    metaBox.recordFinalResponse(
                        reply: result.reply,
                        sessionId: sessionId.flatMap { $0.isEmpty ? nil : $0 }
                    )
                case .error(let message):
                    cancelSlowWatch()
                    metaBox.recordExplicitStreamError(message)
                    let error = NSError(
                        domain: "NativeAgentStream",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                    terminalError = error
                    continuation.finish(throwing: error)
                }
            }
            try Task.checkCancellation()
            cancelSlowWatch()
            if terminalError == nil { continuation.finish() }
        } catch {
            cancelSlowWatch()
            if Task.isCancelled || error is CancellationError {
                // Typed, observed at this adapter's own boundary — not parsed
                // from provider text.
                metaBox.recordCancellationAcknowledged()
            }
            continuation.finish(throwing: error)
        }
    }

}

extension MacChatStreamAdapter.MetaBox {
    public func observedTerminalSignal() -> MacChatTurnObservedTerminalSignal {
        switch terminalEvidence() {
        case .finalResponse:
            return .finalResponse
        case .explicitFailure(let reason):
            return .explicitFailure(reason)
        case .cancellationAcknowledged:
            return .cancellationAcknowledged
        case .ambiguousTermination:
            return .ambiguousTermination
        case nil:
            return .none
        }
    }

}
