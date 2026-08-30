import Foundation
import NativeAgentCore
import PersistenceCore

enum TelegramQueuedTurnControlAction: String, Sendable, Equatable {
    case steer = "s"
    case remove = "x"
}

struct TelegramQueuedTurnControlCallback: Sendable, Equatable {
    let callbackId: String
    let action: TelegramQueuedTurnControlAction
    let updateId: Int
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
        self.updateId = parsed.updateId
        self.chatId = chatId
        self.messageId = messageId
        self.fromUserId = fromUserId
    }

    static func replyMarkup(updateId: Int) -> JSONValue {
        .object([
            "inline_keyboard": .array([
                .array([
                    button(title: "Steer now", action: .steer, updateId: updateId),
                    button(title: "Remove", action: .remove, updateId: updateId),
                ]),
            ]),
        ])
    }

    private static func button(
        title: String,
        action: TelegramQueuedTurnControlAction,
        updateId: Int
    ) -> JSONValue {
        .object([
            "text": .string(title),
            "callback_data": .string("na_queue:\(action.rawValue):\(updateId)"),
        ])
    }

    private static func parseData(
        _ raw: String
    ) -> (action: TelegramQueuedTurnControlAction, updateId: Int)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3,
              parts[0] == "na_queue",
              let action = TelegramQueuedTurnControlAction(rawValue: parts[1]),
              let updateId = Int(parts[2]) else {
            return nil
        }
        return (action, updateId)
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
