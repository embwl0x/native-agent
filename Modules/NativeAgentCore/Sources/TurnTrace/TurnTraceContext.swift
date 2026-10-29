import Foundation
// Blueprint: | `TurnTraceContext.swift` | Request-scoped turn identity, origin, reply route and stable reply-row correlation |

/// Task-local turn identity and reply correlation, inherited by tasks created
/// inside the binding. Unbound emitters retain standalone receipts with
/// turnId "unknown"; context-based bus emission requires a bound turn.
public enum TurnTraceContext {
    @TaskLocal public static var turnId: String?
    /// Native work keeps its receipts but is not a choice made by the mind.
    @TaskLocal public static var automaticOrigin: String?
    /// Optional request-scoped bus; context emitters otherwise use `.shared`.
    @TaskLocal public static var bus: TurnTraceBus?

    /// The reply route's conversation and thread, bound beside turnId so every
    /// event captures them before detached persistence. Nil without a return route.
    @TaskLocal public static var destinationId: String?
    @TaskLocal public static var threadId: String?

    /// The row a surface is already drawing this turn's reply in. The turn's
    /// answer is written under that id, so the reply the person watched arrive
    /// is the row that stays: nothing is swapped out when it lands.
    @TaskLocal public static var replyRow: ReplyRow?

    public struct ReplyRow: Sendable, Equatable {
        public let turnId: String
        public let messageId: String
        public init(turnId: String, messageId: String) {
            self.turnId = turnId
            self.messageId = messageId
        }
    }

    /// Mint a fresh UUID-based turn id. Lowercased to match the row-id
    /// convention used across the trace writers.
    public static func mintTurnId() -> String {
        UUID().uuidString.lowercased()
    }

}
