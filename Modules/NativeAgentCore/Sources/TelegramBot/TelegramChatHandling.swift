import Foundation
import PersistenceCore
import ChatSessionWork
import ChatTurnRuntime

// Blueprint: | `TelegramChatHandling.swift` | Telegram chat contracts: progress/compaction sinks and attempt context carrying decoded sender identity separately from chat identity |

public typealias TelegramCompaction = @Sendable (_ sessionId: String) async throws -> ChatSessionCompactionOutcome

public typealias TelegramChatProgressSink = @Sendable (TurnStreamEvent) async -> Void

public struct TelegramChatAttemptContext: Sendable, Equatable {
    public let replyTo: TelegramReplyContext?
    /// Transport-decoded Telegram sender identity. This is carried separately
    /// from chatId because group chats differ and private installs commonly
    /// configure `allowed_user_ids`, which TrustCenter must be able to prove at
    /// the effect-time gate.
    public let fromUserId: Int?
    /// Approval continuations pin their original session; nil resolves the chat's active session.
    public let sessionId: String?
    public let runId: String?
    /// Sessions key on (chatId, threadId); nil addresses a chat-only conversation.
    public let threadId: Int?
    public let suppressUserAppend: Bool

    public init(
        replyTo: TelegramReplyContext? = nil,
        fromUserId: Int? = nil,
        suppressUserAppend: Bool = false,
        sessionId: String? = nil,
        runId: String? = nil,
        threadId: Int? = nil
    ) {
        self.replyTo = replyTo
        self.fromUserId = fromUserId
        self.threadId = threadId
        self.suppressUserAppend = suppressUserAppend
        let trimmedSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionId = (trimmedSession?.isEmpty ?? true) ? nil : trimmedSession
        self.runId = runId
    }
}

/// Progress chat handler variant that also carries inbound image attachments
/// (telegram-vision-in). When non-empty, `attachments` hold already-downloaded
/// image bytes (`TelegramMediaAttachment.bytes` set) the app-layer handler
/// converts to ChatTurnContracts' MultimodalAttachment and threads onto the
/// chat turn. Carrying `TelegramMediaAttachment` keeps this handler interface
/// independent of the chat attachment contract. It returns her reply's face: its words and
/// the images she chose, which Telegram renders together.
public typealias TelegramProgressChatHandlerWithAttachments = @Sendable (
    _ chatId: Int,
    _ text: String,
    _ attachments: [TelegramMediaAttachment],
    _ progress: @escaping TelegramChatProgressSink,
    _ context: TelegramChatAttemptContext
) async throws -> (reply: String, imagePaths: [String])
