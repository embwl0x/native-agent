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
    /// 2026-09-06: the forum topic the control button lives in.
    let threadId: Int?
    let messageId: Int
    let fromUserId: Int?

    var destination: TelegramDestination {
        TelegramDestination(chatId: chatId, threadId: threadId)
    }

    init?(_ raw: JSONValue) {
        guard let payload = TelegramCallbackPayload(raw, parseData: Self.parseData) else { return nil }
        self.callbackId = payload.callbackId
        self.action = payload.command.action
        self.updateId = payload.command.updateId
        self.chatId = payload.chatId
        self.threadId = payload.threadId
        self.messageId = payload.messageId
        self.fromUserId = payload.fromUserId
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

}
