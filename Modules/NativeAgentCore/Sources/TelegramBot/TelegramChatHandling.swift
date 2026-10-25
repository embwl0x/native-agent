import Foundation
import PersistenceCore
import ChatSessionWork

// Blueprint: | `TelegramChatHandling.swift` | Telegram chat contracts: progress/compaction sinks and attempt context carrying decoded sender identity separately from chat identity |

public typealias TelegramCompactionHandler = @Sendable (_ sessionId: String) async throws -> ChatSessionCompactionOutcome

public enum TelegramChatProgressEvent: Sendable, Equatable {
    case replyTextSettled(Bool)
    case status(text: String)
    case toolUse(name: String, input: JSONValue?)
    case toolResult(name: String, output: JSONValue?)
    /// In-turn notice (invoke_claude start / heartbeat / timeout). `kind`
    /// lets the sink throttle heartbeats while always delivering terminal
    /// notices like `invoke_timeout`.
    case notice(kind: String, text: String)
    /// Accumulated reply text so far. Routed to the native draft preview,
    /// never rendered as a discrete progress message.
    case textDelta(accumulated: String)
}

public typealias TelegramChatProgressSink = @Sendable (TelegramChatProgressEvent) async -> Void

public struct TelegramChatAttemptContext: Sendable, Equatable {
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
    public let runId: String?
    /// 2026-09-06: the forum topic this turn arrived in, when there is one.
    /// The handler keys its chat session on (chatId, threadId): a topic in a
    /// supergroup is its own conversation, and nil means the whole chat — a
    /// DM, an ordinary group, or a forum's General topic.
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
