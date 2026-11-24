import SenseCore
import Foundation
import NativeAgentShared
import MacNerves
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import MindCore

// Blueprint: | `TelegramPollLoop+Updates.swift` | `TelegramPollLoop`: one claimed update's stages from durable claim to settlement: `processUpdate` (claim, offset, processing, completion), `routeUpdate` (card buttons, then the message), `readIncomingMessage` (sender, mention and attachment admission), `routeCommand`, `startChatTurn` (pinned session, Stop, tracked turn) |

extension TelegramPollLoop {
    /// A tick stage's signal: `proceed` hands its value to the tick; `end` ends the tick with that outcome.
    enum TickStep<Value> {
        case proceed(Value)
        case end(LoopTickOutcome)
    }

    /// Where routing one update in processing came to rest.
    enum UpdateRouting {
        /// Routing is done; `completeClaim` false leaves the claim to the owner that took it (a detached command, an approval, a turn).
        case rested(completeClaim: Bool)
        /// On to the next update with nothing more for this one.
        case nextUpdate
        /// The tick ends with this outcome.
        case end(LoopTickOutcome)
    }

    /// One update: claim it durably, pass what is settled or owned, advance the offset, enter processing, route, then settle the claim.
    /// nil goes on to the next update; an outcome ends the tick.
    func processUpdate(_ candidateUpdate: TelegramUpdate, updateInbox: TelegramUpdateInbox, cursor: TelegramOffsetCursor,
                       persistedOffset: inout Int) async -> LoopTickOutcome? {
        let claim: TelegramUpdateClaim
        do {
            claim = try await updateInbox.ensurePending(candidateUpdate)
        } catch {
            await recordError(context: "update_inbox_claim", error: String(describing: error), update: candidateUpdate)
            return .failed(error: "Telegram update \(candidateUpdate.updateId) could not be claimed durably")
        }
        // The bytes already admitted to disk are canonical for this update id. Never process a later transport representation instead.
        let update = claim.update
        switch claim.phase {
        case .completed, .outcomeUnknown, .sentUnconfirmed, .failedBeforeAnswer, .quarantined, .stopped:
            return nil
        case .awaitingSpeechPermission:
            return nil
        case .processing:
            // Recovery leaves claims owned by live in-process turns in .processing.
            if await turnCoordinator.isUpdateProcessing(claim.updateId) {
                return nil
            }
            // Same-process ticks are single-flight, so this can only be an unexpected persisted ambiguity. Never duplicate effects.
            do {
                _ = try await updateInbox.transition(updateId: update.updateId, from: [.processing], to: .outcomeUnknown)
            } catch {
                await recordError(context: "update_inbox_unknown", error: String(describing: error), update: update)
                return .failed(error: "Telegram could not retain the uncertain update: \(error)")
            }
            return nil
        case .pending:
            break
        }
        await recordSeen(update: update)
        guard let updateOffset = update.nextOffset else {
            return .failed(error: "Telegram update ID has no representable successor")
        }
        if updateOffset > persistedOffset {
            guard let advanced = await persistOffset(updateOffset, cursor: cursor) else {
                return .failed(error: "Telegram update \(update.updateId) was claimed but its offset could not be persisted")
            }
            persistedOffset = advanced
        }
        if claim.phase == .pending {
            // Register the live owner before entering .processing, including media preparation.
            await turnCoordinator.beginUpdateProcessing(update.updateId)
            do {
                let processing = try await updateInbox.transition(
                    updateId: update.updateId,
                    from: [.pending],
                    to: .processing
                )
                guard processing.phase == .processing else {
                    await turnCoordinator.endUpdateProcessing(update.updateId)
                    return .failed(error: "Telegram update \(update.updateId) could not enter processing")
                }
            } catch {
                await turnCoordinator.endUpdateProcessing(update.updateId)
                await recordError(context: "update_inbox_processing", error: String(describing: error), update: update)
                return .failed(error: "Telegram update \(update.updateId) could not enter processing")
            }
        }

        let shouldCompleteClaim: Bool
        switch await routeUpdate(update, claim: claim, updateInbox: updateInbox) {
        case .rested(let completeClaim): shouldCompleteClaim = completeClaim
        case .nextUpdate: return nil
        case .end(let outcome): return outcome
        }
        guard shouldCompleteClaim else { return nil }
        await turnCoordinator.endUpdateProcessing(update.updateId)
        do {
            let completed = try await updateInbox.transition(
                updateId: update.updateId,
                from: [.processing],
                to: .completed
            )
            guard completed.phase == .completed else {
                return .failed(error: "Telegram update \(update.updateId) could not be settled")
            }
        } catch {
            await recordError(context: "update_inbox_complete", error: String(describing: error), update: update)
            return .failed(error: "Telegram update \(update.updateId) completed but its durable claim could not settle")
        }
        return nil
    }

