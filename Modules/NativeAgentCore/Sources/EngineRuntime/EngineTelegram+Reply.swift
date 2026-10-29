import Foundation
import PersistenceCore
import NativeAgentShared
import TelegramBot
// Blueprint: | `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |

public struct TelegramTestResponse: Codable, Hashable, Sendable {
    public var ok: Bool
    public var chatId: String
    public var messageId: Int?
    public var receipt: TelegramReceipt?
    /// A successful outgoing reply proves the saved credential can send, but
    /// it does not prove the inbound long-poll lane is alive.  These fields
    /// are attached after the transport reply, from the live
    /// BackgroundLoops owner.
    public var tokenConfigured: Bool?
    public var pollerRegistered: Bool?
    public var pollerTicking: Bool?

    public init(result: TelegramTestResult) {
        ok = true
        chatId = String(result.chatId)
        messageId = result.messageId
    }
}
