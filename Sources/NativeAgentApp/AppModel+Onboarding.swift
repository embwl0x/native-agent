import Foundation
import SwiftUI
import EngineRuntime
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ChatSessionWork
import ChatTurnRuntime
import Onboarding
import AttentionRouting
import DoctorChecks
import WidgetKit
import AppIntents
import Observation
import MemoryV2
import ProviderRouting
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import TelegramBot
import DeviceSync
// Blueprint: | `AppModel+Onboarding.swift` | `AppModel`: first-run greeting port and onboarding commands |

@MainActor
extension AppModel: FirstRunWelcomePort {
    var firstRunDataRoot: URL { engine.dataRoot }
    var firstRunIsPublicRelease: Bool { InstallPaths.isPublicReleaseBundle }
    var firstRunSessionIsBusy: Bool { engine.turns.busySessions.contains(activeChatSessionId) }
    var firstRunSyntheticErrorIDPrefix: String { Self.syntheticErrorIDPrefix }

    func firstRunMessages(for sessionID: String) -> [ChatMessage] {
        engine.transcripts.messages(for: sessionID)
    }

    func markFirstRunWelcomePending() {
        firstRunWelcomeTransaction.markFirstRunWelcomePending(port: self)
    }

    @discardableResult
    func maybeSendFirstRunGreeting() async -> FirstRunGreetingOutcome {
        let outcome = await firstRunWelcomeTransaction.maybeSendFirstRunGreeting(port: self)
        // `.delivered` means the greeting turn has finished, whichever trigger
        // started it — only now may macOS post its "Login Item Added" banner.
        if case .delivered = outcome { AppDelegate.registerLoginItemInBackground() }
        return outcome
    }

    /// Engine-owned first-conversation section title used to match persona-write receipts.
    var firstConversationReceiptTitle: String? {
        engine.transcripts.firstConversationReceiptTitle
    }

    /// The person's own name, as the persona documents know it — the only
    /// source for the exact section title the write must use.
    var firstConversationPersonName: String {
        engine.transcripts.firstConversationPersonName
    }

    /// Production requires a fresh successful provider read. An old cached
    /// ready row is not authority to create a first-run turn after a failed
    /// refresh.
    func firstRunGreetingHasReadyProvider() async -> Bool {
        let providersFresh = await loadProvidersForChat()
        return providersFresh && engine.providers.hasReadyConnection
    }

    /// The greeting uses ordinary chat admission after the first-run claim.
    func sendFirstRunGreeting(
        _ kickoff: String,
        sessionID: String
    ) async -> ChatTurnAcceptance {
        return await sendChat(kickoff, sessionId: sessionID, hideUserBubble: true, requireIdleAndEmpty: true)
    }

}

extension AppModel {
    // MARK: Onboarding
    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResult {
        try await engine.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: agentName, personaType: personaType, userName: userName),
            resident: .live
        )
    }

    func resumePendingOnboarding() async throws -> OnboardingCompleteResult {
        try await engine.resumePendingOnboarding(resident: .live)
    }

    func repairOnboardingProfile(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResult {
        try await engine.repairOnboardingProfile(
            payload: OnboardingCompletePayload(agentName: agentName, personaType: personaType, userName: userName),
            publishProfile: { await self.reloadPersonality() }, resident: .live
        )
    }

    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResult {
        try await engine.resetOnboarding(confirm: confirm, resident: .live)
    }

    func refreshResidentMindAfterOnboardingTransition() async {
        await NativeAgentEngine.live.refreshResidentMindAfterOnboardingTransition()
    }
}
