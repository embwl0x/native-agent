import Foundation
import PersistenceCore
// Blueprint: | `TelegramNotificationDelivery.swift` | `TelegramPollLoop.notificationOutcome`: accept only complete chunked sends |

extension TelegramPollLoop {
    public static func notificationOutcome(_ token: String, _ destination: TelegramDestination,
                                           _ text: String) async -> NotificationDeliveryOutcome {
        guard !token.isEmpty, !text.isEmpty else {
            return .notDelivered(reason: "Telegram notification needs credentials and a nonempty message")
        }
        do {
            for part in try _tgChunkMessage(text, limit: 4000) {
                guard !Task.isCancelled else { return .notDelivered(reason: "cancelled before part dispatch") }
                _ = try await defaultSendMessageWithReplyMarkupReturningId(token, destination, part, .object([:]))
            }
            // The occurrence is accepted only after every part is accepted. A refused part remains retryable even if earlier parts landed.
            return .delivered
        } catch {
            return TelegramAPIFailure.isKnownNotDelivered(error)
                ? .notDelivered(reason: error.localizedDescription)
                : .unknown(sent: true, reason: error.localizedDescription)
        }
    }
}
