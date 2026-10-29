import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TelegramApprovalHandling.swift` | `TelegramApprovalHandling`: addressed-bot-aware approval parsing, callback contracts and canonical approval resolution/delivery lifecycle |

public enum TelegramApprovalDecision: String, Sendable, Equatable {
    case approved
    case denied
}

public struct TelegramApprovalCommand: Sendable, Equatable {
    public let id: String
    public let decision: TelegramApprovalDecision
    /// The command's `@bot` suffix, or nil for commands without one and callback buttons.
    public let addressedBot: String?
    /// A mirrored inline card's option, by index (`na_approval:c<n>:<id>`).
    public let choice: Int?

    public init(
        id: String,
        decision: TelegramApprovalDecision,
        addressedBot: String? = nil,
        choice: Int? = nil
    ) {
        self.id = id
        self.decision = decision
        self.addressedBot = addressedBot
        self.choice = choice
    }

    public static func parse(command: TelegramParsedSlashCommand, addressedBot: String?) -> TelegramApprovalCommand? {
        let decision: TelegramApprovalDecision
        switch command.definition.handler {
        case .approve: decision = .approved
        case .deny: decision = .denied
        default: return nil
        }
        guard let id = command.args.first else { return nil }
        return TelegramApprovalCommand(id: id, decision: decision, addressedBot: addressedBot)
    }

    public static func parse(callbackData raw: String) -> TelegramApprovalCommand? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "na_approval" else { return nil }
        let decision: TelegramApprovalDecision
        var choice: Int?
        switch parts[1] {
        case "approve", "approved":
            decision = .approved
        case "deny", "denied", "reject", "rejected":
            decision = .denied
        case let verb where verb.hasPrefix("c") && Int(verb.dropFirst()).map({ $0 >= 0 }) == true:
            decision = .approved
            choice = Int(verb.dropFirst())
        default:
            return nil
        }
        let id = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return TelegramApprovalCommand(id: id, decision: decision, choice: choice)
    }
}

public protocol TelegramApprovalHandling: Sendable {
    func startApprovalDelivery() async
    func stopApprovalDelivery() async
    /// Slash decisions carry nil; mirrored cards carry their picked option.
    func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        choice: Int?,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution
}

/// Telegram acknowledges the decision; the shared approval owner reports its result.
public struct TelegramApprovalResolution: Sendable, Equatable {
    public let acknowledgement: String

    public init(acknowledgement: String) {
        self.acknowledgement = acknowledgement
    }
}

public struct TelegramApprovalCallback: Sendable, Equatable {
    public let callbackId: String
    public let command: TelegramApprovalCommand
    public let chatId: Int
    /// The button's forum topic, shared by acknowledgements and continuation replies.
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
