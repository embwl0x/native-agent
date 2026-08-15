import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func handleApprovalSlashCommand(
        _ command: TelegramApprovalCommand,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        guard let approvalHandler else {
            let reply = "Approval commands are not wired on this Telegram surface."
            do {
                try await sendMessage(token, message.chatId, reply)
                await recordReceipt(kind: "approval_unavailable", update: update, message: message, text: text, reply: reply)
            } catch {
                await recordError(context: "send_approval_unavailable", error: String(describing: error), update: update, message: message, text: text)
            }
            return
        }
        do {
            let resolution = try await approvalHandler.resolveTelegramApproval(
                id: command.id,
                decision: command.decision,
                chatId: message.chatId,
                fromUserId: message.fromUserId
            )
            if let prompt = resolution.continuationPrompt {
                await deliverApprovalContinuation(
                    prompt: prompt,
                    acknowledgement: resolution.acknowledgement,
                    chatId: message.chatId,
                    fromUserId: message.fromUserId
                )
            } else {
                try await sendMessage(token, message.chatId, resolution.acknowledgement)
            }
            await recordReceipt(
                kind: "approval_decision",
                update: update,
                message: message,
                text: text,
                reply: resolution.acknowledgement
            )
        } catch {
            let reply = "Approval update failed: \(Self._tgRedactToken(String(describing: error)))"
            do {
                try await sendMessage(token, message.chatId, reply)
                await recordReceipt(kind: "approval_error", update: update, message: message, text: text, reply: reply)
            } catch {
                await recordError(context: "send_approval_error", error: String(describing: error), update: update, message: message, text: text)
            }
        }
    }

    func handleApprovalCallback(update: TelegramUpdate, callback: JSONValue) async -> Bool {
        guard let parsed = TelegramApprovalCallback(callback) else { return false }
        // Fail-closed perimeter, same contract as the message gate (2026-08-13
        // gpt-5.5 BLOCKING: with an empty allowlist a stale/forged approval
        // button could resolve an approval and start a chat continuation while
        // the front door was supposedly closed).
        let hasAllowlist = !allowedChatIds.isEmpty || !allowedUserIds.isEmpty
        guard hasAllowlist else {
            await recordBlocked(reason: "allowlist_empty_fail_closed", update: update, message: nil, text: nil)
            try? await answerCallbackQuery(token, parsed.callbackId, "Telegram allowlist is empty — add an approved sender in settings.")
            return true
        }
        let chatOk = allowedChatIds.contains(Int64(parsed.chatId))
        let userOk = parsed.fromUserId.map { allowedUserIds.contains(Int64($0)) } ?? false
        guard chatOk || userOk else {
            await recordBlocked(reason: "not_allowlisted", update: update, message: nil, text: nil)
            try? await answerCallbackQuery(token, parsed.callbackId, "This Telegram chat is not allowlisted.")
            return true
        }
        guard let approvalHandler else {
            try? await answerCallbackQuery(token, parsed.callbackId, "Approval commands are not wired.")
            return true
        }
        do {
            let resolution = try await approvalHandler.resolveTelegramApproval(
                id: parsed.command.id,
                decision: parsed.command.decision,
                chatId: parsed.chatId,
                fromUserId: parsed.fromUserId
            )
            try? await answerCallbackQuery(token, parsed.callbackId, resolution.acknowledgement)
            if let prompt = resolution.continuationPrompt {
                await deliverApprovalContinuation(
                    prompt: prompt,
                    acknowledgement: resolution.acknowledgement,
                    chatId: parsed.chatId,
                    fromUserId: parsed.fromUserId
                )
            } else {
                try await sendMessage(token, parsed.chatId, resolution.acknowledgement)
            }
        } catch {
            let reply = "Approval update failed: \(Self._tgRedactToken(String(describing: error)))"
            try? await answerCallbackQuery(token, parsed.callbackId, reply)
            do {
                try await sendMessage(token, parsed.chatId, reply)
            } catch {
                await recordError(context: "send_approval_callback_error", error: String(describing: error), update: update, message: nil, text: nil)
            }
        }
        return true
    }

    /// Resume the exact Telegram conversation whose non-blocking approval just
    /// completed. The prompt is internal (`suppressUserAppend`) and carries the
    /// redacted replay result, so the assistant can finish the interrupted
    /// request without fabricating a second user message or rerunning the tool.
    private func deliverApprovalContinuation(
        prompt: String,
        acknowledgement: String,
        chatId: Int,
        fromUserId: Int?
    ) async {
        guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
            try? await sendMessage(token, chatId, acknowledgement)
            return
        }
        guard let started = await turnCoordinator.startTurn(
            chatId: chatId,
            text: prompt,
            operation: {
                let typingTask = await startTypingHeartbeat(chatId: chatId)
                defer { typingTask?.cancel() }
                do {
                    let progress = makeProgressSink(chatId: chatId)
                    let reply = try await runChatHandlerWithRetry(
                        chatId: chatId,
                        text: prompt,
                        attachments: [],
                        progress: progress,
                        replyTo: nil,
                        fromUserId: fromUserId,
                        suppressUserAppend: true
                    )
                    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await sendMessage(
                        token,
                        chatId,
                        trimmed.isEmpty ? acknowledgement : trimmed
                    )
                } catch {
                    let safeError = Self._tgRedactToken(String(describing: error))
                    try? await sendMessage(
                        token,
                        chatId,
                        "\(acknowledgement) NativeAgent could not continue the reply automatically: \(safeError)"
                    )
                }
            }
        ) else {
            try? await sendMessage(
                token,
                chatId,
                "\(acknowledgement) A different turn is running; the verified result is saved for the next turn."
            )
            return
        }
        await started.task.value
        await turnCoordinator.finishTurn(chatId: chatId, turnId: started.id)
    }
}
