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

    public init(id: String, decision: TelegramApprovalDecision) {
        self.id = id
        self.decision = decision
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
        return TelegramApprovalCommand(id: id, decision: decision)
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

    public init(acknowledgement: String, continuationPrompt: String? = nil) {
        self.acknowledgement = acknowledgement
        self.continuationPrompt = continuationPrompt
    }
}

public struct TelegramApprovalCallback: Sendable, Equatable {
    public let callbackId: String
    public let command: TelegramApprovalCommand
    public let chatId: Int
    public let fromUserId: Int?

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
        let chatId: Int? = {
            guard case .object(let message)? = obj["message"],
                  case .object(let chat)? = message["chat"] else { return nil }
            return Self.int(chat["id"])
        }()
        guard let chatId else { return nil }
        self.callbackId = callbackId
        self.command = command
        self.chatId = chatId
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
