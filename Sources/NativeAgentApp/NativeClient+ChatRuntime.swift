import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

enum ChatTurnNoticeDestination: Equatable {
    case chatTop
    case globalWarning
    case globalInfo
}

enum ChatTurnNoticePresentation {
    static func destination(for kind: String) -> ChatTurnNoticeDestination {
        if kind == "slow_turn" {
            return .chatTop
        }
        if kind.contains("timeout") {
            return .globalWarning
        }
        return .globalInfo
    }
}

extension NativeClient {
    func chat(message: String, sessionId: String?, model: String, reasoningEffort: String, fileAccess: String, attachments: [MultimodalAttachment] = [], suppressUserAppend: Bool = false, surface: String = "chat", replacementAssistantMessageId: String? = nil) async throws -> ChatResponse {
        let swiftClient = Self.residentMacChatClient
        let persona = UserDefaults.standard.string(forKey: "chatPersona").flatMap { (s: String) -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let requestedTier = surface == "chat" && UserDefaults.standard.bool(forKey: "chatFastMode")
            ? "priority" : nil
        let coResp = try await ChatPersistenceContext.$replacementAssistantMessageID
            .withValue(replacementAssistantMessageId) {
                try await LLMCallContext.$serviceTier.withValue(requestedTier) {
                    try await swiftClient.chat(
                        message: message,
                        sessionId: sessionId,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        fileAccess: fileAccess,
                        attachments: Self.adaptAttachments(attachments),
                        persona: persona,
                        surface: surface,
                        suppressUserAppend: suppressUserAppend
                    )
                }
        }
        return adaptChatResponse(coResp)
    }

    // Wave 33 (2026-06-01): RETIRED the dead `captureScreen(prompt:analyze:returnBase64:)`
    // daemon-proxy method that posted to /v1/multimodal/capture_screen. It had ZERO callers
    // repo-wide (mac/ios/scripts/tests) — the Mac UI screen-capture button at
    // ContentView.swift:2151 calls the NATIVE `NativeScreenCapture.captureImageBase64()`
    // (ScreenCaptureKit / SCScreenshotManager), and a regression assertion in
    // tests/test_nextgen_consolidation.py explicitly forbids the daemon path. The wave-30 W14
    // audit (CUTOVER §6 entry #9) wrongly described this method as "UI-wired"; the UI never
    // used it. See CUTOVER_PLAN.md §6.96 for the full audit + the daemon-route retirement_path.

    // S.5: actor-based metadata holder — all access is async-safe.
    // [String: Any] contains only property-list-compatible values from JSON, which are
    // effectively value-typed; marking the wrapper @unchecked Sendable is safe here.
    final class MetaBox: @unchecked Sendable {
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

        enum StreamTerminalEvidence: Sendable, Equatable {
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
        private var _value: [String: Any] = [:]
        private var _terminalEvidence: StreamTerminalEvidence?
        func set(_ meta: [String: Any]) { lock.lock(); _value = meta; lock.unlock() }
        func get() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return _value }
        func recordFinalResponse() {
            lock.lock()
            _terminalEvidence = .finalResponse
            lock.unlock()
        }
        /// Typed cancellation seen by this adapter itself. This is the ONLY
        /// producer of `.cancellationAcknowledged`; it is never inferred from
        /// stream text.
        func recordCancellationAcknowledged() {
            lock.lock()
            _terminalEvidence = .cancellationAcknowledged
            lock.unlock()
        }
        func recordExplicitStreamError(_ raw: String) {
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
        func terminalEvidence() -> StreamTerminalEvidence? {
            lock.lock()
            defer { lock.unlock() }
            return _terminalEvidence
        }
        func recordProducerFinished() { producerCompletion.resolve() }
        func waitForProducerTermination() async { await producerCompletion.wait() }
        var producerHasFinished: Bool { producerCompletion.isResolved }
    }

    // Slow-network advisory (2026-06-14): the chatStream watchdog and the
    // delta-consumer share this flag across two Tasks; it MUST be lock-guarded
    // (not a bare captured var) to satisfy Swift 6 data-race checking.
    final class FirstTokenFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func mark() { lock.lock(); v = true; lock.unlock() }
        func seen() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
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
    static let slowNetworkAdvisoryDelayNanos: UInt64 = 10_000_000_000

    // PATCH-2026-05-06: hotpath-4 streaming chat — yields delta strings via AsyncThrowingStream, done event carries metadata
    // PATCH-2026-05-06: multimodal-ui Sprint 3 — added attachments param
    // S.5: onMetadata replaced by lock-guarded MetaBox; caller reads metadata after stream exhaustion.
    // Wave 16 (2026-06-01): same gate as chat() above — see comment block at chat().
    func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment] = [],
        metaBox: MetaBox,
        suppressUserAppend: Bool = false,
        activityIdentity: MacChatTurnIdentity,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Surface cancellation propagates into the concrete core producer,
            // but this adapter does not resolve its completion receipt until
            // that producer has finished its canonical partial/terminal write.
            let producer = Task {
                defer { metaBox.recordProducerFinished() }
                await TurnTraceContext.$turnId.withValue(activityIdentity.turnId) {
                let swiftClient = Self.residentMacChatClient
                let persona = UserDefaults.standard.string(forKey: "chatPersona").flatMap { (s: String) -> String? in
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
                let requestedTier = UserDefaults.standard.bool(forKey: "chatFastMode")
                    ? "priority" : nil
                let swiftExecution = LLMCallContext.$serviceTier.withValue(requestedTier) {
                    swiftClient.chatStreamExecution(
                        message: message,
                        sessionId: sessionId,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        fileAccess: fileAccess,
                        attachments: Self.adaptAttachments(attachments),
                        persona: persona,
                        surface: "chat",
                        suppressUserAppend: suppressUserAppend
                    )
                }
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
            continuation.onTermination = { termination in
                if case .cancelled = termination { producer.cancel() }
            }
        }
    }

    /// Adapts the typed core stream while preserving its persistence ordering.
    /// A terminal error closes the surface stream immediately, then this loop
    /// continues draining to core EOF before its caller resolves producer
    /// completion. The seam is internal so tests can gate EOF deterministically.
    static func bridgeChatStreamEvents(
        _ swiftStream: AsyncThrowingStream<TurnStreamEvent, Error>,
        sessionId: String?,
        activityIdentity: MacChatTurnIdentity,
        metaBox: MetaBox,
        firstToken: FirstTokenFlag,
        cancelSlowWatch: @escaping @Sendable () -> Void,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var terminalError: NSError?
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
                    continuation.yield(text)
                case .toolUse, .toolResult, .notice:
                    if let activity = MacChatTurnActivityBoundary.activity(
                        from: event,
                        identity: activityIdentity,
                        at: Date()
                    ) {
                        await onTurnActivity(activity)
                    }
                case .final(let result):
                    var meta: [String: Any] = [
                        "output": result.reply,
                        "model": result.modelUsed,
                    ]
                    if let sessionId, !sessionId.isEmpty { meta["sessionId"] = sessionId }
                    metaBox.set(meta)
                    metaBox.recordFinalResponse()
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
