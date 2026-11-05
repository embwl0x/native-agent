import Foundation
import PersistenceCore
import ChatSessionWork
import ChatTurnRuntime
import NativeAgentCore

// Blueprint: | `TelegramChatHandling.swift` | Sender identity stays separate from chat identity; handlers return reply faces |


public typealias TelegramChatProgressSink = @Sendable (TurnStreamEvent) async -> Void

public struct TelegramChatAttemptContext: Sendable {
    public let turn: Turn
    public let replyTo: TelegramReplyContext?
    /// Carry sender identity separately from group chat identity so TrustCenter can prove allowed_user_ids at the effect gate.
    public let fromUserId: Int?
    /// Approval continuations pin their original session; nil resolves the chat's active session.
    public var sessionId: String? { turn.session }
    public var runId: String { turn.run }
    /// Sessions key on (chatId, threadId); nil addresses a chat-only conversation.
    public let threadId: Int?
    public let suppressUserAppend: Bool

    public init(
        turn: Turn,
        replyTo: TelegramReplyContext? = nil,
        fromUserId: Int? = nil,
        suppressUserAppend: Bool = false,
        threadId: Int? = nil
    ) {
        self.turn = turn
        self.replyTo = replyTo
        self.fromUserId = fromUserId
        self.threadId = threadId
        self.suppressUserAppend = suppressUserAppend
    }
}

/// Carry downloaded media independently of the app-layer attachment type; the returned reply face keeps words and images together.
/// `readBy`: the agent's turn in progress read the message, so that turn's reply answers it and this update posts nothing.
public typealias TelegramProgressChatHandlerWithAttachments = @Sendable (
    _ chatId: Int,
    _ text: String,
    _ attachments: [TelegramMediaAttachment],
    _ context: TelegramChatAttemptContext
) async throws -> (reply: String, imagePaths: [String], readBy: String?)
