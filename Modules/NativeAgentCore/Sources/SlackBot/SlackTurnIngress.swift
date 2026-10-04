import Foundation
import ChatOrchestration
import PersistenceCore
import PersonaEngine

extension SlackSocketModeLoop {
    /// The Slack surface, built only when Socket Mode is configured and
    /// enabled. The host supplies the engine's Slack-profiled chat client
    /// (built only past the config check) and a transcript-completion signal
    /// that fires once each turn settles or throws, and the bot-event intake.
    public static func ifConfigured(
        dataRoot: URL,
        chatClient makeChatClient: () -> any ChatOrchestrationClient,
        turnCompleted: @escaping @Sendable (_ sessionID: String) -> Void,
        botEventIntake: @escaping SlackBotEventIntake
    ) -> SlackSocketModeLoop? {
        guard let cfg = SlackSocketModeConfig.load(dataRoot: dataRoot), cfg.enabled else {
            return nil
        }
        let slackSessions = SlackSessionStore(dataRoot: dataRoot)
        let client = makeChatClient()
        let handler: SlackSocketModeProgressChatHandler = { inbound, progress in
            let sessionId = try await slackSessions.activeSessionId(for: inbound)
            let prompt = """
            [from: slack, user: \(inbound.userId), channel: \(inbound.channelId)]
            \(inbound.text)
            """
            let replyRoute = ChatToolSessionContext.ReplyRoute(
                surface: "slack",
                destinationId: inbound.channelId,
                threadId: inbound.replyThreadTs
            )
            // 2026-07-21 audit fix: the forged commandSignatureVerified=true
            // binding is REMOVED. Socket mode carries no request signature;
            // slack origin trust now comes from the explicit slack allowlist
            // in SecurityCenter.assessOrigin (mirroring telegram).
            let request = TurnRequest(
                message: prompt,
                sessionID: sessionId,
                // The chat facade admits the complete checked tuple once;
                // surface shells provide no stale partial pick.
                attachments: inbound.attachments,
                persona: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                surface: "slack",
                verifiedChatID: inbound.channelId,
                verifiedUserID: inbound.userId,
                replyRoute: replyRoute
            )
            let response: ChatResponse
            do {
                defer { turnCompleted(sessionId) }
                // 2026-09-06: Slack supplied no progress callback at all, so
                // reconnect and compaction notices died here. Only notices are
                // forwarded — tool events would be channel noise; the sink
                // posts one line per kind.
                response = try await TurnAdmission.shared.run(sessionID: sessionId) {
                    try await request.chat(on: client, progress: { event in
                        if case .notice(let kind, let text) = event {
                            await progress(kind, text)
                        }
                    })
                }
            }
            return SlackSocketModeReply(
                text: response.output,
                attachments: response.attachments ?? []
            )
        }
        return SlackSocketModeLoop(
            config: cfg,
            dataRoot: dataRoot,
            botEventIntake: botEventIntake,
            progressChatHandler: handler
        )
    }
}
