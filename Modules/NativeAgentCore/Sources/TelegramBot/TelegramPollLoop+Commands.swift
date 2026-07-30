import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func handleSlashCommand(
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
            return false
        }

        if let approvalCommand = TelegramApprovalCommand.parse(text: text) {
            await handleApprovalSlashCommand(
                approvalCommand,
                update: update,
                message: message,
                text: text
            )
            return true
        }

        guard let parsed = TelegramCommandRegistry.parse(text: text) else {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: unsupported slash command \(text)\n".utf8)
            )
            await recordBlocked(reason: "unsupported_slash_command", update: update, message: message, text: text)
            return true
        }

        switch parsed.definition.handler {
        case .stop:
            let cancelled = await turnCoordinator.cancelTurn(chatId: message.chatId)
            let reply = cancelled
                ? "Stopping the current Telegram turn."
                : "No Telegram turn is running for this chat."
            await sendCommandReply(reply, kind: "slash_reply", update: update, message: message, text: text)
            return true

        case .retry:
            await handleRetryCommand(update: update, message: message, text: text)
            return true

        case .sessions:
            await handleSessionsCommand(update: update, message: message, text: text)
            return true

        case .resume:
            await handleResumeCommand(args: parsed.args, update: update, message: message, text: text)
            return true

        case .status:
            let reply = await buildStatusReply(chatId: message.chatId)
            await sendCommandReply(reply, kind: "slash_reply", update: update, message: message, text: text)
            return true

        case .model where parsed.args.isEmpty:
            await handleModelMenuCommand(parsed: parsed, update: update, message: message, text: text)
            return true

        case .approve, .deny:
            await sendCommandReply(
                "\(parsed.definition.usage) is required.",
                kind: "approval_usage",
                update: update,
                message: message,
                text: text
            )
            return true

        default:
            await handleExistingBotCommand(parsed: parsed, update: update, message: message, text: text)
            return true
        }
    }

    func handleModelSelectionCallback(update: TelegramUpdate, callback: JSONValue) async -> Bool {
        guard let parsed = TelegramModelSelectionCallback(callback) else { return false }
        let hasAllowlist = !allowedChatIds.isEmpty || !allowedUserIds.isEmpty
        if hasAllowlist {
            let chatOk = allowedChatIds.contains(Int64(parsed.chatId))
            let userOk = parsed.fromUserId.map { allowedUserIds.contains(Int64($0)) } ?? false
            guard chatOk || userOk else {
                await recordBlocked(reason: "not_allowlisted", update: update, message: nil, text: nil)
                try? await answerCallbackQuery(token, parsed.callbackId, "This Telegram chat is not allowlisted.")
                return true
            }
        }

        guard let menu = await bot.telegramModelMenuForSurface("telegram") else {
            try? await answerCallbackQuery(token, parsed.callbackId, "Model menu is not available.")
            return true
        }

        switch parsed.action {
        case .providers:
            do {
                try await editMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    TelegramModelSelectionUI.providerText(menu: menu),
                    TelegramModelSelectionUI.providerReplyMarkup(menu: menu)
                )
                try? await answerCallbackQuery(token, parsed.callbackId, "Choose a provider.")
            } catch {
                try? await answerCallbackQuery(token, parsed.callbackId, "Could not update model menu.")
                await recordError(context: "model_menu_callback_edit", error: String(describing: error), update: update, message: nil, text: nil)
            }
            return true

        case .provider(let providerIndex):
            guard let text = TelegramModelSelectionUI.modelText(menu: menu, providerIndex: providerIndex),
                  let markup = TelegramModelSelectionUI.modelReplyMarkup(menu: menu, providerIndex: providerIndex) else {
                try? await answerCallbackQuery(token, parsed.callbackId, "That provider is no longer available.")
                return true
            }
            do {
                try await editMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    text,
                    markup
                )
                try? await answerCallbackQuery(token, parsed.callbackId, "Choose a model.")
            } catch {
                try? await answerCallbackQuery(token, parsed.callbackId, "Could not open model list.")
                await recordError(context: "model_provider_callback_edit", error: String(describing: error), update: update, message: nil, text: nil)
            }
            return true

        case .model(let providerIndex, let modelIndex):
            guard providerIndex >= 0, providerIndex < menu.providers.count else {
                try? await answerCallbackQuery(token, parsed.callbackId, "That provider is no longer available.")
                return true
            }
            let provider = menu.providers[providerIndex]
            guard modelIndex >= 0, modelIndex < provider.models.count else {
                try? await answerCallbackQuery(token, parsed.callbackId, "That model is no longer available.")
                return true
            }
            let model = provider.models[modelIndex]
            do {
                try await bot.saveTelegramModelSelection(
                    surface: "telegram",
                    provider: provider.id,
                    model: model.id
                )
                try await editMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    TelegramModelSelectionUI.selectedText(provider: provider, model: model),
                    TelegramModelSelectionUI.selectedReplyMarkup(providerIndex: providerIndex)
                )
                try? await answerCallbackQuery(token, parsed.callbackId, "Telegram model set to \(model.id).")
            } catch {
                let reply = "Failed to set Telegram model: \(Self._tgRedactToken(String(describing: error)))"
                try? await answerCallbackQuery(token, parsed.callbackId, reply)
                await recordError(context: "model_selection_callback_save", error: String(describing: error), update: update, message: nil, text: nil)
            }
            return true
        }
    }

    private func handleModelMenuCommand(
        parsed: TelegramParsedSlashCommand,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        guard let menu = await bot.telegramModelMenuForSurface("telegram") else {
            await handleExistingBotCommand(
                parsed: parsed,
                update: update,
                message: message,
                text: text
            )
            return
        }
        do {
            try await sendMessageWithReplyMarkup(
                token,
                message.chatId,
                TelegramModelSelectionUI.providerText(menu: menu),
                TelegramModelSelectionUI.providerReplyMarkup(menu: menu)
            )
            await recordReceipt(
                kind: "model_menu",
                update: update,
                message: message,
                text: text,
                reply: "telegram model provider menu"
            )
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: model menu send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8)
            )
            await recordError(context: "send_model_menu", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    private func handleExistingBotCommand(
        parsed: TelegramParsedSlashCommand,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        do {
            let outcome = try await bot.dispatchSwiftSlashCommandDetailed(
                parsed.definition.name,
                args: parsed.args,
                chatId: message.chatId,
                fromUserId: message.fromUserId,
                chatType: message.chatType
            )
            if let reply = outcome.reply {
                await sendCommandReply(reply, kind: "slash_reply", update: update, message: message, text: text)
                outcome.afterReplySent?()
            } else {
                FileHandle.standardError.write(
                    Data("TelegramPollLoop: unhandled slash command \(parsed.rawName)\n".utf8)
                )
                await recordBlocked(reason: "unsupported_slash_command", update: update, message: message, text: text)
            }
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: update \(update.updateId) failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8)
            )
            await recordError(context: "slash_command", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    private func handleSessionsCommand(
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        do {
            let sessions = try await TelegramSessionStore(dataRoot: dataRoot).recentSessions(limit: 8)
            let reply: String
            if sessions.isEmpty {
                reply = "No chat sessions found."
            } else {
                let lines = sessions.map { session -> String in
                    let updated = session.updatedAt.map { ", updated \($0)" } ?? ""
                    return "\(session.id) - \(session.title) (\(session.source), \(session.messageCount) message(s)\(updated))"
                }
                reply = (["Recent sessions:"] + lines + ["Use /resume <id> to bind this Telegram chat."])
                    .joined(separator: "\n")
            }
            await sendCommandReply(reply, kind: "slash_reply", update: update, message: message, text: text)
        } catch {
            await sendCommandReply(
                "Could not list sessions: \(Self._tgRedactToken(String(describing: error)))",
                kind: "slash_error",
                update: update,
                message: message,
                text: text
            )
        }
    }

    private func handleResumeCommand(
        args: [String],
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        let requested = args.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let status = try await TelegramSessionStore(dataRoot: dataRoot)
                .bindSession(chatId: message.chatId, requestedSessionId: requested)
            let reply = """
            Resumed Telegram session: \(status.sessionId)
            Persona: \(status.persona)
            Messages: \(status.messageCount)
            """
            await sendCommandReply(reply, kind: "slash_reply", update: update, message: message, text: text)
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await sendCommandReply(
                "Could not resume session: \(Self._tgRedactToken(description))",
                kind: "slash_error",
                update: update,
                message: message,
                text: text
            )
        }
    }

    private func handleRetryCommand(
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
            await sendCommandReply(
                "Chat handling is not wired on this Telegram surface.",
                kind: "retry_unavailable",
                update: update,
                message: message,
                text: text
            )
            return
        }
        guard let last = await turnCoordinator.lastUserMessage(chatId: message.chatId) else {
            await sendCommandReply(
                "No Telegram user message is available to retry.",
                kind: "retry_unavailable",
                update: update,
                message: message,
                text: text
            )
            return
        }

        guard let started = await turnCoordinator.startTurn(
            chatId: message.chatId,
            text: last.text,
            operation: {
                await runRetryTurn(update: update, message: message, commandText: text, retryText: last.text)
            }
        ) else {
            await sendCommandReply(
                "A Telegram turn is already running for this chat. Use /stop before retrying.",
                kind: "retry_busy",
                update: update,
                message: message,
                text: text
            )
            return
        }
        await started.task.value
        await turnCoordinator.finishTurn(chatId: message.chatId, turnId: started.id)
    }

    private func runRetryTurn(
        update: TelegramUpdate,
        message: TelegramMessage,
        commandText: String,
        retryText: String
    ) async {
        let draft = TelegramDraftStreamer(
            token: token,
            chatId: message.chatId,
            editIntervalSeconds: draftEditIntervalSeconds,
            sendReturningId: sendMessageReturningId,
            editMessage: editMessageText
        )
        do {
            let typingTask = await startTypingHeartbeat(chatId: message.chatId)
            defer { typingTask?.cancel() }
            let progress = makeProgressSink(chatId: message.chatId, draft: draft)
            let generatedImages = TelegramGeneratedImageCollector()
            let capturingProgress: TelegramChatProgressSink = { event in
                await generatedImages.record(event)
                await progress(event)
            }
            let reply = try await runChatHandlerWithRetry(
                chatId: message.chatId,
                text: retryText,
                attachments: [],
                progress: capturingProgress,
                replyTo: nil,
                fromUserId: message.fromUserId,
                suppressUserAppend: true
            )
            try Task.checkCancellation()
            if !reply.isEmpty {
                for chunk in await draft.finalize(reply: reply) {
                    try await sendMessage(token, message.chatId, chunk)
                }
                let imagePaths = await generatedImages.snapshot()
                for imagePath in imagePaths {
                    do {
                        try await sendChatAction(token, message.chatId, "upload_photo")
                        try await sendPhoto(token, message.chatId, imagePath, nil)
                    } catch {
                        FileHandle.standardError.write(Data("TelegramPollLoop: generated image send failed for retry update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                        await recordError(context: "send_generated_image", error: String(describing: error), update: update, message: message, text: commandText)
                    }
                }
                await recordReceipt(kind: "retry_reply", update: update, message: message, text: commandText, reply: reply)
            } else {
                let notice = "(the retry came back empty - check the Mac error log)"
                await recordError(context: "empty_retry", error: "chat handler returned empty output", update: update, message: message, text: commandText)
                await deliverDraftOrSendNotice(
                    notice,
                    draft: draft,
                    receiptKind: "empty_retry_notice",
                    sendErrorContext: "send_empty_retry_notice",
                    update: update,
                    message: message,
                    text: commandText
                )
            }
        } catch is CancellationError {
            let notice = "(Telegram turn stopped.)"
            if await draft.abortDelivering(notice: notice) {
                await recordReceipt(kind: "stopped_notice", update: update, message: message, text: commandText, reply: notice)
            } else {
                do {
                    try await sendMessage(token, message.chatId, notice)
                    await recordReceipt(kind: "stopped_notice", update: update, message: message, text: commandText, reply: notice)
                } catch {
                    await recordError(context: "send_stop_notice", error: String(describing: error), update: update, message: message, text: commandText)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("TelegramPollLoop: retry chat handler failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
            await recordError(context: "retry_chat_handler", error: String(describing: error), update: update, message: message, text: commandText)
            let notice = Self.chatErrorNotice(for: error)
            if await draft.abortDelivering(notice: notice) {
                await recordReceipt(kind: "error_notice", update: update, message: message, text: commandText, reply: notice)
            } else {
                do {
                    try await sendMessage(token, message.chatId, notice)
                    await recordReceipt(kind: "error_notice", update: update, message: message, text: commandText, reply: notice)
                } catch {
                    await recordError(context: "send_error_notice", error: String(describing: error), update: update, message: message, text: commandText)
                }
            }
        }
    }

    private func buildStatusReply(chatId: Int) async -> String {
        var lines: [String] = []
        do {
            let status = try await bot.getStatus()
            let seen = status.lastSeenAt ?? "never"
            lines.append("Telegram: enabled=\(status.enabled ?? false) tokenConfigured=\(status.tokenConfigured ?? false) lastSeenAt=\(seen)")
            lines.append("Runtime: enabled=\(status.enabled ?? false) poller=\(status.pollerEnabled ?? false) token=\(status.tokenConfigured ?? false)")
            lines.append("Last seen: \(seen)")
            if let lastError = status.lastError, !lastError.isEmpty {
                lines.append("Last error: \(Self._tgRedactToken(lastError))")
            }
        } catch {
            lines.append("Runtime: unavailable (\(Self._tgRedactToken(String(describing: error))))")
        }

        do {
            let outcome = try await bot.dispatchSwiftSlashCommandDetailed(
                "model",
                args: [],
                chatId: chatId
            )
            if let model = outcome.reply?.trimmingCharacters(in: .whitespacesAndNewlines),
               !model.isEmpty {
                lines.append("Model: \(model.replacingOccurrences(of: "\n", with: " | "))")
            } else {
                lines.append("Model: not configured")
            }
        } catch {
            lines.append("Model: unavailable")
        }

        do {
            let session = try await TelegramSessionStore(dataRoot: dataRoot).status(chatId: chatId)
            lines.append("Session: \(session.sessionId) (\(session.messageCount) message(s), persona \(session.persona))")
        } catch {
            lines.append("Session: unavailable")
        }

        let turn = await turnCoordinator.snapshot(chatId: chatId)
        if turn.isRunning {
            lines.append("Task: running since \(turn.startedAt ?? "unknown")")
            if let preview = turn.promptPreview, !preview.isEmpty {
                lines.append("Task prompt: \(preview)")
            }
        } else {
            lines.append("Task: idle")
        }
        if let last = turn.lastUserMessagePreview, !last.isEmpty {
            lines.append("Last user message: \(last)")
        }
        return lines.joined(separator: "\n")
    }

    private func sendCommandReply(
        _ reply: String,
        kind: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        do {
            try await sendMessage(token, message.chatId, reply)
            await recordReceipt(kind: kind, update: update, message: message, text: text, reply: reply)
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: command reply send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8)
            )
            await recordError(context: "send_command_reply", error: String(describing: error), update: update, message: message, text: text)
        }
    }
}
