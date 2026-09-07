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
        self.turnId = payload.command.turnId
        self.chatId = payload.chatId
        self.threadId = payload.threadId
        self.messageId = payload.messageId
        self.fromUserId = payload.fromUserId
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

}
