import Foundation
import PersistenceCore
import TelegramBot

/// Transport effects supplied by the host. Destination selection, payload
/// construction, fallback policy and delivery bookkeeping stay in the router.
public struct AttentionDeliveryPorts: Sendable {
    public typealias TelegramSender = @Sendable (
        _ botToken: String, _ destination: TelegramDestination, _ text: String
    ) async throws -> Void

    public typealias SlackSender = @Sendable (
        _ input: [String: JSONValue], _ dataRoot: URL
    ) async throws -> Void

    let phone: AttentionRouter.PhoneSender
    let telegram: TelegramSender
    let slack: SlackSender

    public init(
        phone: @escaping AttentionRouter.PhoneSender,
        telegram: @escaping TelegramSender,
        slack: @escaping SlackSender
    ) {
        self.phone = phone
        self.telegram = telegram
        self.slack = slack
    }
}
