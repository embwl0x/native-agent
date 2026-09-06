import Foundation
import NativeAgentCore
import PersistenceCore

public enum TelegramApprovalDecision: String, Sendable, Equatable {
    case approved
    case denied
}

public struct TelegramApprovalCommand: Sendable, Equatable {
    public let id: String
    public let decision: TelegramApprovalDecision
    /// 2026-09-06: the `@bot` the command was addressed to, if any
    /// (`/approve@OtherBot id` -> "OtherBot"). The text parser used to strip
    /// this suffix WITHOUT reading it, so the value was only recoverable by
    /// re-parsing the raw text; the poll loop's own gate does that today, and
    /// a future caller reaching the parser directly would have silently
    /// answered an approval addressed to another bot in the room. Nil means
    /// the command named no bot, or did not arrive as text at all (a callback
    /// button is delivered only to the bot that sent it).
    public let addressedBot: String?

    public init(
        id: String,
        decision: TelegramApprovalDecision,
        addressedBot: String? = nil
    ) {
        self.id = id
        self.decision = decision
        self.addressedBot = addressedBot
    }

    public static func parse(text raw: String) -> TelegramApprovalCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 2 else { return nil }
        let command = parts[0]
            .dropFirst()
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).lowercased() } ?? ""
        let decision: TelegramApprovalDecision
        switch command {
        case "approve", "approved", "allow":
            decision = .approved
        case "deny", "denied", "reject", "rejected":
            decision = .denied
        default:
            return nil
        }
        let id = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return TelegramApprovalCommand(
            id: id,
            decision: decision,
            addressedBot: TelegramCommandRegistry.addressedBotUsername(text: trimmed)
        )
    }

    public static func parse(callbackData raw: String) -> TelegramApprovalCommand? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "na_approval" else { return nil }
        let decision: TelegramApprovalDecision
        switch parts[1] {
        case "approve", "approved":
            decision = .approved
        case "deny", "denied", "reject", "rejected":
            decision = .denied
        default:
            return nil
        }
        let id = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return TelegramApprovalCommand(id: id, decision: decision)
    }
}

public protocol TelegramApprovalHandling: Sendable {
    func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution
}

/// The canonical approval result plus an optional internal continuation turn.
/// A non-blocking Telegram approval ends the original model turn, so a
/// successful replay must explicitly resume it; otherwise the tool executes
/// but the assistant never receives the outcome needed to answer the user.
public struct TelegramApprovalResolution: Sendable, Equatable {
    public let acknowledgement: String
    public let continuationPrompt: String?
    /// 2026-09-06: the chat session the interrupted turn belonged to, read off
    /// the approval record. The continuation MUST resume that session: the
    /// chat's active session binding can have moved (`/new`, `/resume`) while
    /// the approval sat pending, and resolving the binding at delivery time
    /// dropped the tool result into whatever session is current instead.
    public let sessionId: String?
    /// 2026-09-06: the chat and forum topic the approval was raised in, read
    /// off the approval record. `/approve <id>` can be typed in any topic of
    /// the supergroup (or in General), and the continuation, its progress card
    /// and its reply belong to the topic the interrupted turn ran in — not to
    /// wherever the command happened to be typed.
    public let destination: TelegramDestination?

    public init(
        acknowledgement: String,
        continuationPrompt: String? = nil,
        sessionId: String? = nil,
        destination: TelegramDestination? = nil
    ) {
        self.acknowledgement = acknowledgement
        self.continuationPrompt = continuationPrompt
        self.sessionId = sessionId
        self.destination = destination
    }
}

public struct TelegramApprovalCallback: Sendable, Equatable {
    public let callbackId: String
    public let command: TelegramApprovalCommand
    public let chatId: Int
    /// 2026-09-06: the forum topic the button lives in, so the acknowledgement
    /// and any continuation answer in that topic rather than in General.
    public let threadId: Int?
    public let messageId: Int
    public let fromUserId: Int?

    public var destination: TelegramDestination {
        TelegramDestination(chatId: chatId, threadId: threadId)
    }

    public init?(_ raw: JSONValue) {
        guard case .object(let obj) = raw else { return nil }
        guard case .string(let callbackId)? = obj["id"],
              case .string(let data)? = obj["data"],
              let command = TelegramApprovalCommand.parse(callbackData: data) else {
            return nil
        }
        let fromUserId: Int? = {
            guard case .object(let from)? = obj["from"] else { return nil }
            return Self.int(from["id"])
        }()
        let message: [String: JSONValue]? = {
            guard case .object(let value)? = obj["message"] else { return nil }
            return value
        }()
        let chatId: Int? = {
            guard case .object(let chat)? = message?["chat"] else { return nil }
            return Self.int(chat["id"])
        }()
        let messageId = Self.int(message?["message_id"])
            ?? Self.int(message?["messageId"])
        guard let chatId, let messageId else { return nil }
        self.callbackId = callbackId
        self.command = command
        self.chatId = chatId
        self.threadId = TelegramDestination.topicThreadId(inMessageObject: message)
        self.messageId = messageId
        self.fromUserId = fromUserId
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }
}
