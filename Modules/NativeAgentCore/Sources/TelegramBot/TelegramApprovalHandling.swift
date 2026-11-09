import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TelegramApprovalHandling.swift` | `TelegramApprovalHandling`: a card's button or a slash decision names one action of its matter's Inbox row |

/// The person's answer to a card on Telegram: one action of its matter's Inbox row. A button names only the action; its matter is the one its
/// message was sent for. A slash command (`/approve <id>`, `/deny <id>`) names the matter and the row's approve or reject.
public struct TelegramApprovalCommand: Sendable, Equatable {
    /// The matter a slash command names; nil for a button.
    public let matter: String?
    public let action: String
    public let addressedBot: String?

    public init(matter: String?, action: String, addressedBot: String? = nil) {
        self.matter = matter
        self.action = action
        self.addressedBot = addressedBot
    }

    public static func parse(command: TelegramParsedSlashCommand, addressedBot: String?) -> TelegramApprovalCommand? {
        let action: String
        switch command.definition.handler {
        case .approve: action = "approve"
        case .deny: action = "reject"
        default: return nil
        }
        guard let id = command.args.first else { return nil }
        return TelegramApprovalCommand(matter: id, action: action, addressedBot: addressedBot)
    }

    /// A card's button carries `na_card:` and its action's id: Telegram holds at most 64 bytes, so the matter is read from the message.
    public static let callbackPrefix = "na_card:"
    public static let callbackLimit = 64

    public static func parse(callbackData raw: String) -> TelegramApprovalCommand? {
        guard raw.hasPrefix(callbackPrefix) else { return nil }
        let action = String(raw.dropFirst(callbackPrefix.count))
        guard !action.isEmpty else { return nil }
        return TelegramApprovalCommand(matter: nil, action: action)
    }
}

public protocol TelegramApprovalHandling: Sendable {
    func startApprovalDelivery() async
    func stopApprovalDelivery() async
    /// The person's answer to a card, from an allowlisted sender: a button on the card's message (`messageId`), or a slash command naming
    /// its matter. It runs that matter's Inbox row action through the person's Telegram door, or says why it did not.
    func act(_ command: TelegramApprovalCommand, chatId: Int, messageId: Int?, fromUserId: Int?) async -> TelegramApprovalResolution
}

/// Telegram acknowledges the answer in the act's own words; the card's owner reports its result.
public struct TelegramApprovalResolution: Sendable, Equatable {
    public let acknowledgement: String
    /// True when the card's row offers nothing more on Telegram, so its buttons are done; nil when the row could not be read.
    public let settled: Bool?

    public init(acknowledgement: String, settled: Bool?) {
        self.acknowledgement = acknowledgement
        self.settled = settled
    }
}

public struct TelegramApprovalCallback: Sendable, Equatable {
    public let callbackId: String
    public let command: TelegramApprovalCommand
    public let chatId: Int
    public let threadId: Int?
    public let messageId: Int
    public let fromUserId: Int?

    public var destination: TelegramDestination {
        TelegramDestination(chatId: chatId, threadId: threadId)
    }

    public init?(_ raw: JSONValue) {
        guard let payload = TelegramCallbackPayload(raw, parseData: TelegramApprovalCommand.parse(callbackData:)) else { return nil }
        self.callbackId = payload.callbackId
        self.command = payload.command
        self.chatId = payload.chatId
        self.threadId = payload.threadId
        self.messageId = payload.messageId
        self.fromUserId = payload.fromUserId
    }

}
