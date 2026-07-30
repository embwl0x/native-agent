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
import CapabilityFoundry

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
        private let lock = NSLock()
        private var _value: [String: Any] = [:]
        func set(_ meta: [String: Any]) { lock.lock(); _value = meta; lock.unlock() }
        func get() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return _value }
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
        suppressUserAppend: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Fix 7: keep a handle to the producer Task so cancellation propagates to the URLSession bytes stream
            let producer = Task {
                let swiftClient = Self.residentMacChatClient
                let persona = UserDefaults.standard.string(forKey: "chatPersona").flatMap { (s: String) -> String? in
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
                let requestedTier = UserDefaults.standard.bool(forKey: "chatFastMode")
                    ? "priority" : nil
                let swiftStream = LLMCallContext.$serviceTier.withValue(requestedTier) {
                    swiftClient.chatStream(
                        message: message,
                        sessionId: sessionId,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        fileAccess: fileAccess,
                        attachments: Self.adaptAttachments(attachments),
                        persona: persona,
                        suppressUserAppend: suppressUserAppend
                    )
                }
                var accumulatedSwift = ""
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
                    NotificationCenter.default.post(
                        name: .nativeAgentTurnNotice,
                        object: nil,
                        userInfo: [
                            "kind": "slow_turn",
                            "text": "Still working on it - a complex reply can take a moment.",
                            // Session-scope so a background/detached turn's advisory
                            // doesn't toast over the active conversation (audit #7/#9).
                            "sessionId": sessionId ?? "",
                        ]
                    )
                }
                // Belt-and-suspenders: guarantee the advisory timer is cancelled
                // when the producer unwinds for ANY reason — including outer
                // stream cancellation (Stop) observed mid-await — so it can never
                // post after the turn ends. The explicit cancels below stop it
                // promptly on the first delta; this is the catch-all.
                defer { slowWatch.cancel() }
                do {
                    for try await event in swiftStream {
                        try Task.checkCancellation()
                        switch event {
                        case .delta(let s):
                            // Only a non-empty (user-visible) delta counts as the
                            // first token / cancels the slow-turn advisory. Empty
                            // liveness deltas (audit #4: emitted during thinking /
                            // tool-arg accumulation to keep ProviderStreamGuard's
                            // idle clock alive) must NOT cancel the advisory, or a
                            // long pure-thinking phase would show nothing at all.
                            if !s.isEmpty {
                                firstToken.mark()
                                slowWatch.cancel()
                            }
                            accumulatedSwift += s
                            continuation.yield(s)
                        case .toolUse, .toolResult:
                            // Keep the slow-turn advisory ALIVE during tool runs:
                            // this wrapper swallows tool events (no live pill in the
                            // main chat list), so a long tool call has no other
                            // "still working" signal — cancelling here would hide it
                            // (gpt-5.5 review of audit #7, 2026-06-14).
                            continue
                        case .notice(let kind, let text):
                            // Notify-don't-hang (2026-06-09): ephemeral in-turn
                            // status (invoke_claude start/heartbeat/timeout).
                            // Not reply text — surface via the app-wide toast
                            // bar (ChatView observes this notification).
                            NotificationCenter.default.post(
                                name: .nativeAgentTurnNotice,
                                object: nil,
                                userInfo: ["kind": kind, "text": text, "sessionId": sessionId ?? ""]
                            )
                            continue
                        case .final(let result):
                            var meta: [String: Any] = [
                                "output": result.reply,
                                "model": result.modelUsed,
                            ]
                            if let sid = sessionId, !sid.isEmpty { meta["sessionId"] = sid }
                            metaBox.set(meta)
                        case .error(let m):
                            slowWatch.cancel()
                            continuation.finish(throwing: NSError(domain: "NativeAgentStream", code: -1, userInfo: [NSLocalizedDescriptionKey: m]))
                            return
                        }
                    }
                    slowWatch.cancel()
                    continuation.finish()
                } catch {
                    slowWatch.cancel()
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the stream (e.g. stop button) cancels the producer which in turn
            // causes the URLSession bytes task to be cancelled on next checkCancellation().
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

}
