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
            await answerApprovalCallback(
                parsed.callbackId,
                text: "Telegram allowlist is empty — add an approved sender in settings.",
                context: "approval_allowlist_callback_answer",
                update: update
            )
            return true
        }
        let chatOk = allowedChatIds.contains(Int64(parsed.chatId))
        let userOk = parsed.fromUserId.map { allowedUserIds.contains(Int64($0)) } ?? false
        guard chatOk || userOk else {
            await recordBlocked(reason: "not_allowlisted", update: update, message: nil, text: nil)
            await answerApprovalCallback(
                parsed.callbackId,
                text: "This Telegram chat is not allowlisted.",
                context: "approval_unauthorized_callback_answer",
                update: update
            )
            return true
        }
        guard let approvalHandler else {
            await answerApprovalCallback(
                parsed.callbackId,
                text: "Approval commands are not wired.",
                context: "approval_unavailable_callback_answer",
                update: update
            )
            return true
        }
        guard await turnCoordinator.claimCallback(parsed.callbackId) else {
            do {
                try await answerCallbackQuery(token, parsed.callbackId, "This approval callback was already handled.")
            } catch {
                await recordError(
                    context: "approval_duplicate_callback_answer",
                    error: String(describing: error),
                    update: update,
                    message: nil,
                    text: nil
                )
            }
            return true
        }
        do {
            let resolution = try await approvalHandler.resolveTelegramApproval(
                id: parsed.command.id,
                decision: parsed.command.decision,
                chatId: parsed.chatId,
                fromUserId: parsed.fromUserId
            )
            do {
                try await answerCallbackQuery(
                    token,
                    parsed.callbackId,
                    resolution.acknowledgement
                )
            } catch {
                await recordError(
                    context: "approval_callback_answer",
                    error: String(describing: error),
                    update: update,
                    message: nil,
                    text: nil
                )
            }
            await terminalizeApprovalKeyboard(
                chatId: parsed.chatId,
                messageId: parsed.messageId,
                text: resolution.acknowledgement,
                update: update
            )
            if let prompt = resolution.continuationPrompt {
                await deliverApprovalContinuation(
                    prompt: prompt,
                    acknowledgement: resolution.acknowledgement,
                    chatId: parsed.chatId,
                    fromUserId: parsed.fromUserId
                )
            }
        } catch {
            let reply = "Approval update failed: \(Self._tgRedactToken(String(describing: error)))"
            do {
                try await answerCallbackQuery(token, parsed.callbackId, reply)
            } catch {
                await recordError(
                    context: "approval_callback_error_answer",
                    error: String(describing: error),
                    update: update,
                    message: nil,
                    text: nil
                )
            }
            await terminalizeApprovalKeyboard(
                chatId: parsed.chatId,
                messageId: parsed.messageId,
                text: reply,
                update: update
            )
        }
        return true
    }

    private func terminalizeApprovalKeyboard(
        chatId: Int,
        messageId: Int,
        text: String,
        update: TelegramUpdate
    ) async {
        do {
            try await editMessageTextWithReplyMarkup(
                token,
                chatId,
                messageId,
                text,
                TelegramTurnControlCallback.clearedReplyMarkup
            )
        } catch {
            await recordError(
                context: "approval_keyboard_terminalize",
                error: String(describing: error),
                update: update,
                message: nil,
                text: nil
            )
        }
    }

    private func answerApprovalCallback(
        _ callbackId: String,
        text: String,
        context: String,
        update: TelegramUpdate
    ) async {
        do {
            try await answerCallbackQuery(token, callbackId, text)
        } catch {
            await recordError(
                context: context,
                error: String(describing: error),
                update: update,
                message: nil,
                text: nil
            )
        }
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
        guard await turnCoordinator.startTrackedTurn(
            chatId: chatId,
            text: prompt,
            operation: { turnId in
                let card = makeTurnProgressCard(
                    chatId: chatId,
                    turnId: turnId,
                    errorContext: "approval_continuation_card",
                    update: nil,
                    message: nil,
                    text: nil
                )
                guard await turnCoordinator.attachCard(
                    card,
                    chatId: chatId,
                    turnId: turnId
                ) else { return }
                await card.start()
                await card.transition(.working(action: "Continuing after approval"))
                let delivery = makeAssistantDelivery(
                    chatId: chatId,
                    turnId: turnId,
                    errorContext: "approval_assistant_delivery",
                    update: nil,
                    message: nil,
                    text: nil
                )
                let typingTask = await startTypingHeartbeat(chatId: chatId)
                defer { typingTask?.cancel() }
                do {
                    let progress = makeProgressSink(delivery: delivery, card: card)
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
                    let deliveredText = trimmed.isEmpty ? acknowledgement : trimmed
                    switch await delivery.finalize(reply: deliveredText) {
                    case .delivered:
                        await card.transition(.completed(summary: "Reply delivered"))
                    case .failed(let reason):
                        await recordError(
                            context: "send_approval_continuation",
                            error: reason
                        )
                        await card.transition(.failed(reason: "Reply delivery failed: \(reason)"))
                    case .outcomeUnknown(let reason):
                        await recordError(
                            context: "send_approval_continuation_outcome_unknown",
                            error: reason
                        )
                        await card.transition(.outcomeUnknown(
                            reason: "Reply delivery could not be confirmed: \(reason)"
                        ))
                    }
                } catch is CancellationError {
                    await card.transition(.canceled(reason: "Stopped by user"))
                } catch {
                    await card.transition(.failed(reason: String(describing: error)))
                    let safeError = Self._tgRedactToken(String(describing: error))
                    let notice = "\(acknowledgement) NativeAgent could not continue the reply automatically: \(safeError)"
                    if !(await delivery.abortDelivering(notice: notice)) {
                        try? await sendMessage(token, chatId, notice)
                    }
                }
            }
        ) != nil else {
            try? await sendMessage(
                token,
                chatId,
                "\(acknowledgement) A different turn is running; the verified result is saved for the next turn."
            )
            return
        }
    }
}