    /// Route one update in processing: card buttons first, then the message: its words, a command, a handoff, or a chat turn.
    private func routeUpdate(_ update: TelegramUpdate, claim: TelegramUpdateClaim,
                             updateInbox: TelegramUpdateInbox) async -> UpdateRouting {
        if let callback = update.callbackQuery,
           await handleTurnControlCallback(update: update, callback: callback) {
            return .rested(completeClaim: true)
        }
        if let callback = update.callbackQuery,
           await handleModelSelectionCallback(update: update, callback: callback) {
            return .rested(completeClaim: true)
        }
        if let callback = update.callbackQuery,
           await handleApprovalCallback(update: update, callback: callback) {
            return .rested(completeClaim: false)
        }
        // A button no handler reads any more (one sent before its card changed shape) is answered in words, never left spinning.
        if let id = update.callbackQuery?.objectValue?["id"]?.stringValue {
            await answerRecordedCallback(id, text: "This button no longer does anything; answer the card in the Inbox on the Mac or the phone.",
                context: "unread_callback_answer", update: update)
            return .rested(completeClaim: true)
        }
        guard let msg = update.message else {
            await recordBlocked(reason: "no_message", update: update, message: nil, text: nil)
            return .rested(completeClaim: true)
        }
        let admitted: IncomingMessage?
        do {
            admitted = try await readIncomingMessage(update: update, msg: msg)
        } catch {
            return await retainPendingBotIdentity(update: update, updateInbox: updateInbox)
        }
        guard let incoming = admitted else { return .rested(completeClaim: true) }
        let (textFromMessage, voiceAttachment, mediaAttachment, unsupportedAttachmentKind, text) = incoming
        if let routed = await routeCommand(update: update, msg: msg, text: text, updateInbox: updateInbox) { return routed }
        guard attachmentChatHandler != nil else {
            await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: text)
            return .rested(completeClaim: true)
        }
        var handoffText = text
        if text.contains("@"), let username = await resolveBotUsername() {
            handoffText = text.split(whereSeparator: { $0.isWhitespace })
                .filter { String($0).compare("@\(username)", options: .caseInsensitive) != .orderedSame }
                .joined(separator: " ")
        }
        if UserMessageIntentSignals.isControlHandoff(handoffText) {
            await runCommandDetached(update: update, message: msg, text: handoffText)
            return .rested(completeClaim: false)
        }
        if let unsupportedAttachmentKind {
            // A supported text caption still follows its original route; the notice makes clear that its attached file was not read.
            await notifyUnsupportedAttachment(kind: unsupportedAttachmentKind, update: update, message: msg)
        }
        return await startChatTurn(update: update, claim: claim, msg: msg, textFromMessage: textFromMessage,
            voiceAttachment: voiceAttachment, mediaAttachment: mediaAttachment, text: text, handoffText: handoffText,
            updateInbox: updateInbox)
    }

    private typealias IncomingMessage = (textFromMessage: String?, voiceAttachment: TelegramMediaAttachment?,
        mediaAttachment: TelegramMediaAttachment?, unsupportedAttachmentKind: String?, text: String)

    private struct BotIdentityUnavailable: Error {}

    /// Admit readable words and attachments from an allowlisted sender, after verifying any required group mention.
    private func readIncomingMessage(update: TelegramUpdate, msg: TelegramMessage) async throws(BotIdentityUnavailable)
        -> IncomingMessage? {
        // Media-only prompts live in caption; prefer explicit text when the message carries both.
        let captionText = Self.caption(from: msg)
        let textFromMessage = (msg.text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? captionText
        let voiceAttachment = Self.voiceAttachment(from: msg)
        let mediaAttachment = Self.chatAttachment(from: msg)
        let unsupportedAttachmentKind = Self.unsupportedAttachmentKind(from: msg)
        guard textFromMessage?.isEmpty == false
                || voiceAttachment != nil
                || mediaAttachment != nil
                || unsupportedAttachmentKind != nil else {
            await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
            return nil
        }
        // Authorize before slash dispatch: chat OR sender must be allowlisted; empty lists fail closed.
        switch Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds,
            allowedUserIds: allowedUserIds,
            chatId: msg.chatId,
            fromUserId: msg.fromUserId
        ) {
        case .allowlistEmpty:
            FileHandle.standardError.write(Data("""
                TelegramPollLoop: dropping update \(update.updateId) — allowlist is EMPTY (fail-closed); add an approved \
                sender/group in Telegram settings\n
                """.utf8))
            await recordBlocked(reason: "allowlist_empty_fail_closed", update: update, message: msg, text: textFromMessage)
            return nil
        case .notAllowlisted:
            FileHandle.standardError.write(Data("""
                TelegramPollLoop: dropping update \(update.updateId) — chat_id \(msg.chatId) / from \(msg.fromUserId ?? 0) not \
                allowlisted\n
                """.utf8))
            await recordBlocked(reason: "not_allowlisted", update: update, message: msg, text: textFromMessage)
            return nil
        case .allowed:
            break
        }
        // Mention offsets refer to the wire text, never a transcript. Gate ordinary group traffic before downloading or acknowledging media.
        let mentionText = msg.text ?? {
            guard case .object(let extras)? = msg.extras else { return "" }
            return extras["caption"]?.stringValue ?? ""
        }()
        let mentionEntities: JSONValue? = {
            guard case .object(let extras)? = msg.extras else { return nil }
            return extras[msg.text == nil ? "caption_entities" : "entities"]
        }()
        if requireMention, msg.chatId < 0,
           voiceAttachment != nil || !mentionText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            let mentions = Self.mentionedUsernames(in: mentionText, entities: mentionEntities)
            let botUsername = mentions.isEmpty ? nil : await resolveBotUsername()
            if !mentions.isEmpty, botUsername == nil { throw BotIdentityUnavailable() }
            guard let botUsername, mentions.contains(botUsername.lowercased()) else {
                await recordBlocked(reason: "mention_required", update: update, message: msg, text: textFromMessage)
                return nil
            }
        }
        if let unsupportedAttachmentKind,
           textFromMessage?.isEmpty != false, voiceAttachment == nil, mediaAttachment == nil {
            // Admitted senders need truthful attachment evidence; never reply to outsiders or unmentioned groups, or invent attachment text.
            await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
            if !Self.dropsForMissingMention(requireMention: requireMention, chatId: msg.chatId, text: "") {
                await notifyUnsupportedAttachment(kind: unsupportedAttachmentKind, update: update, message: msg)
            }
            return nil
        }
        let text: String
        if voiceAttachment != nil, voiceTranscriber != nil {
            text = "[Telegram voice message]" + (textFromMessage.map { "\n" + $0 } ?? "")
        } else if let existing = textFromMessage, !existing.isEmpty {
            text = existing
        } else if voiceAttachment != nil {
            let notice = "(I got your voice note, but Telegram voice transcription is not configured.)"
            do {
                try await Self.defaultSendMessage(token, msg.destination, notice)
                await recordReceipt(kind: "voice_transcription_unavailable", update: update, message: msg, text: "[Telegram voice message]", reply: notice)
            } catch {
                await recordError(context: "send_voice_unavailable_notice", error: String(describing: error), update: update, message: msg, text: nil)
            }
            return nil
        } else if let mediaAttachment {
            text = mediaAttachment.chatTypeAndMime?.type == "file"
                ? "[The user sent a file with no caption. Read it and respond.]"
                : "[The user sent an image with no caption. Look at it and respond.]"
        } else {
            await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
            return nil
        }
        return (textFromMessage, voiceAttachment, mediaAttachment, unsupportedAttachmentKind, text)
    }

    /// A slash command for this bot runs detached and owns its reply and claim; nil when the text is no command.
    private func routeCommand(update: TelegramUpdate, msg: TelegramMessage, text: String,
                              updateInbox: TelegramUpdateInbox) async -> UpdateRouting? {
        if text.hasPrefix("/"), msg.chatId < 0 || TelegramCommandRegistry.parse(text: text) != nil {
            // Accept bare commands or a verified @ThisBot suffix before applying the mention filter.
            if let addressedBot = TelegramCommandRegistry.addressedBotUsername(text: text) {
                guard let ownUsername = await resolveBotUsername() else {
                    return await retainPendingBotIdentity(update: update, updateInbox: updateInbox)
                }
                if addressedBot.compare(ownUsername, options: .caseInsensitive) != .orderedSame {
                    await recordBlocked(
                        reason: "command_for_other_bot",
                        update: update,
                        message: msg,
                        text: text
                    )
                    return .rested(completeClaim: true)
                }
            }
            // The tracked command task owns its reply and claim settlement, leaving polling free.
            await runCommandDetached(update: update, message: msg, text: text)
            return .rested(completeClaim: false)
        }
        return nil
    }

    private func retainPendingBotIdentity(update: TelegramUpdate, updateInbox: TelegramUpdateInbox) async -> UpdateRouting {
        let failure = "Telegram update \(update.updateId) could not be retained pending bot identity"
        do {
            let pending = try await updateInbox.transition(updateId: update.updateId, from: [.processing], to: .pending)
            await turnCoordinator.endUpdateProcessing(update.updateId)
            return pending.phase == .pending ? .rested(completeClaim: false) : .end(.failed(error: failure))
        } catch {
            await turnCoordinator.endUpdateProcessing(update.updateId)
            await recordError(context: "bot_identity_pending", error: String(describing: error), update: update)
            return .end(.failed(error: failure))
        }
    }

    /// Pin the session, register Stop and start the tracked turn; from here the turn's own work owns the claim.
    private func startChatTurn(update: TelegramUpdate, claim: TelegramUpdateClaim, msg: TelegramMessage, textFromMessage: String?,
                               voiceAttachment: TelegramMediaAttachment?, mediaAttachment: TelegramMediaAttachment?,
                               text: String, handoffText: String, updateInbox: TelegramUpdateInbox) async -> UpdateRouting {
        // Pin before media work and queue waits so later /new or /resume cannot redirect the message while polling admits controls.
        let turnSessionId: String
        do {
            if let saved = claim.resolvedSessionId {
                turnSessionId = saved
            } else {
                turnSessionId = try await TelegramSessionStore(dataRoot: dataRoot)
                    .activeSessionId(destination: msg.destination)
            }
        } catch {
            await recordError(context: "turn_session", error: String(describing: error), update: update, message: msg, text: text)
            let notice = Self.chatErrorNotice(for: error)
            do {
                try await Self.defaultSendMessage(token, msg.destination, notice)
                await recordReceipt(kind: "error_notice", update: update, message: msg, text: text, reply: notice)
            } catch {
                await recordError(context: "send_session_error_notice", error: String(describing: error), update: update, message: msg, text: text)
            }
            return .rested(completeClaim: true)
        }
        // A replayed claim keeps the run it waited under, so a row the agent's turn already saved stays the one row.
        let queuedTurnId = claim.assistantRunId.flatMap(UUID.init(uuidString:)) ?? UUID()
        // Register Stop before awaiting: it must identify this run while queued or running, through the turn operation's settlement.
        let traceTurnId = TurnTraceContext.mintTurnId()
        let runStop = TelegramRunStop(ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: turnSessionId,
                                                            runId: queuedTurnId.uuidString, turnId: traceTurnId))
        // Capture the person's conversation before queueing a takeover.
        let takeover = await MacWorkContinuation.admit(handoffText)
        var takenOver = telegramTurn(message: msg, session: turnSessionId, run: queuedTurnId.uuidString,
            id: traceTurnId).with(\.macContinuation, takeover)
        // Both readers carry the takeover: the prompt reads the envelope, MacControl reads the turn.
        if let takeover { takenOver.envelope = takenOver.envelope?.withMacContinuation(takeover) }
        let turn = takenOver
        let signalArrival: @Sendable (String, String) -> Void = { turnId, text in
            var arrived: [String: JSONValue] = ["text": .string(text), "chat_id": .int(Int64(msg.chatId)),
                "user_id": msg.fromUserId.map { .int(Int64($0)) } ?? .null,
                "session_id": .string(turnSessionId), "turn_id": .string(turnId)]
            // A sender the owner did not allowlist by user speaks as a stranger.
            if msg.fromUserId.map({ !allowedUserIds.contains(Int64($0)) }) ?? true {
                arrived["agent"] = .string("telegram:" + (msg.fromUserId.map(String.init) ?? "unknown"))
            }
            AbilityStore(dataRoot: dataRoot).signal("message.arrived:telegram", arrived)
        }
        let turnBody: @Sendable (UUID) async -> Void = { turnId in
            let preparedText = await runTurn(turnId: turnId, turn: turn, update: update, message: msg,
                text: text, sessionId: turnSessionId) { card in
                await card.transition(.working(action: voiceAttachment != nil
                    ? "Transcribing voice message" : mediaAttachment != nil ? "Preparing attachment" : nil))
                let prepared: (text: String, attachments: [TelegramMediaAttachment], receiptKind: String)
                do {
                    prepared = try await prepareIncomingMedia(text: text, caption: textFromMessage,
                        voice: voiceAttachment, media: mediaAttachment, update: update, message: msg, turn: turn)
                    try Task.checkCancellation()
                } catch {
                    // No chat turn has started: shutdown may release media for recovery, while an explicit Stop remains terminal.
                    let canceled = Task.isCancelled || error is CancellationError
                    if !canceled, Self.isSpeechPermissionDenial(error) {
                        await retainForSpeechPermission(error: error, card: card, update: update, message: msg, text: text)
                        return nil
                    }
                    let shuttingDown = await turnCoordinator.shutdownInterruptedTurn(destination: msg.destination, turnId: turnId)
                    let retryAfterShutdown = canceled && shuttingDown && !runStop.isRaised
                        && (voiceAttachment != nil || mediaAttachment != nil)
                    let stopReadFailure = runStop.readFailure
                    await settle {
                        // The notice is the one message the person gets; the card goes with it once it is sent.
                        var noticeSent = false
                        if !canceled {
                            let notice = voiceAttachment != nil ? Self.voiceTranscriptionNotice(for: error) : Self.attachmentDroppedNotice(for: error)
                            do {
                                try await Self.defaultSendMessage(token, msg.destination, notice)
                                noticeSent = true
                                await recordReceipt(kind: "media_error", update: update, message: msg, text: text, reply: notice)
                            } catch {
                                await recordError(context: "send_media_error_notice", error: String(describing: error),
                                    update: update, message: msg, text: text)
                            }
                        }
                        await card.transition(canceled ? .canceled(reason: retryAfterShutdown
                            ? "Interrupted by shutdown; message saved for retry" : stopReadFailure ?? "Stopped by user")
                            : noticeSent ? .completed(summary: nil) : .failed(reason: Self.chatErrorNotice(for: error)))
                        if !retryAfterShutdown {
                            await recordError(context: "media_preparation", error: stopReadFailure ?? String(describing: error),
                                update: update, message: msg, text: text)
                        }
                        do {
                            _ = try await updateInbox.transition(updateId: update.updateId, from: [.processing],
                                to: retryAfterShutdown ? .pending : canceled ? .stopped : .completed,
                                resolvedSessionId: retryAfterShutdown ? turnSessionId : nil)
                        } catch {
                            await recordError(context: "media_preparation_settlement", error: String(describing: error),
                                update: update, message: msg, text: text)
                        }
                    }
                    return nil
                }
                await turnCoordinator.recordLastUserMessage(destination: msg.destination, text: prepared.text, message: msg,
                    sessionId: turnSessionId, updatingCurrent: true)
                return (prepared.text, prepared.attachments, prepared.receiptKind,
                    TelegramChatAttemptContext(turn: turn, replyTo: msg.replyTo, fromUserId: msg.fromUserId,
                        threadId: msg.destination.threadId))
            }
            if let preparedText { signalArrival(turnId.uuidString, preparedText) }
        }
        let turnOperation: @Sendable (UUID) async -> Void = { turnId in
            await TurnTraceContext.$turnId.withValue(turn.id) {
                await turnBody(turnId)
            }
            withExtendedLifetime(runStop) {}
        }
        await turnCoordinator.recordLastUserMessage(destination: msg.destination, text: text, message: msg, sessionId: turnSessionId)
        guard await turnCoordinator.startTrackedTurn(id: queuedTurnId, destination: msg.destination, text: text,
            priority: .userInitiated, operation: turnOperation) else {
            // Intake is stopping: the update waits for recovery instead of settling unanswered.
            await turnCoordinator.endUpdateProcessing(update.updateId)
            do { _ = try await updateInbox.transition(updateId: update.updateId, from: [.processing], to: .pending) }
            catch { await recordError(context: "update_inbox_shutdown_hold", error: String(describing: error), update: update) }
            return .nextUpdate
        }
        return .rested(completeClaim: false)
    }
}
