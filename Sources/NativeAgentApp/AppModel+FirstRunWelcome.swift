import ChatOrchestration
import Cognition
import Foundation
import NativeAgentShared
import PersistenceCore
import PersonaEngine

@MainActor
extension AppModel: FirstRunWelcomePort {
    var firstRunDataRoot: URL { dataRootOverride ?? NativeAgentPaths.dataRoot }
    var firstRunIsPublicRelease: Bool { NativeAgentPaths.isPublicReleaseBundle }
    var firstRunSessionIsBusy: Bool { engine.turns.busySessions.contains(activeChatSessionId) }
    var firstRunGreetingSendIsOverridden: Bool { firstRunGreetingSendOverride != nil }
    var firstRunSyntheticErrorIDPrefix: String { Self.syntheticErrorIDPrefix }

    func firstRunMessages(for sessionID: String) -> [ChatMessage] {
        engine.transcripts.messages(for: sessionID)
    }

    func markFirstRunWelcomePending() {
        firstRunWelcomeTransaction.markFirstRunWelcomePending(port: self)
    }

    @discardableResult
    func maybeSendFirstRunGreeting() async -> FirstRunGreetingOutcome {
        await firstRunWelcomeTransaction.maybeSendFirstRunGreeting(port: self)
    }

    static func hasConversationRows(_ messages: [ChatMessage]) -> Bool {
        FirstRunWelcomeTransaction.hasConversationRows(messages, syntheticErrorIDPrefix: syntheticErrorIDPrefix)
    }

    /// The exact section title the first conversation's write used, or nil when
    /// this persona has no first conversation on record.
    ///
    /// The settled receipt is restricted to writes matching this (Sol P2-10),
    /// so it is read here rather than in a view body: once it answers, it is
    /// answered for the process.
    var firstConversationReceiptTitle: String? {
        if let cached = firstConversationReceiptTitleCache { return cached }
        let title = FirstConversationPersonaExemption.recordedWriteTitle(
            dataRoot: dataRootOverride ?? NativeAgentPaths.dataRoot
        )
        firstConversationReceiptTitleCache = title
        return title
    }

    /// The person's own name, as the persona documents know it — the only
    /// source for the exact section title the write must use.
    var firstConversationPersonName: String {
        NativeCognitionRuntime.resolveUserName(
            dataRoot: dataRootOverride ?? NativeAgentPaths.dataRoot
        )
    }

    /// Production requires a fresh successful provider read. An old cached
    /// ready row is not authority to create a first-run turn after a failed
    /// refresh.
    func firstRunGreetingHasReadyProvider() async -> Bool {
        if let firstRunGreetingProviderReadyOverride {
            return await firstRunGreetingProviderReadyOverride()
        }
        let providersFresh = await loadProvidersForChat()
        return providersFresh && engine.providers.connections.contains(where: { $0.auth_status.state == "ready" })
    }

    /// The injected handoff remains behind every real first-run gate and claim;
    /// production always reaches the normal `sendChat` turn owner.
    func sendFirstRunGreeting(
        _ kickoff: String,
        sessionID: String
    ) async -> ChatTurnAcceptance {
        if let firstRunGreetingSendOverride {
            return await firstRunGreetingSendOverride(kickoff, sessionID, true)
        }
        return await sendChat(kickoff, sessionId: sessionID, hideUserBubble: true, requireIdleAndEmpty: true)
    }

}
