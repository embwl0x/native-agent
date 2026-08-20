import Foundation
import NativeAgentCore
import PersistenceCore

enum TelegramTurnControlAction: String, Sendable, Equatable {
    case status = "s"
    case details = "d"
    case stop = "x"
}

struct TelegramTurnControlCallback: Sendable, Equatable {
    let callbackId: String
    let action: TelegramTurnControlAction
    let turnId: UUID
    let chatId: Int
    let messageId: Int
    let fromUserId: Int?

    init?(_ raw: JSONValue) {
        guard case .object(let object) = raw,
              case .string(let callbackId)? = object["id"],
              case .string(let data)? = object["data"],
              let parsed = Self.parseData(data),
              case .object(let message)? = object["message"],
              case .object(let chat)? = message["chat"],
              let chatId = Self.int(chat["id"]),
              let messageId = Self.int(message["message_id"])
                ?? Self.int(message["messageId"]) else {
            return nil
        }
        let fromUserId: Int? = {
            guard case .object(let from)? = object["from"] else { return nil }
            return Self.int(from["id"])
        }()
        self.callbackId = callbackId
        self.action = parsed.action
        self.turnId = parsed.turnId
        self.chatId = chatId
        self.messageId = messageId
        self.fromUserId = fromUserId
    }

    static func replyMarkup(turnId: UUID) -> JSONValue {
        .object([
            "inline_keyboard": .array([
                .array([
                    button(title: "Status", action: .status, turnId: turnId),
                    button(title: "Details", action: .details, turnId: turnId),
                    button(title: "Stop", action: .stop, turnId: turnId),
                ]),
            ]),
        ])
    }

    static let clearedReplyMarkup: JSONValue = .object([
        "inline_keyboard": .array([]),
    ])

    private static func button(
        title: String,
        action: TelegramTurnControlAction,
        turnId: UUID
    ) -> JSONValue {
        .object([
            "text": .string(title),
            "callback_data": .string(data(action: action, turnId: turnId)),
        ])
    }

    private static func data(action: TelegramTurnControlAction, turnId: UUID) -> String {
        "na_turn:\(action.rawValue):\(turnId.uuidString.lowercased())"
    }

    private static func parseData(
        _ raw: String
    ) -> (action: TelegramTurnControlAction, turnId: UUID)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3,
              parts[0] == "na_turn",
              let action = TelegramTurnControlAction(rawValue: parts[1]),
              let turnId = UUID(uuidString: parts[2]) else {
            return nil
        }
        return (action, turnId)
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let value)?: return Int(value)
        case .double(let value)?: return Int(value)
        case .string(let value)?: return Int(value)
        default: return nil
        }
    }
}
