import Foundation
import PersistenceCore
// Blueprint: | `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |

// Event waking for bots (0.4.12). One listener, no loop of its own: the Slack
// entry point is called by the socket-mode runner on a message it already
// accepted. It hands the event to BotEventRouter, which matches triggers and
// admits runs through the ordinary run queue under the master Autonomy switch.
public enum BotEventIntake {
    static func router(dataRoot: URL, isAutonomyEnabled: @escaping @Sendable () async -> Bool) -> BotEventRouter {
        BotEventRouter(dataRoot: dataRoot, isAutonomyEnabled: isAutonomyEnabled)
    }

    /// Called by the Slack socket-mode runner for each message it accepted, so
    /// only channels the runner already receives can wake a bot.
    public static func slackMessage(
        channelId: String,
        text: String,
        userId: String,
        dataRoot: URL,
        isAutonomyEnabled: @escaping @Sendable () async -> Bool
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let summary = "Slack message in \(channelId): " + String(trimmed.prefix(200))
        let event = BotIncomingEvent(
            source: .slack,
            target: channelId,
            summary: summary,
            detail: "From \(userId) in \(channelId):\n" + trimmed,
            verifiedUserID: userId
        )
        _ = await router(dataRoot: dataRoot, isAutonomyEnabled: isAutonomyEnabled).deliver(event)
    }
}
