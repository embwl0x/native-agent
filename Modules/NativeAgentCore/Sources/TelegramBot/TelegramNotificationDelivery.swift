import Foundation
import PersistenceCore
// Blueprint: | `TelegramNotificationDelivery.swift` | `TelegramPollLoop.notificationOutcome`: accept only complete chunked sends; failures after accepted parts remain unknown and cannot authorize whole-message replay |

extension TelegramPollLoop {
    public static func notificationOutcome(_ token: String, _ destination: TelegramDestination,
                                           _ text: String) async -> NotificationDeliveryOutcome {
        guard !token.isEmpty, !text.isEmpty else {
            return .notDelivered(reason: "Telegram notification needs credentials and a nonempty message")
        }
        var acceptedParts = 0
        do {
            for part in try _tgChunkMessage(text, limit: 4000) {
                if Task.isCancelled {
                    return acceptedParts == 0 ? .notDelivered(reason: "cancelled before first part dispatch")
                        : .unknown(sent: true, reason: "Telegram accepted \(acceptedParts) notification parts before cancellation; the rest was not sent")
                }
                _ = try await defaultSendMessageWithReplyMarkupReturningId(token, destination, part, .object([:]))
                acceptedParts += 1
            }
            return .delivered
        } catch {
            if acceptedParts > 0 {
                return .unknown(sent: true, reason: "Telegram accepted \(acceptedParts) notification parts; the rest is unconfirmed: \(error.localizedDescription)")
            }
            return TelegramAPIFailure.isKnownNotDelivered(error)
                ? .notDelivered(reason: error.localizedDescription)
                : .unknown(sent: true, reason: error.localizedDescription)
        }
    }
}
