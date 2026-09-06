import Foundation
import PersistenceCore

public typealias TelegramChatHandler = @Sendable (_ chatId: Int, _ text: String) async throws -> String

public enum TelegramChatProgressEvent: Sendable, Equatable {
    case status(text: String)
    case toolUse(name: String, input: JSONValue?)
    case toolResult(name: String, output: JSONValue?)
    /// In-turn notice (invoke_claude start / heartbeat / timeout). `kind`
    /// lets the sink throttle heartbeats while always delivering terminal
    /// notices like `invoke_timeout`.
    case notice(kind: String, text: String)
    /// Accumulated reply text so far. Routed to the growing draft streamer,
    /// never rendered as a discrete progress message.
    case textDelta(accumulated: String)
}

public typealias TelegramChatProgressSink = @Sendable (TelegramChatProgressEvent) async -> Void

public struct TelegramChatAttemptContext: Sendable, Equatable {
    public let attemptIndex: Int
    public let totalAttempts: Int
    public let replyTo: TelegramReplyContext?
    /// Transport-decoded Telegram sender identity. This is carried separately
    /// from chatId because group chats differ and private installs commonly
    /// configure `allowed_user_ids`, which TrustCenter must be able to prove at
    /// the effect-time gate.
    public let fromUserId: Int?
    /// 2026-09-06: the chat session this turn must run in, when the caller
    /// already knows it. Only an approval continuation sets it — it has to
    /// resume the session the interrupted turn ran in, not whichever session
    /// the chat is bound to now. Nil means "resolve the chat's active session".
    public let sessionId: String?
    /// 2026-09-06: the forum topic this turn arrived in, when there is one.
    /// The handler keys its chat session on (chatId, threadId): a topic in a
    /// supergroup is its own conversation, and nil means the whole chat — a
    /// DM, an ordinary group, or a forum's General topic.
    public let threadId: Int?
    private let suppressUserAppendOverride: Bool

    public var isRetry: Bool { attemptIndex > 0 }
    public var suppressUserAppend: Bool { suppressUserAppendOverride || isRetry }

    public init(
        attemptIndex: Int,
        totalAttempts: Int,
        replyTo: TelegramReplyContext? = nil,
        fromUserId: Int? = nil,
        suppressUserAppend: Bool = false,
        sessionId: String? = nil,
        threadId: Int? = nil
    ) {
        self.attemptIndex = max(0, attemptIndex)
        self.totalAttempts = max(1, totalAttempts)
        self.replyTo = replyTo
        self.fromUserId = fromUserId
        self.threadId = threadId
        self.suppressUserAppendOverride = suppressUserAppend
        let trimmedSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionId = (trimmedSession?.isEmpty ?? true) ? nil : trimmedSession
    }
}

public typealias TelegramProgressChatHandler = @Sendable (
    _ chatId: Int,
    _ text: String,
    _ progress: @escaping TelegramChatProgressSink,
    _ context: TelegramChatAttemptContext
) async throws -> String

/// Progress chat handler variant that also carries inbound image attachments
/// (telegram-vision-in). When non-empty, `attachments` hold already-downloaded
/// image bytes (`TelegramMediaAttachment.bytes` set) the app-layer handler
/// converts to ChatOrchestration's MultimodalAttachment and threads onto the
/// chat turn. Carrying `TelegramMediaAttachment` keeps this module free of a
/// ChatOrchestration dependency.
public typealias TelegramProgressChatHandlerWithAttachments = @Sendable (
    _ chatId: Int,
    _ text: String,
    _ attachments: [TelegramMediaAttachment],
    _ progress: @escaping TelegramChatProgressSink,
    _ context: TelegramChatAttemptContext
) async throws -> String
