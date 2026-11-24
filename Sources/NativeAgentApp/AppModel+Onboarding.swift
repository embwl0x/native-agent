import Foundation
import SwiftUI
import BodyRuntime
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import MindCore
import WidgetKit
import AppIntents
import Observation
import ProviderRouting
import SenseCore
import DeskCore
// Blueprint: | `AppModel+Onboarding.swift` | `AppModel`: first-run greeting port and onboarding commands |

@MainActor
extension AppModel: FirstRunWelcomePort {
    var firstRunDataRoot: URL { engine.dataRoot }
    var firstRunIsPublicRelease: Bool { InstallPaths.isPublicReleaseBundle }
    var firstRunSessionIsBusy: Bool { engine.turns.runtime.busySessions.contains(activeChatSessionId) }
    var firstRunSyntheticErrorIDPrefix: String { Self.syntheticErrorIDPrefix }

    func firstRunMessages(for sessionID: String) -> [ChatMessage] {
        engine.transcripts.displayedTranscript(for: sessionID).messages
    }
    func firstRunLoadMessages(for sessionID: String) async throws {
        _ = try await engine.transcripts.loadMessages(sessionId: sessionID, cached: true)
        _ = try engine.transcripts.completeDisplayedMessages(for: sessionID)
    }

    func markFirstRunWelcomePending() {
        firstRunWelcomeTransaction.markFirstRunWelcomePending(port: self)
    }

    @discardableResult
    func maybeSendFirstRunGreeting() async -> FirstRunGreetingOutcome {
        let outcome = await firstRunWelcomeTransaction.maybeSendFirstRunGreeting(port: self)
        // Later provider/session triggers ignore the returned outcome, so rejected preparation must also remain visible in state.
        if case .rejected = outcome, let message = outcome.routeFailureMessage {
            statusText = message
        }
        // Only a completed greeting permits the macOS login-item banner, regardless of which trigger started it.
        if case .delivered = outcome { AppDelegate.registerLoginItemInBackground() }
        return outcome
    }

    /// Match persona-write receipts against the engine-owned section title.
    var firstConversationReceiptTitle: String? {
        engine.transcripts.firstConversationReceiptTitle
    }

    /// Read the exact section title from persona documents so the write matches the person's own name.
    var firstConversationPersonName: String {
        get throws { try engine.transcripts.firstConversationPersonName }
    }

    /// Require a fresh successful provider read; stale ready rows cannot authorize a first-run turn after refresh failure.
    func firstRunGreetingHasReadyProvider() async -> Bool {
        let providersFresh = await loadProvidersForChat()
        return providersFresh && engine.providers.hasReadyConnection
    }

    /// First-run claims do not bypass ordinary chat admission.
    func sendFirstRunGreeting(
        _ kickoff: String,
        sessionID: String
    ) async -> MacChatTurnAcceptance {
        return await sendChat(kickoff, sessionId: sessionID, hideUserBubble: true, requireIdleAndEmpty: true)
    }

}
