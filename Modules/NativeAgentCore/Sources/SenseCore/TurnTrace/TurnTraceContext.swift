import Foundation
import NativeAgentCore
// Blueprint: | `TurnTraceContext.swift` | Trace-only correlation; reply-row identity is held on `Turn.replyRow` |

/// Trace correlation only. Decisions and writes read the explicit Turn instead.
public enum TurnTraceContext {
    @TaskLocal public static var turnId: String?
    /// Native work keeps its receipts but is not a choice made by the mind.
    @TaskLocal public static var automaticOrigin: String?
    /// Optional request-scoped bus; context emitters otherwise use `.shared`.
    @TaskLocal public static var bus: TurnTraceBus?

    /// The reply route's conversation and thread, bound beside turnId so every event captures them before detached persistence. Nil without a return route.
    @TaskLocal public static var destinationId: String?
    @TaskLocal public static var threadId: String?

    /// Adopt reply identity only in its own session and turn so nested helper conversations cannot take the parent's row.
    public struct ReplyRow: Sendable, Equatable {
        public let turnId: String
        public let sessionId: String
        public let messageId: String
        public init(turnId: String, sessionId: String, messageId: String) {
            self.turnId = turnId
            self.sessionId = sessionId
            self.messageId = messageId
        }
        public func messageId(turn: String?, session: String) -> String? {
            let mine = NativeAgentChatSessionID.normalizedPathComponent(sessionId)
            return turnId == turn && mine != nil && mine == NativeAgentChatSessionID.normalizedPathComponent(session) ? messageId : nil
        }
    }

    /// Lowercase UUIDs to match trace row identity conventions.
    public static func mintTurnId() -> String {
        UUID().uuidString.lowercased()
    }

}
