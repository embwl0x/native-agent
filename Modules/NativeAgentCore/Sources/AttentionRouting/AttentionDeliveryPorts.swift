import Foundation
import PersistenceCore
import TelegramBot
import DeviceSync
// Blueprint: | `AttentionDeliveryPorts.swift` | Host ports classify delivery; phone receipts never imply acceptance |

/// Each client classifies its transport outcome; the router owns routing and bookkeeping.
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

    public typealias TelegramApprovalSender = @Sendable (
        _ approvalID: String, _ chatID: Int, _ dataRoot: URL
    ) async -> NotificationDeliveryOutcome

    let phone: @Sendable (NativeAgentNotificationDefaults.Note, [String: String]) async -> PhoneResult
    let telegram: TelegramSender
    let slack: SlackSender
    let telegramApproval: TelegramApprovalSender

    public init(
        phone: @escaping AttentionRouter.PhoneSender,
        telegram: @escaping TelegramSender,
        slack: @escaping SlackSender,
        telegramApproval: @escaping TelegramApprovalSender
    ) {
        self.phone = { note, info in
            do {
                let receipt = try await phone(note, info)
                return PhoneResult(outcome: receipt.notificationOutcome, receipt: receipt)
            } catch let failure as NotificationDeliveryFailure {
                return PhoneResult(outcome: failure.outcome, receipt: nil)
            } catch {
                return PhoneResult(outcome: .unknown(sent: true, reason: error.localizedDescription), receipt: nil)
            }
        }
        self.telegram = telegram
        self.slack = slack
        self.telegramApproval = telegramApproval
    }
}
