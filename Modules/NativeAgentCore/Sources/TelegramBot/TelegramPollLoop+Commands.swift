import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    /// Returns true only when the command transferred ownership of its durable
    /// inbox claim to a tracked turn. Ordinary commands finish synchronously
    /// and let the poll loop settle their claim.
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
            return false
        }

        guard let parsed = TelegramCommandRegistry.parse(text: text) else {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: unsupported slash command \(text)\n".utf8)
            )
            await recordBlocked(reason: "unsupported_slash_command", update: update, message: message, text: text)
            return false
        }

        switch parsed.definition.handler {
        case .stop:
            let outcome = await requestLiveTurnStop(destination: message.destination)
            switch outcome {
            case .confirmed:
                await recordReceipt(
                    kind: "slash_stop_confirmed",
                    update: update,
                    message: message,
                    text: text,
                    reply: "Stopped."
                )
            case .outcomeUnknown:
                await recordReceipt(
                    kind: "slash_stop_outcome_unknown",
                    update: update,
                    message: message,
                    text: text,
                    reply: "I asked it to stop but could not confirm it did — check the Mac app if it keeps going."
                )
            case .notRunning:
                await sendCommandReply(
                    "Nothing is running right now.",
                    kind: "slash_reply",
                    update: update,
                    message: message,
                    text: text
                )
            }
            return false

        case .retry:
            return await handleRetryCommand(update: update, message: message, text: text)

        case .sessions:
            await handleSessionsCommand(update: update, message: message, text: text)
            return false

        case .resume:
            await handleResumeCommand(args: parsed.args, update: update, message: message, text: text)
            return false

        case .status:
            if await refreshLiveTurnCard(destination: message.destination) {
                await recordReceipt(
                    kind: "slash_status_card_refresh",
                    update: update,
                    message: message,
                    text: text,
                    reply: "Refreshed the card above."
                )
            } else {
                let reply = await buildStatusReply(destination: message.destination)
                await sendCommandReply(reply, kind: "slash_reply", update: update, message: message, text: text)
            }
            return false

        case .model where parsed.args.isEmpty:
            await handleModelMenuCommand(parsed: parsed, update: update, message: message, text: text)
            return false

        case .approve, .deny:
            await sendCommandReply(
                "\(parsed.definition.usage) is required.",
                kind: "approval_usage",
                update: update,
                message: message,
                text: text
            )
            return false

        default:
            await handleExistingBotCommand(parsed: parsed, update: update, message: message, text: text)
            return false
        }
    }

    func handleModelSelectionCallback(update: TelegramUpdate, callback: JSONValue) async -> Bool {
        guard let parsed = TelegramModelSelectionCallback(callback) else { return false }
        // Fail-closed perimeter, same contract as the message gate (2026-08-13
        // gpt-5.5 BLOCKING: callbacks dispatched BEFORE the message gate, so an
        // empty allowlist accepted stale/forged inline-button callbacks while
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
                message.destination,
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
                destination: message.destination,
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
                .bindSession(destination: message.destination, requestedSessionId: requested)
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
    ) async -> Bool {
        guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
            await sendCommandReply(
                "I can't run anything here right now — chat isn't wired up on this surface.",
                kind: "retry_unavailable",
                update: update,
                message: message,
                text: text
            )
            return false
        }
        let updateInbox = TelegramUpdateInbox(offsetURL: offsetURL)
        // 2026-09-06: a queued /retry pins the text it resolved to on its
        // durable claim. Restart recovery replays that claim through this
        // handler with an empty in-memory last-message map, so without the
        // pinned text the sender's queued retry answered "nothing to retry"
        // and the claim settled — the request was gone.
        let retryText: String
        if let pinned = await updateInbox.resolvedRetryText(updateId: update.updateId) {
            retryText = pinned
        } else if let last = await turnCoordinator.lastUserMessage(destination: message.destination) {
            retryText = last.text
        } else {
            await sendCommandReply(
                "There's nothing of yours to retry yet.",
                kind: "retry_unavailable",
                update: update,
                message: message,
                text: text
            )
            return false
        }
        let retryOperation: @Sendable (UUID) async -> Void = { turnId in
            // 2026-09-06: the same silent-loss window the chat lane had —
            // `.completed` was written after the transition, before the retry
            // turn ran, so a crash left a claim recovery never reopens. It
            // settles after the reply has been handed off instead. The
            // in-flight mark keeps the every-tick recovery pass off a live
            // turn, and it is taken BEFORE the claim enters `.processing`: a
            // tick landing in the gap saw a `.processing` claim with no owner
            // and quarantined the running retry as outcome-unknown.
            await turnCoordinator.beginUpdateProcessing(update.updateId)
            do {
                let processing = try await updateInbox.transition(
                    updateId: update.updateId,
                    from: [.queued],
                    to: .processing
                )
                guard processing.phase == .processing else {
                    await turnCoordinator.endUpdateProcessing(update.updateId)
                    await recordError(
                        context: "retry_update_start",
                        error: "durable retry claim was \(processing.phase.rawValue)",
                        update: update,
                        message: message,
                        text: text
                    )
                    return
                }
            } catch {
                await turnCoordinator.endUpdateProcessing(update.updateId)
                await recordError(
                    context: "retry_update_start",
                    error: String(describing: error),
                    update: update,
                    message: message,
                    text: text
                )
                return
            }
            await runRetryTurn(
                turnId: turnId,
                update: update,
                message: message,
                commandText: text,
                retryText: retryText
            )
            do {
                _ = try await updateInbox.transition(
                    updateId: update.updateId,
                    from: [.processing],
                    to: .completed
                )
            } catch {
                await recordError(
                    context: "retry_update_complete",
                    error: String(describing: error),
                    update: update,
                    message: message,
                    text: text
                )
            }
            await turnCoordinator.endUpdateProcessing(update.updateId)
        }

        if await turnCoordinator.startTrackedTurn(
            destination: message.destination,
            text: retryText,
            operation: retryOperation
        ) != nil {
            return true
        }

        guard await turnCoordinator.canEnqueue(destination: message.destination) else {
            await sendCommandReply(
                "I'm still working on the last one — send /stop first.",
                kind: "retry_busy",
                update: update,
                message: message,
                text: text
            )
            return false
        }

        do {
            // The resolved text is part of the queue write itself: a crash
            // between two writes used to leave a queued retry with no pinned
            // text, which is the very state recovery cannot resolve.
            let queued = try await updateInbox.transition(
                updateId: update.updateId,
                from: [.processing],
                to: .queued,
                resolvedRetryText: retryText
            )
            guard queued.phase == .queued, queued.resolvedRetryText == retryText else {
                await sendCommandReply(
                    "I couldn't line that retry up safely. Try again once I've finished this one.",
                    kind: "retry_busy",
                    update: update,
                    message: message,
                    text: text
                )
                return false
            }
        } catch {
            await recordError(
                context: "retry_queue_update",
                error: String(describing: error),
                update: update,
                message: message,
                text: text
            )
            return false
        }

        let preview = String(retryText.replacingOccurrences(of: "\n", with: " ").prefix(120))
        var acknowledgementMessageId: Int?
        do {
            let sentMessageId = try await sendMessageWithReplyMarkupReturningId(
                token,
                message.destination,
                "Queued retry · \(preview)",
                TelegramQueuedTurnControlCallback.replyMarkup(updateId: update.updateId)
            )
            acknowledgementMessageId = sentMessageId
            _ = try await updateInbox.recordQueueAcknowledgement(
                updateId: update.updateId,
                messageId: sentMessageId
            )
            await recordReceipt(
                kind: "retry_queued",
                update: update,
                message: message,
                text: text,
                reply: "Queued retry"
            )
        } catch {
            await recordError(
                context: "send_retry_queued_notice",
                error: String(describing: error),
                update: update,
                message: message,
                text: text
            )
        }

        let queued = await turnCoordinator.enqueueTrackedTurn(
            updateId: update.updateId,
            destination: message.destination,
            text: retryText,
            acknowledgementMessageId: acknowledgementMessageId,
            operation: retryOperation,
            onStart: { messageId in
                guard let messageId else { return }
                try? await editMessageTextWithReplyMarkup(
                    token,
                    message.chatId,
                    messageId,
                    "Running retry · \(preview)",
                    TelegramTurnControlCallback.clearedReplyMarkup
                )
            }
        )
        guard queued != nil else {
            _ = try? await updateInbox.transition(
                updateId: update.updateId,
                from: [.queued],
                to: .completed
            )
            return true
        }
        return true
    }

    private func runRetryTurn(
        turnId: UUID,
        update: TelegramUpdate,
        message: TelegramMessage,
        commandText: String,
        retryText: String
    ) async {
        let card = makeTurnProgressCard(
            destination: message.destination,
            turnId: turnId,
            errorContext: "retry_turn_card",
            update: update,
            message: message,
            text: commandText
        )
        guard await turnCoordinator.attachCard(
            card,
            destination: message.destination,
            turnId: turnId
        ) else { return }
        await card.start()
        await card.transition(.working(action: nil))
        await card.transition(.retrying(action: "Taking another run at your last message"))
        let delivery = makeAssistantDelivery(
            destination: message.destination,
            turnId: turnId,
            errorContext: "retry_assistant_delivery",
            update: update,
            message: message,
            text: commandText
        )
        do {
            let typingTask = await startTypingHeartbeat(destination: message.destination)
            defer { typingTask?.cancel() }
            let progress = makeProgressSink(delivery: delivery, card: card)
            let generatedImages = TelegramGeneratedImageCollector()
            let capturingProgress: TelegramChatProgressSink = { event in
                await generatedImages.record(event)
                await progress(event)
            }
            let reply = try await runChatHandlerWithRetry(
                destination: message.destination,
                text: retryText,
                attachments: [],
                progress: capturingProgress,
                replyTo: nil,
                fromUserId: message.fromUserId,
                suppressUserAppend: true
            )
            try Task.checkCancellation()
            if !reply.isEmpty {
                let deliveryOutcome = await delivery.finalize(reply: reply)
                switch deliveryOutcome {
                case .delivered:
                    let imagePaths = await generatedImages.snapshot()
                    switch await deliverGeneratedImages(
                        imagePaths,
                        destination: message.destination,
                        errorContext: "send_generated_image",
                        update: update,
                        message: message,
                        text: commandText
                    ) {
                    case .delivered:
                        await recordReceipt(kind: "retry_reply", update: update, message: message, text: commandText, reply: reply)
                        await card.transition(.completed(summary: nil))
                    case .failed(let reason):
                        await card.transition(.failed(
                            reason: "I sent the reply, but the images did not go through: \(reason)"
                        ))
                    case .outcomeUnknown(let reason):
                        await card.transition(.outcomeUnknown(
                            reason: "I sent the reply; I could not confirm the images went through: \(reason)"
                        ))
                    }
                case .failed(let reason):
                    await recordError(context: "send_retry_reply", error: reason, update: update, message: message, text: commandText)
                    await card.transition(.failed(reason: "I could not send the reply: \(reason)"))
                case .outcomeUnknown(let reason):
                    await recordError(context: "send_retry_reply_outcome_unknown", error: reason, update: update, message: message, text: commandText)
                    await card.transition(.outcomeUnknown(
                        reason: "I could not confirm the reply reached you: \(reason)"
                    ))
                }
            } else {
                let notice = "(the retry came back empty — check the Mac error log)"
                await recordError(context: "empty_retry", error: "chat handler returned empty output", update: update, message: message, text: commandText)
                await card.transition(.failed(reason: "the retry came back empty"))
                await deliverDraftOrSendNotice(
                    notice,
                    delivery: delivery,
                    receiptKind: "empty_retry_notice",
                    sendErrorContext: "send_empty_retry_notice",
                    update: update,
                    message: message,
                    text: commandText
                )
            }
        } catch is CancellationError {
            let notice = "(Stopped.)"
            await card.transition(.canceled(reason: "Stopped by user"))
            if await delivery.abortDelivering(notice: notice) {
                await recordReceipt(kind: "stopped_notice", update: update, message: message, text: commandText, reply: notice)
            } else {
                await recordReceipt(kind: "turn_canceled", update: update, message: message, text: commandText, reply: notice)
            }
        } catch {
            FileHandle.standardError.write(Data("TelegramPollLoop: retry chat handler failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
            await recordError(
                context: "retry_chat_handler",
                error: String(describing: error),
                update: update,
                message: message,
                text: commandText
            )
            await card.transition(.failed(reason: Self.chatErrorNotice(for: error)))
            let notice = Self.chatErrorNotice(for: error)
            if await delivery.abortDelivering(notice: notice) {
                await recordReceipt(kind: "error_notice", update: update, message: message, text: commandText, reply: notice)
            } else {
                do {
                    try await sendMessage(token, message.destination, notice)
                    await recordReceipt(kind: "error_notice", update: update, message: message, text: commandText, reply: notice)
                } catch {
                    await recordError(context: "send_error_notice", error: String(describing: error), update: update, message: message, text: commandText)
                }
            }
        }
    }

    /// One human sentence: what she's doing, which model in plain words,
    /// and whether anything is waiting on User. No flags, no session ids, no
    /// poller internals — those live in receipts and the Mac app, which is
    /// where someone debugging the surface actually looks.
    func buildStatusReply(destination: TelegramDestination) async -> String {
        let turn = await turnCoordinator.snapshot(destination: destination)
        let phase = await turnCoordinator.activeCard(destination: destination)?.snapshot().state.phase
        let waitingOnUser = phase == .blocked

        var sentence: String
        if waitingOnUser {
            sentence = "I'm waiting on an approval from you"
        } else if turn.isRunning {
            if let preview = turn.promptPreview, !preview.isEmpty {
                sentence = "I'm working on \u{201C}\(Self.statusPreview(preview))\u{201D}"
            } else {
                sentence = "I'm working on something for you"
            }
        } else {
            sentence = "I'm idle"
        }

        if let model = await bot.telegramPlainModelPhrase() {
            sentence += ", on \(model)"
        }
        sentence += "."

        if !waitingOnUser {
            sentence += " Nothing is waiting on you."
        }
        return sentence
    }

    /// A short, single-line, token-redacted echo of what she's working on.
    static func statusPreview(_ raw: String) -> String {
        let flattened = _tgRedactToken(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.count <= 60 { return flattened }
        return String(flattened.prefix(60)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The reply send is AWAITED by its command.
    ///
    /// 2026-09-06: this send goes through the per-chat wire lane, which waits
    /// out that chat's flood cooldown before it returns, so running it inline
    /// on the poll loop let one chat told to be quiet for 30s stall the whole
    /// poller. Detaching only the SEND fixed that and broke something worse:
    /// the command returned before its reply had left, so `/restart` armed
    /// termination and the durable claim was completed while the message was
    /// still on the wire — a reply lost with no claim left to replay it. The
    /// whole command now runs off the poll loop instead
    /// (`runSlashCommandDetached`), so the poller stays free AND everything
    /// a command does after its reply happens after the reply is actually out.
    private func sendCommandReply(
        _ reply: String,
        kind: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        do {
            try await sendMessage(token, message.destination, reply)
            await recordReceipt(kind: kind, update: update, message: message, text: text, reply: reply)
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: command reply send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8)
            )
            await recordError(context: "send_command_reply", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    /// Run one slash command in its own task, and settle its durable claim only
    /// once the command (reply included) has finished.
    ///
    /// 2026-09-06: the poll loop no longer waits for a command — a chat in a
    /// flood cooldown holds up nothing but itself — and the claim it would have
    /// completed on the command's behalf travels with the command, the same way
    /// a tracked turn carries its own. A crash mid-command therefore leaves the
    /// claim replayable instead of marked done with nothing sent.
    func runSlashCommandDetached(
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) {
        let loop = self
        Task {
            let transferred = await loop.handleSlashCommand(
                update: update,
                message: message,
                text: text
            )
            // `true` means a tracked turn took the claim; that turn settles it.
            guard !transferred else { return }
            do {
                _ = try await TelegramUpdateInbox(offsetURL: loop.offsetURL).transition(
                    updateId: update.updateId,
                    from: [.processing, .queued],
                    to: .completed
                )
            } catch {
                await loop.recordError(
                    context: "update_inbox_complete",
                    error: String(describing: error),
                    update: update,
                    message: message,
                    text: text
                )
            }
            await loop.turnCoordinator.endUpdateProcessing(update.updateId)
        }
    }
}

// MARK: - Preferences asked for in words

extension TelegramPollLoop {
    /// The retired /model, /think, /fast and /persona spellings, reachable by
    /// saying what you want. Every branch dispatches the SAME command name
    /// and args the slash spelling used, so there is exactly one writer per
    /// preference. Returns nil when the message isn't a preference change —
    /// which is almost always — and the turn runs normally.
    func spokenPreferenceReply(destination: TelegramDestination, text: String) async -> String? {
        guard let intent = TelegramSpokenPreference.parse(
            text: Self.spokenPreferenceSource(text)
        ) else { return nil }

        switch intent {
        case .whichModel:
            guard let model = await bot.telegramPlainModelPhrase() else { return nil }
            return "I'm on \(model)."

        case .model(let query):
            // A spoken model name only counts once it resolves against the
            // live menu; an unmatched phrase is ordinary conversation and
            // must never silently rewrite routing.
            guard let menu = await bot.telegramModelMenuForSurface("telegram"),
                  let match = TelegramSpokenPreference.resolveModel(query: query, in: menu)
            else { return nil }
            guard let reply = await dispatchSpokenPreference(
                "model",
                args: [match.providerId, match.modelId],
                destination: destination
            ) else { return nil }
            if reply.hasPrefix("Failed") { return reply }
            return "Switched to \(match.label) on \(match.providerLabel)."

        case .effort(let effort):
            guard let capabilities = await bot.telegramModelCapabilitiesForSurface(),
                  let level = effort.resolved(supported: capabilities.reasoningEfforts)
            else {
                return "This model doesn't have a thinking dial I can turn."
            }
            guard let reply = await dispatchSpokenPreference(
                "think", args: [level], destination: destination
            ) else { return nil }
            if reply.hasPrefix("Failed") { return reply }
            return "Thinking at \(level) from here on."

        case .fast(let on):
            guard let capabilities = await bot.telegramModelCapabilitiesForSurface(),
                  capabilities.supportsFast
            else {
                return "This model doesn't have a fast lane."
            }
            guard let reply = await dispatchSpokenPreference(
                "fast", args: [on ? "on" : "off"], destination: destination
            ) else { return nil }
            if reply.hasPrefix("Failed") { return reply }
            return on ? "Running fast from here on." : "Back to normal speed."

        case .persona(let name):
            guard let reply = await dispatchSpokenPreference(
                "persona",
                args: name.split(separator: " ").map(String.init),
                destination: destination
            ) else { return nil }
            if reply.hasPrefix("Failed") { return reply }
            return "I'm \(name) here now."
        }
    }

    private func dispatchSpokenPreference(
        _ command: String,
        args: [String],
        destination: TelegramDestination
    ) async -> String? {
        do {
            let outcome = try await bot.dispatchSwiftSlashCommandDetailed(
                command, args: args, destination: destination
            )
            outcome.afterReplySent?()
            return outcome.reply
        } catch {
            return "Failed to change that: \(Self._tgRedactToken(error.localizedDescription))"
        }
    }

    /// Voice notes arrive wrapped in a transcript envelope; a spoken
    /// preference should work the same whether it was typed or said.
    static func spokenPreferenceSource(_ text: String) -> String {
        let marker = "Transcript: "
        guard text.hasPrefix("[Telegram voice message]"),
              let range = text.range(of: marker) else { return text }
        return String(text[range.upperBound...])
    }
}
