import Foundation
import MacControl
import ChatTurnRuntime
import ChatTurnContracts
import PersistenceCore
import PersonaEngine

// Blueprint: | `SlackTurnIngress.swift` | `SlackSocketModeLoop.ifConfigured`: configured Slack ingress, engine-profiled chat and settled-turn signal wiring without forged signature authority |

extension SlackSocketModeLoop {
    /// Why `ifConfigured` built nothing, said as the lane's Off reason: Socket
    /// Mode switched off in the saved Slack config, or Slack not connected.
    public static func offReason(dataRoot: URL) throws -> String {
        try SlackSocketModeConfig.socketModeSwitchedOff(dataRoot: dataRoot)
            ? "Socket Mode off" : "Slack not connected (no bot and app token)"
    }

    /// The Slack surface, built only when Socket Mode is configured and
    /// enabled. The host supplies the engine's Slack-profiled chat client
    /// (built only past the config check) and a transcript-completion signal
    /// that fires once each turn settles or throws, and the bot-event intake.
    public static func ifConfigured(
        dataRoot: URL,
        chatClient makeChatClient: () -> SwiftNativeChatOrchestrationClient,
        turnCompleted: @escaping @Sendable (_ sessionID: String) -> Void,
        botEventIntake: @escaping SlackBotEventIntake
    ) throws -> SlackSocketModeLoop? {
        guard let cfg = try SlackSocketModeConfig.load(dataRoot: dataRoot), cfg.enabled else {
            return nil
        }
        let client = makeChatClient()
        let handler: SlackProgressChat = { inbound, sessionId, progress in
            let takeover = await MacWorkContinuation.admit(inbound.text)
            let prompt = """
            [from: slack, user: \(inbound.userId), channel: \(inbound.channelId)]
            \(inbound.text)
            """
            let replyRoute = ChatToolSessionContext.ReplyRoute(
                surface: "slack",
                destinationId: inbound.channelId,
                threadId: inbound.replyThreadTs,
                requesterUserId: inbound.userId
            )
            // Socket mode has no request signature; SecurityCenter.assessOrigin checks the Slack allowlist.
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
                replyRoute: replyRoute,
                queryUserMessage: inbound.text
            )
            let response: ChatResponse
            do {
                defer { turnCompleted(sessionId) }
                // Forward only notices, one line per kind, to keep tool events out of the channel.
                response = try await MacWorkContinuation.$current.withValue(takeover) {
                try await TurnAdmission.shared.run(sessionID: sessionId) {
                    try await request.chat(on: client, progress: { event in
                        if case .notice(let kind, let text) = event {
                            await progress(kind, text)
                        }
                    })
                }
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
