import Foundation
import PersistenceCore
import TelegramBot
import DeviceSync
// Blueprint: | `AttentionDeliveryPorts.swift` | Host notification ports return the shared delivery verdict; phone evidence preserves its receipt without inferring acceptance |

/// Transport effects supplied by the host. Destination selection, payload
/// construction and delivery bookkeeping stay in the router. Every client
/// classifies its own outcome before it crosses this port.
public struct AttentionDeliveryPorts: Sendable {
    struct PhoneResult: Sendable {
        let outcome: NotificationDeliveryOutcome
        let receipt: MobileNotificationDeliveryReceipt?
    }
    public typealias TelegramSender = @Sendable (
        _ botToken: String, _ destination: TelegramDestination, _ text: String
    ) async -> NotificationDeliveryOutcome

    public typealias SlackSender = @Sendable (
        _ input: [String: JSONValue], _ dataRoot: URL
    ) async -> NotificationDeliveryOutcome

    let phone: @Sendable (String, String, [String: String]) async -> PhoneResult
    let telegram: TelegramSender
    let slack: SlackSender

    public init(
        phone: @escaping AttentionRouter.PhoneSender,
        telegram: @escaping TelegramSender,
        slack: @escaping SlackSender
    ) {
        self.phone = { title, body, info in
            do {
                let receipt = try await phone(title, body, info)
                return PhoneResult(outcome: receipt.notificationOutcome, receipt: receipt)
            } catch let failure as NotificationDeliveryFailure {
                return PhoneResult(outcome: failure.outcome, receipt: nil)
            } catch {
                return PhoneResult(outcome: .unknown(sent: true, reason: error.localizedDescription), receipt: nil)
            }
        }
        self.telegram = telegram
        self.slack = slack
    }
}
