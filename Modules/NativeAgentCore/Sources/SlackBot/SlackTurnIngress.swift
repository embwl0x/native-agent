import Foundation
import MacControl
import ChatTurnRuntime
import ChatTurnContracts
import PersistenceCore
import NativeAgentCore

// Blueprint: | `SlackTurnIngress.swift` | Configured Slack ingress shares persona selection, profiled chat and allowlist authority |

extension SlackSocketModeLoop {
    public static func offReason(dataRoot: URL) throws -> String {
        try SlackSocketModeConfig.socketModeSwitchedOff(dataRoot: dataRoot)
            ? "Socket Mode off" : "Slack not connected (no bot and app token)"
    }

    /// Build the Slack-profiled client only after configuration admits Socket Mode. Transcript completion must signal once on both settled and throwing turns.
    public static func ifConfigured(
        dataRoot: URL,
        chatClient makeChatClient: @escaping @Sendable () -> SwiftNativeChatOrchestrationClient,
        turnCompleted: @escaping @Sendable (_ sessionID: String) -> Void,
        botEventIntake: @escaping SlackBotEventIntake
    ) throws -> SlackSocketModeLoop? {
        guard let cfg = try SlackSocketModeConfig.load(dataRoot: dataRoot), cfg.enabled else {
            return nil
        }
        let handler: SlackProgressChat = { inbound, sessionId, handler in
            let client = makeChatClient()
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
                // The chat facade admits the complete checked tuple once; surface shells provide no stale partial pick.
                attachments: inbound.attachments,
                surface: "slack",
                envelope: TurnEnvelope(surface: "slack", verifiedChatId: inbound.channelId,
                    verifiedUserId: inbound.userId, commandSignatureVerified: nil, deliveryRoute: replyRoute,
                    macContinuation: takeover),
                verifiedSessionID: sessionId,
                verifiedChatID: inbound.channelId,
                verifiedUserID: inbound.userId,
                replyRoute: replyRoute,
                queryUserMessage: inbound.text
            )
            let turn = request.turn(id: handler.turn.id, parent: handler.turn).with(\.macContinuation, takeover)
            let admitted: TurnAdmission.Admitted<ChatResponse>
            do {
                defer { turnCompleted(sessionId) }
                // The surface owns delivery of prose and notices; tool events stay local.
                admitted = try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: sessionId, arrival: request.arrival(.shown),
                    turn: turn) { turn in
                    try await client.chat(message: request.message, sessionId: sessionId,
                        model: request.model, reasoningEffort: request.reasoningEffort, fileAccess: request.fileAccess,
                        attachments: request.attachments, persona: request.persona, surface: "slack",
                        suppressUserAppend: request.suppressUserAppend, turn: turn, serviceTier: request.serviceTier ?? nil)
                }
            }
            switch admitted {
            case .ran(let response): return SlackSocketModeReply(text: response.output, attachments: response.attachments ?? [])
            case .steered(let steered): return SlackSocketModeReply(text: "", readBy: steered.turnID)
            }
        }
        return SlackSocketModeLoop(
            config: cfg,
            dataRoot: dataRoot,
            botEventIntake: botEventIntake,
            progressChatHandler: handler
        )
    }
}
