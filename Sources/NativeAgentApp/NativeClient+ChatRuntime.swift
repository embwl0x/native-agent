import Privacy
import Foundation
import NativeAgentShared
import PersistenceCore
import TurnTrace
import NativeAgentCore
import ChatOrchestration
import ProviderRouting

enum ChatTurnNoticeDestination: Equatable {
    case chatTop
    case globalWarning
    case globalInfo
}

enum ChatTurnNoticePresentation {
    static func destination(for kind: String) -> ChatTurnNoticeDestination {
        // 2026-09-22 WHY: reconnect notices live in the turn's own lane, which
        // clears when the turn ends, so a long-held one never outlives the retry.
        if kind == "provider_retry" {
            return .chatTop
        }
        if kind.contains("timeout") {
            return .globalWarning
        }
        return .globalInfo
    }
}

/// The two Mac chat entry points share their provider-facing tier setting.
/// Core resolves the installation's persona for every door.
struct NativeChatTurnOptions: Sendable, Equatable {
    let serviceTier: String?

    static func resolve(
        fastModeEnabled: Bool,
        surface: String
    ) -> NativeChatTurnOptions {
        return NativeChatTurnOptions(
            serviceTier: surface == "chat" && fastModeEnabled ? "priority" : nil
        )
    }

    /// The picker displays the same normalized value Core compiles.
    static func normalizedPickerPersona(_ raw: String?, fallback: String = "AI") -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func current(surface: String, defaults: UserDefaults = .standard) -> NativeChatTurnOptions {
        resolve(
            fastModeEnabled: defaults.bool(forKey: "chatFastMode"),
            surface: surface
        )
    }
}

extension NativeClient {
    func chat(message: String, sessionId: String?, model: String, reasoningEffort: String, fileAccess: String, attachments: [MultimodalAttachment] = [], suppressUserAppend: Bool = false, surface: String = "chat", replacementAssistantMessageId: String? = nil) async throws -> ChatOrchestration.ChatResponse {
        let swiftClient = Self.residentMacChatClient
        let options = NativeChatTurnOptions.current(surface: surface)
        return try await TurnRequest(
            message: message,
            sessionID: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess,
            attachments: Self.adaptAttachments(attachments),
            persona: nil,
            surface: surface,
            suppressUserAppend: suppressUserAppend,
            replacementAssistantMessageID: replacementAssistantMessageId,
            serviceTier: options.serviceTier
        ).chat(on: swiftClient)
    }

    // Wave 33 (2026-06-01): RETIRED the dead `captureScreen(prompt:analyze:returnBase64:)`
    // daemon-proxy method that posted to /v1/multimodal/capture_screen. It had ZERO callers
    // repo-wide (mac/ios/scripts/tests) — the Mac UI screen-capture button at
    // ContentView.swift:2151 calls the NATIVE `NativeScreenCapture.captureImageBase64()`
    // (ScreenCaptureKit / SCScreenshotManager), and a regression assertion in
    // tests/test_nextgen_consolidation.py explicitly forbids the daemon path. The wave-30 W14
    // audit (CUTOVER §6 entry #9) wrongly described this method as "UI-wired"; the UI never
    // used it.

    typealias MetaBox = MacChatStreamAdapter.MetaBox

    func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment] = [],
        metaBox: MetaBox,
        suppressUserAppend: Bool = false,
        // A bot's own session continued in Chat runs on surface "bot" so it keeps
        // the bot approval rule instead of silently becoming an ordinary chat
        // turn (lane1 finding 4). Everything else stays "chat".
        surface: String = "chat",
        /// The bot's saved provider tuple when this session belongs to a bot.
        /// Bound turn-locally, so routing admits the bot's own provider/model/
        /// effort instead of the Chat surface preference.
        choice: ProviderTurnChoice? = nil,
        activityIdentity: MacChatTurnIdentity,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void,
        /// Sink for the chat's live computer pane while the agent drives the
        /// Mac. Separate from `onTurnActivity` on purpose: that boundary is
        /// deliberately incapable of carrying a payload, and this one carries a
        /// picture. Left nil by a surface with no card to show it on, and the
        /// four-verb path then produces nothing at all.
        onScreenPreview: (@Sendable (MacScreenPreviewUpdate) async -> Void)? = nil,
        /// Does the surface consuming this stream DRAW inline cards? True only
        /// for a mounted Mac chat transcript. Everything else — the bridge,
        /// iCloud forwarding, a headless driver — gets the card said in prose,
        /// because a withheld card copy reaches them as silence.
        consumerRendersInlineCards: Bool = false
    ) -> AsyncThrowingStream<MacChatStreamUpdate, Error> {
        MacChatStreamAdapter.stream(
            sessionId: sessionId,
            metaBox: metaBox,
            activityIdentity: activityIdentity,
            onTurnActivity: onTurnActivity,
            onScreenPreview: onScreenPreview
        ) {
            let swiftClient = Self.residentMacChatClient
            let options = NativeChatTurnOptions.current(surface: surface)
            // The bot tuple AND the service tier travel as parameters so
            // the facade binds them inside its own producer task for that
            // producer's whole life; a synchronous binding here pops the
            // moment the execution is constructed, before the producer
            // reads it (swift_task_dealloc_specific).
            return swiftClient.chatStreamExecution(
                message: message,
                sessionId: sessionId,
                model: model,
                reasoningEffort: reasoningEffort,
                fileAccess: fileAccess,
                attachments: Self.adaptAttachments(attachments),
                persona: nil,
                surface: surface,
                suppressUserAppend: suppressUserAppend,
                choice: choice,
                serviceTier: options.serviceTier,
                consumerRendersInlineCards: consumerRendersInlineCards
            )
        }
    }
}
