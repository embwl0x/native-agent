import Foundation
import NativeAgentShared
import ChatTurnContracts
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`: `handleControlHandoff`, `clearQueueAcknowledgement`, `handleSlashCommand`; admitted commands/callbacks bind their Telegram surface, verified chat/sender and work identity in TurnEnvelope; Telegram has no command-signature scheme |

extension TelegramPollLoop {
    func handleControlHandoff(update: TelegramUpdate, message: TelegramMessage, text: String,
                              admissionReady: @escaping @Sendable () -> Void) async {
        let (turnId, card) = await turnCoordinator.prepareControlHandoff(destination: message.destination)
        await revokeDriverControl()
        admissionReady()
        let outcome = await requestLiveTurnStop(
            destination: message.destination, turnId: turnId ?? UUID(), pauseQueuedTurns: true
        )
        let activity = await card?.snapshot().state.activities.last(where: { !$0.phase.isTerminal })?.detail
        let reply = UserMessageIntentSignals.controlHandoffReply(lastActivity: activity)
            + (outcome == .outcomeUnknown ? " Turn cancellation is not yet confirmed." : "")
        await sendCommandReply(reply, kind: "control_handoff", update: update, message: message, text: text)
    }

    /// Remove a starting turn's queue acknowledgement, or replace it with runningText if deletion fails.
    func clearQueueAcknowledgement(chatId: Int, messageId: Int, runningText: String) async {
        if (try? await Self.defaultDeleteMessage(token, chatId, messageId)) != nil { return }
        try? await Self.defaultEditMessageTextWithReplyMarkup(
            token,
            chatId,
            messageId,
            runningText,
            TelegramTurnControlCallback.clearedReplyMarkup
        )
    }

    /// Returns true only when the command transferred ownership of its durable
    /// inbox claim to a tracked turn. Ordinary commands finish synchronously
    /// and let the poll loop settle their claim.
    func handleSlashCommand(
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async -> Bool {
        await ChatToolSessionContext.$envelope.withValue(TurnEnvelope(surface: "telegram", verifiedChatId: String(message.chatId),
            verifiedUserId: message.fromUserId.map(String.init), commandSignatureVerified: nil,
            workIdentity: "telegram:command:\(botIdentity):\(update.updateId)")) {
            await handleAdmittedSlashCommand(update: update, message: message, text: text)
        }
    }

    private func handleAdmittedSlashCommand(
        update: TelegramUpdate, message: TelegramMessage, text: String
    ) async -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
            return false
        }

        guard let parsed = TelegramCommandRegistry.parse(text: text) else {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: unsupported slash command \(text)\n".utf8)
            )
            await recordBlocked(reason: "unsupported_slash_command", update: update, message: message, text: text)
            return false
        }

        if let approvalCommand = TelegramApprovalCommand.parse(
            command: parsed, addressedBot: TelegramCommandRegistry.addressedBotUsername(text: text)
        ) {
            await handleApprovalSlashCommand(
                approvalCommand,
                update: update,
                message: message,
                text: text
            )
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
            return await handleRetryCommand(args: parsed.args, update: update, message: message, text: text)

        case .sessions, .resume:
            await handleExistingBotCommand(parsed: parsed, update: update, message: message, text: text)
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
        let authorization = Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds, allowedUserIds: allowedUserIds,
            chatId: parsed.chatId, fromUserId: parsed.fromUserId)
        guard authorization != .allowlistEmpty else {
            await recordBlocked(reason: "allowlist_empty_fail_closed", update: update, message: nil, text: nil)
            try? await answerCallbackQuery(token, parsed.callbackId, "Telegram allowlist is empty — add an approved sender in settings.")
            return true
        }
        guard authorization == .allowed else {
            await recordBlocked(reason: "not_allowlisted", update: update, message: nil, text: nil)
            try? await answerCallbackQuery(token, parsed.callbackId, "This Telegram chat is not allowlisted.")
            return true
        }

        return await ChatToolSessionContext.$envelope.withValue(TurnEnvelope(surface: "telegram", verifiedChatId: String(parsed.chatId),
            verifiedUserId: parsed.fromUserId.map(String.init), commandSignatureVerified: nil,
            workIdentity: "telegram:callback:\(botIdentity):\(parsed.callbackId)")) {
            await dispatchAuthenticatedModelSelection(parsed, update: update)
        }
    }

    private func dispatchAuthenticatedModelSelection(_ parsed: TelegramModelSelectionCallback, update: TelegramUpdate) async -> Bool {
        guard let menu = await bot.telegramModelMenuForSurface("telegram"), let providers = menu.providers else {
            try? await answerCallbackQuery(token, parsed.callbackId, "Model menu is not available.")
            return true
        }

        switch parsed.action {
        case .providers:
            do {
                let presentation = try await bot.modelPickerPresentation("providers", menu: menu)
                try await Self.defaultEditMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    presentation.text,
                    presentation.markup
                )
                try? await answerCallbackQuery(token, parsed.callbackId, "Choose a provider.")
            } catch {
                try? await answerCallbackQuery(token, parsed.callbackId, "Could not update model menu.")
                await recordError(context: "model_menu_callback_edit", error: String(describing: error), update: update, message: nil, text: nil)
            }
            return true

        case .provider(let key):
            let matches = providers.indices.filter {
                TelegramModelSelectionCallback.selectionKey(providers[$0].id) == key
            }
            guard matches.count == 1, let providerIndex = matches.first else {
                try? await answerCallbackQuery(token, parsed.callbackId, "That provider is no longer available.")
                return true
            }
            do {
                let presentation = try await bot.modelPickerPresentation("models", menu: menu, providerId: providers[providerIndex].id)
                try await Self.defaultEditMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    presentation.text,
                    presentation.markup
                )
                try? await answerCallbackQuery(token, parsed.callbackId, "Choose a model.")
            } catch {
                try? await answerCallbackQuery(token, parsed.callbackId, "Could not open model list.")
                await recordError(context: "model_provider_callback_edit", error: String(describing: error), update: update, message: nil, text: nil)
            }
            return true

        case .model(let providerKey, let modelKey):
            let matchingProviders = providers.filter {
                TelegramModelSelectionCallback.selectionKey($0.id) == providerKey
            }
            guard matchingProviders.count == 1, let provider = matchingProviders.first else {
                try? await answerCallbackQuery(token, parsed.callbackId, "That provider is no longer available.")
                return true
            }
            let models = provider.models.filter {
                TelegramModelSelectionCallback.selectionKey($0.id) == modelKey
            }
            guard models.count == 1, let model = models.first else {
                try? await answerCallbackQuery(token, parsed.callbackId, "That model is no longer available.")
                return true
            }
            do {
                let presentation = try await bot.modelPickerPresentation("selected", menu: menu, providerId: provider.id, modelId: model.id)
                try Task.checkCancellation()
                try await bot.saveTelegramModelSelection(
                    surface: "telegram",
                    provider: provider.id,
                    model: model.id
                )
                try await Self.defaultEditMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    presentation.text,
                    presentation.markup
                )
                try? await answerCallbackQuery(token, parsed.callbackId, "Chat model set to \(model.id).")
            } catch {
                let reply = "Failed to set Telegram model: \(TurnSecretRedactor.redactText(String(describing: error)))"
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
        guard let menu = await bot.telegramModelMenuForSurface("telegram"), menu.providers != nil else {
            await handleExistingBotCommand(
                parsed: parsed,
                update: update,
                message: message,
                text: text
            )
            return
        }
        let presentation: (text: String, markup: JSONValue)
        do {
            presentation = try await bot.modelPickerPresentation("providers", menu: menu)
        } catch {
            await recordError(context: "model_menu_part", error: String(describing: error), update: update, message: message, text: text)
            if !Task.isCancelled {
                await sendCommandReply(
                    "Telegram model picker failed: \(TurnTraceRedactor.redactText(error.localizedDescription))",
                    kind: "model_menu_part_failed", update: update, message: message, text: text
                )
            }
            return
        }
        do {
            try await Self.defaultSendMessageWithReplyMarkup(
                token,
                message.destination,
                presentation.text,
                presentation.markup
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
                Data("TelegramPollLoop: model menu send failed for update \(update.updateId): \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8)
            )
            await recordError(context: "send_model_menu", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    private func handleExistingBotCommand(
        parsed: TelegramParsedSlashCommand,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String,
        admissionReady: @Sendable () -> Void = {}
    ) async {
        do {
            let outcome = try await bot.dispatchSwiftSlashCommandDetailed(
                parsed,
                destination: message.destination,
                fromUserId: message.fromUserId,
                chatType: message.chatType
            )
            admissionReady()
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
            admissionReady()
            FileHandle.standardError.write(
                Data("TelegramPollLoop: update \(update.updateId) failed: \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8)
            )
            if parsed.definition.handler == .sessions || parsed.definition.handler == .resume {
                let operation = parsed.definition.handler == .sessions ? "list conversations" : "resume conversation"
                let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                await sendCommandReply("Could not \(operation): \(TurnSecretRedactor.redactText(description))",
                    kind: "slash_error", update: update, message: message, text: text)
            }
            await recordError(context: "slash_command", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    private func handleRetryCommand(
        args: [String],
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async -> Bool {
        let updateInbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        do {
            var pending: TelegramUpdateClaim?
            for claim in try await updateInbox.snapshots().reversed()
                where claim.update.message?.destination == message.destination {
                if await turnCoordinator.isUpdateProcessing(claim.updateId) {
                    if claim.assistantDelivery?.isDelivered == false {
                        pending = claim
                        break
                    }
                    continue
                }
                if try await retainedAssistantDelivery(for: claim)?.isDelivered == false {
                    pending = claim
                    break
                }
            }
            if let saved = pending {
                if await turnCoordinator.isUpdateProcessing(saved.updateId) {
                    await sendCommandReply("I'm still delivering that answer.", kind: "retry_busy", update: update, message: message, text: text)
                } else {
                    try await updateInbox.withAssistantDeliveryLock(updateId: saved.updateId) {
                        let claim = try updateInbox.claim(updateId: saved.updateId)
                        guard let originalMessage = claim.update.message else {
                            throw TelegramUpdateInboxError.malformedClaim("\(claim.updateId).json")
                        }
                        guard let retained = try await retainedAssistantDelivery(for: claim), !retained.isDelivered else { return }
                        let delivery = makeAssistantDelivery(
                            destination: message.destination, turnId: UUID(), errorContext: "retry_saved_reply",
                            update: claim.update, message: originalMessage, text: nil
                        )
                        switch await delivery.finalize(reply: retained.reply, savedDelivery: retained, resendUnknown: args == ["resend"]) {
                        case .held: break
                        case .delivered:
                            if let session = claim.assistantSessionId, let run = claim.assistantRunId {
                                try await settleReplyCheckpoint(sessionId: session, runId: run, verdict: "completed")
                            }
                            _ = try await updateInbox.transition(updateId: claim.updateId,
                                from: [.processing, .completed, .outcomeUnknown, .sentUnconfirmed], to: .completed)
                            await updateInbox.pruneTerminalClaims(dataRoot: dataRoot)
                            await recordReceipt(kind: "retry_reply", update: claim.update, message: originalMessage, text: text, reply: retained.reply)
                            if let cardId = await turnCardRestartRepairer.takeInterruptedCard(chatId: message.chatId) {
                                try await Self.defaultDeleteMessage(token, message.chatId, cardId)
                            }
                        case .failed(let reason), .outcomeUnknown(let reason):
                            await sendCommandReply(reason, kind: "retry_delivery_pending", update: update, message: message, text: text)
                        }
                    }
                }
                return false
            }
            if try await retryApprovalAnswer(args: args, update: update, message: message, text: text) { return false }
        } catch {
            await recordError(context: "retry_saved_reply", error: String(describing: error), update: update)
            await sendCommandReply("I couldn't read the saved answer delivery. Check the Mac error log before retrying.", kind: "retry_unavailable", update: update, message: message, text: text)
            return false
        }
        if args == ["resend"] {
            await sendCommandReply("There's no saved answer waiting to be delivered.", kind: "retry_unavailable", update: update, message: message, text: text)
            return false
        }
        guard attachmentChatHandler != nil else {
            await sendCommandReply(
                "I can't run anything here right now — chat isn't wired up on this surface.",
                kind: "retry_unavailable",
                update: update,
                message: message,
                text: text
            )
            return false
        }
        // Queued retries retain their resolved request across restart.
        let retryText: String
        let retryMessage: TelegramMessage?
        let retryClaim: TelegramUpdateClaim
        do {
            retryClaim = try updateInbox.claim(updateId: update.updateId)
        } catch {
            await recordError(context: "retry_claim_read", error: String(describing: error), update: update)
            return false
        }
        if let pinned = retryClaim.resolvedRetryText {
            retryText = pinned
            retryMessage = retryClaim.resolvedRetryMessage
        } else if let last = await turnCoordinator.lastUserMessage(destination: message.destination) {
            retryText = last.text
            retryMessage = last.message
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
        let sessionId: String
        do {
            if let saved = retryClaim.resolvedSessionId {
                sessionId = saved
            } else {
                sessionId = try await TelegramSessionStore(dataRoot: dataRoot)
                    .activeSessionId(destination: message.destination)
            }
        } catch {
            await recordError(context: "retry_session", error: String(describing: error), update: update)
            return false
        }
        let retryOperation: @Sendable (UUID) async -> Void = { turnId in
            if let messageId = retryClaim.queueAcknowledgementMessageId {
                await clearQueueAcknowledgement(chatId: message.chatId, messageId: messageId,
                    runningText: "Running retry · \(String(retryText.prefix(120)))")
            }
            await runTurn(turnId: turnId, update: update, message: message,
                text: text, sessionId: sessionId) { card in
                await card.transition(.retrying(action: "Taking another run at your last message"))
                let prepared: (text: String, attachments: [TelegramMediaAttachment], receiptKind: String)
                if let retryMessage {
                    prepared = try await prepareIncomingMedia(text: retryText,
                        caption: retryMessage.text ?? Self.caption(from: retryMessage),
                        voice: Self.voiceAttachment(from: retryMessage), media: Self.chatAttachment(from: retryMessage),
                        update: update, message: retryMessage)
                } else { prepared = (retryText, [], "reply") }
                return (prepared.text, prepared.attachments, "retry_reply",
                    TelegramChatAttemptContext(replyTo: retryMessage?.replyTo,
                        fromUserId: retryMessage?.fromUserId ?? message.fromUserId,
                        suppressUserAppend: true, sessionId: sessionId,
                        runId: turnId.uuidString, threadId: message.destination.threadId))
            }
        }

        return await admitTurn(update: update, message: message, text: text,
            input: retryText, sessionId: sessionId, retryInput: (retryText, retryMessage),
            queuedNotice: ("Queued retry", "retry_queued", "send_retry_queued_notice"),
            busyNotice: ("I'm still working on the last one — send /stop first.", "retry_busy", "send_command_reply"),
            queueErrorContext: "retry_queue_update",
            invalidQueueNotice: "I couldn't line that retry up safely. Try again once I've finished this one.",
            runningText: "Running retry · \(String(retryText.prefix(120)))",
            operation: retryOperation) != nil
    }

    /// Durable admission precedes acknowledgement delivery; the send retains its returned identity through settlement.
    func admitTurn(
        id: UUID = UUID(), priority: TaskPriority? = nil,
        update: TelegramUpdate, message: TelegramMessage, text: String, input: String, sessionId: String,
        retryInput: (text: String, message: TelegramMessage?)? = nil,
        queuedNotice: (text: String, kind: String, sendError: String),
        busyNotice: (text: String, kind: String, sendError: String),
        queueErrorContext: String = "queue_update", invalidQueueNotice: String? = nil,
        runningText: String? = nil,
        operation: @escaping @Sendable (UUID) async -> Void
    ) async -> Int? {
        if await turnCoordinator.startTrackedTurn(id: id, destination: message.destination,
            text: input, priority: priority, operation: operation) != nil { return 0 }
        guard await turnCoordinator.canEnqueue(destination: message.destination) else {
            do {
                try await Self.defaultSendMessage(token, message.destination, busyNotice.text)
                await recordReceipt(kind: busyNotice.kind, update: update, message: message, text: text, reply: busyNotice.text)
            } catch {
                await recordError(context: busyNotice.sendError, error: String(describing: error), update: update, message: message, text: text)
            }
            return nil
        }
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        let queued: TelegramUpdateClaim
        do {
            queued = try await inbox.transition(updateId: update.updateId, from: [.processing], to: .queued,
                resolvedRetryText: retryInput?.text, resolvedRetryMessage: retryInput?.message, resolvedSessionId: sessionId)
            guard queued.phase == .queued, retryInput == nil || queued.resolvedRetryText == retryInput?.text else {
                if let invalidQueueNotice {
                    await sendCommandReply(invalidQueueNotice, kind: busyNotice.kind, update: update, message: message, text: text)
                } else {
                    await recordError(context: queueErrorContext, error: "durable queue transition failed", update: update, message: message, text: text)
                }
                return nil
            }
        } catch {
            await recordError(context: queueErrorContext, error: String(describing: error), update: update, message: message, text: text)
            return nil
        }
        let preview = String(input.replacingOccurrences(of: "\n", with: " ").prefix(120))
        let position = await turnCoordinator.enqueueTrackedTurn(turnId: id, updateId: update.updateId,
            destination: message.destination, text: input, acknowledgementMessageId: queued.queueAcknowledgementMessageId,
            operation: operation, onStart: { messageId in
                guard let messageId else { return }
                await clearQueueAcknowledgement(chatId: message.chatId, messageId: messageId,
                    runningText: runningText ?? "Running now · \(preview)")
            })
        guard let position else {
            _ = try? await inbox.transition(updateId: update.updateId, from: [.queued], to: .completed)
            return nil
        }
        if queued.queueAcknowledgementMessageId == nil {
            // Command ownership joins the send while admission releases intake.
            _ = await turnCoordinator.runCommandUntilAdmitted(destination: message.destination) { admitted in
                admitted()
                guard await turnCoordinator.queuedTurn(destination: message.destination, updateId: update.updateId) != nil else { return }
                do {
                    let messageId = try await Self.defaultSendMessageWithReplyMarkupReturningId(token, message.destination,
                        "\(queuedNotice.text) · \(preview)", TelegramQueuedTurnControlCallback.replyMarkup(updateId: update.updateId))
                    await settle {
                        do {
                            _ = try await inbox.recordQueueAcknowledgement(updateId: update.updateId, messageId: messageId)
                            if !(await turnCoordinator.bindQueueAcknowledgement(destination: message.destination,
                                updateId: update.updateId, messageId: messageId)) {
                                await clearQueueAcknowledgement(chatId: message.chatId, messageId: messageId,
                                    runningText: "No longer queued · \(preview)")
                            }
                            await recordReceipt(kind: queuedNotice.kind, update: update, message: message, text: text, reply: queuedNotice.text)
                        } catch {
                            await recordError(context: "queue_acknowledgement_record", error: String(describing: error), update: update, message: message, text: text)
                        }
                    }
                } catch {
                    await recordError(context: queuedNotice.sendError, error: String(describing: error), update: update, message: message, text: text)
                }
            }
        }
        return position
    }

    /// Claim ownership begins before processing and ends after delivery settlement.
    func runTurn(
        turnId: UUID,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String,
        sessionId: String,
        prepare: @Sendable (TelegramTurnProgressCardDriver) async throws -> (
            text: String, attachments: [TelegramMediaAttachment], receiptKind: String,
            context: TelegramChatAttemptContext)?
    ) async -> String? {
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        await turnCoordinator.beginUpdateProcessing(update.updateId)
        do {
            let processing = try await inbox.transition(
                updateId: update.updateId, from: [.queued, .processing], to: .processing,
                assistantRunId: turnId.uuidString, assistantSessionId: sessionId)
            guard processing.phase == .processing else {
                await turnCoordinator.endUpdateProcessing(update.updateId)
                return nil
            }
        } catch {
            await turnCoordinator.endUpdateProcessing(update.updateId)
            await recordError(context: "queued_update_start", error: String(describing: error),
                update: update, message: message, text: text)
            return nil
        }
        let card = await makeTurnProgressCard(destination: message.destination, turnId: turnId,
            errorContext: "turn_card", update: update, message: message, text: text)
        guard await turnCoordinator.attachCard(card, destination: message.destination, turnId: turnId) else {
            _ = try? await inbox.transition(updateId: update.updateId, from: [.processing], to: .outcomeUnknown)
            await turnCoordinator.endUpdateProcessing(update.updateId)
            return nil
        }
        await card.start()
        let delivery = makeAssistantDelivery(destination: message.destination, turnId: turnId,
            errorContext: "send_reply", update: update, message: message, text: text)
        var preparedText: String?
        do {
            guard let prepared = try await prepare(card) else {
                await turnCoordinator.endUpdateProcessing(update.updateId)
                return nil
            }
            preparedText = prepared.text
            await card.transition(.working(action: nil))
            let (reply, imagePaths) = try await runChatHandler(
                destination: message.destination, text: prepared.text, attachments: prepared.attachments,
                progress: makeProgressSink(delivery: delivery, card: card), context: prepared.context)
            try Task.checkCancellation()
            if !reply.isEmpty {
                switch await delivery.finalize(reply: reply, imagePaths: imagePaths) {
                case .held: break
                case .delivered:
                    try await settleReplyCheckpoint(sessionId: sessionId, runId: turnId.uuidString, verdict: "completed")
                    await recordReceipt(kind: prepared.receiptKind, update: update, message: message, text: prepared.text, reply: reply)
                    await card.transition(.completed(summary: "Reply delivered"))
                case .failed(let reason):
                    await recordError(context: "send_reply", error: reason, update: update, message: message, text: text)
                    await card.transition(.failed(reason: "Reply delivery failed: \(reason)"))
                case .outcomeUnknown(let reason):
                    await recordError(context: "send_reply_outcome_unknown", error: reason, update: update, message: message, text: text)
                    await card.transition(.outcomeUnknown(reason: "Reply delivery could not be confirmed: \(reason)"))
                }
            } else {
                await recordError(context: "empty_reply", error: "chat handler returned empty output", update: update, message: message, text: text)
                await card.transition(.failed(reason: "The reply came back empty"))
                await deliverTurnNotice("(the reply came back empty - check the Mac error log)",
                    delivery: delivery, receiptKind: "empty_reply_notice", sendErrorContext: "send_empty_reply_notice",
                    update: update, message: message, text: text)
            }
        } catch is CancellationError {
            await settle {
                await delivery.stop()
                await card.transition(.canceled(reason: "Stopped by user"))
                await recordReceipt(kind: "turn_canceled", update: update, message: message, text: text, reply: "(Telegram turn stopped.)")
            }
        } catch {
            FileHandle.standardError.write(Data("TelegramPollLoop: chat handler failed for update \(update.updateId): \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8))
            await recordError(context: "chat_handler", error: String(describing: error), update: update, message: message, text: text)
            let notice = Self.chatErrorNotice(for: error)
            await card.transition(.failed(reason: notice))
            await deliverTurnNotice(notice, delivery: delivery, receiptKind: "error_notice",
                sendErrorContext: "send_error_notice", update: update, message: message, text: text)
        }
        await settle {
            do {
                let saved = try await retainedAssistantDelivery(for: inbox.claim(updateId: update.updateId))
                let phase = await card.snapshot().state.phase
                _ = try await inbox.transition(updateId: update.updateId, from: [.processing],
                    to: saved == nil && phase == .canceled ? .stopped : saved?.isDelivered == true ? .completed : saved?.outcomeUnknown == true ? .sentUnconfirmed : .outcomeUnknown)
            } catch {
                await recordError(context: "queued_update_complete", error: String(describing: error),
                    update: update, message: message, text: text)
            }
            await turnCoordinator.endUpdateProcessing(update.updateId)
        }
        return preparedText
    }

    /// One human sentence: what she's doing, which model in plain words,
    /// and whether anything is waiting on User. No flags, no session ids, no
    /// poller internals — those live in receipts and the Mac app, which is
    /// where someone debugging the surface actually looks.
    func buildStatusReply(destination: TelegramDestination) async -> String {
        let turn = await turnCoordinator.snapshot(destination: destination)
        let phase = await turnCoordinator.activeCard(destination: destination)?.snapshot().state.phase
        let model = await bot.telegramPlainModelPhrase()
        let approvals = await bot.approvalStatus(destination: destination)
        let input: JSONValue = .object([
            "kind": .string("status"), "waitingOnUser": .bool(phase == .blocked),
            "running": .bool(turn.isRunning),
            "hasPreview": .bool(turn.promptPreview?.isEmpty == false),
            "preview": turn.promptPreview.map { .string(Self.statusPreview($0)) } ?? .null,
            "model": .object(["status": .string(model == nil ? "unavailable" : "available"),
                "phrase": model.map(JSONValue.string) ?? .null]),
            "approvals": approvals
        ])
        let face = await TelegramProgressFace(dataRoot: dataRoot, call: partFace)
        let text = await face.text(input: input, row: "status")
        await face.close()
        return text + (model == nil ? " Next-turn model is unavailable." : "")
            + (approvals.objectValue?["status"] == .string("unavailable")
            ? " Approval status is unavailable; check the pending buttons or Desk in the Mac app." : "")
    }

    /// A short, single-line, token-redacted echo of what she's working on.
    static func statusPreview(_ raw: String) -> String {
        let flattened = TurnTraceRedactor.redactText(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.count <= 60 { return flattened }
        return String(flattened.prefix(60)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Await the per-chat reply send before post-reply work and durable claim settlement.
    func sendCommandReply(
        _ reply: String,
        kind: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        do {
            try await Self.defaultSendMessage(token, message.destination, reply)
            await recordReceipt(kind: kind, update: update, message: message, text: text, reply: reply)
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: command reply send failed for update \(update.updateId): \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8)
            )
            await recordError(context: "send_command_reply", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    /// Run one control command in its own task, and settle its durable claim only
    /// once the command (reply included) has finished.
    func runCommandDetached(
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        let loop = self
        // Ingress waits only for a session binding mutation, never its reply.
        // The poller processes updates in order, so the next turn cannot
        // resolve the old binding while /new or /resume is still committing.
        let isStop = TelegramCommandRegistry.parse(text: text)?.definition.handler == .stop
            || UserMessageIntentSignals.isControlHandoff(text)
        await turnCoordinator.runCommandUntilAdmitted(destination: isStop ? nil : message.destination) { admissionReady in
            let transferred: Bool
            if UserMessageIntentSignals.isControlHandoff(text) {
                await loop.handleControlHandoff(
                    update: update, message: message, text: text, admissionReady: admissionReady
                )
                transferred = false
            } else if let parsed = TelegramCommandRegistry.parse(text: text),
                      parsed.definition.handler == .resume ||
                      parsed.definition.handler == .new ||
                        (parsed.definition.name == "session" && ["new", "reset", "clear"].contains(parsed.args.first?.lowercased() ?? "")) {
                await loop.handleExistingBotCommand(
                    parsed: parsed, update: update, message: message, text: text,
                    admissionReady: admissionReady
                )
                transferred = false
            } else {
                admissionReady()
                transferred = await loop.handleSlashCommand(
                    update: update, message: message, text: text
                )
            }
            // `true` means a tracked turn took the claim; that turn settles it.
            guard !transferred else { return }
            do {
                _ = try await TelegramUpdateInbox(offsetURL: loop.offsetURL, dataRoot: loop.dataRoot).transition(
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
