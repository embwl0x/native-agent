import Foundation
import PersistenceCore
import SenseCore
// Blueprint: | `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |

// Reuse accepted socket-mode messages; admission still passes the shared Autonomy gate.
public enum BotEventIntake {
    static func router(dataRoot: URL, isAutonomyEnabled: @escaping @Sendable () async -> Bool) -> BotEventRouter {
        BotEventRouter(dataRoot: dataRoot, isAutonomyEnabled: isAutonomyEnabled)
    }

    /// Only channels the socket-mode runner already receives can wake a bot.
    public static func slackMessage(
        channelId: String,
        text: String,
        userId: String,
        eventId: String,
        dataRoot: URL,
        isAutonomyEnabled: @escaping @Sendable () async -> Bool
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let event = BotIncomingEvent(id: eventId, source: .slack, target: channelId, text: trimmed, verifiedUserID: userId)
        _ = try await router(dataRoot: dataRoot, isAutonomyEnabled: isAutonomyEnabled).deliver(event, scope: BotRunScope())
    }
}
