import Foundation
import NativeAgentShared
import ProviderRouting
import NativeAgentCore
import ChatToolRuntime
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore

// Blueprint: | `TelegramRestart.swift` | Owner-authorized Telegram restart through the injected app operation with termination deferred until the reply attempt |

/// Uses the injected app restart operation; termination is armed after the reply attempt.
public struct TelegramRestartBridge: Sendable {
    public typealias DeferredRestart = @Sendable (
        _ reason: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?)

    let dataRoot: URL
    private let deferredRestart: DeferredRestart

    public init(dataRoot: URL, deferredRestart: @escaping DeferredRestart) {
        self.dataRoot = dataRoot
        self.deferredRestart = deferredRestart
    }

    public func ownerChatIds() async -> Set<Int64> {
        // Re-read the owner allowlist per call; empty or missing config fails closed.
        TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.allowedChatIds ?? []
    }

    public func requestRestart(reason: String) async -> TelegramSlashDispatchOutcome {
        // Commit the restart here; the poll loop arms termination after its reply attempt.
        let (envelope, armTerminate) = await deferredRestart(reason)
        guard case .object(let obj) = envelope else {
            return TelegramSlashDispatchOutcome(
                reply: "Restart failed: unexpected coordinator response."
            )
        }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key] { return s }
            return nil
        }
        if str("status") == "restarting", let armTerminate {
            return TelegramSlashDispatchOutcome(
                reply: "Restarting NativeAgent — back in under a minute. \(str("note") ?? "")",
                afterReplySent: armTerminate
            )
        }
        if str("status") == "restarting" {
            // Refuse a restart without the post-reply termination handoff.
            return TelegramSlashDispatchOutcome(
                reply: "Restart failed: restart handoff was incomplete; NativeAgent is still running."
            )
        }
        if str("reason") == "cooldown" {
            let retry: String = {
                if case .double(let n)? = obj["retryAfterSeconds"],
                   let seconds = Int(exactly: n.rounded(.towardZero)) { return String(seconds) }
                return "?"
            }()
            return TelegramSlashDispatchOutcome(
                reply: "Restart refused: a tool-initiated restart fired within the last 10 minutes. Retry in \(retry)s."
            )
        }
        return TelegramSlashDispatchOutcome(
            reply: "Restart failed: \(str("reason") ?? "unknown"). \(str("detail") ?? "")"
        )
    }
}

extension SwiftNativeTelegramBot {
    /// Owner-gated restart through the injected shared app restart routine.
    func dispatchRestartCommand(
        args: [String],
        chatId: Int?,
        fromUserId: Int?,
        chatType: String?
    ) async -> TelegramSlashDispatchOutcome {
        guard let restart = completenessDeps?.restart else {
            return TelegramSlashDispatchOutcome(
                reply: "restart is not wired in this build. Restart NativeAgent from the Mac app."
            )
        }
        // Require wire chat.type == private, or a positive chat ID when chat.type is absent.
        let isPrivate: Bool = {
            if let chatType { return chatType == "private" }
            if let chatId { return chatId > 0 }
            return false
        }()
        guard isPrivate else {
            return TelegramSlashDispatchOutcome(
                reply: "/restart only works in a private chat with the owner; group chats cannot restart the app."
            )
        }
        let owners = await restart.ownerChatIds()
        // Missing allowlist or chat identity fails the owner gate closed.
        guard let chatId, !owners.isEmpty, owners.contains(Int64(chatId)) else {
            return TelegramSlashDispatchOutcome(
                reply: "/restart is owner-gated; this chat is not authorized."
            )
        }
        // Private-chat sender and chat IDs must match; missing identity fails closed.
        guard let fromUserId, Int64(fromUserId) == Int64(chatId) else {
            return TelegramSlashDispatchOutcome(
                reply: "/restart is owner-gated; this chat is not authorized."
            )
        }
        let reasonText = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return await restart.requestRestart(
            reason: reasonText.isEmpty ? "telegram /restart" : reasonText
        )
    }

}
