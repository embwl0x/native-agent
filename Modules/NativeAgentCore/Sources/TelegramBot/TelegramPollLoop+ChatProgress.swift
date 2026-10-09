import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting

private actor TelegramTypingHeartbeat {
    let start: @Sendable () -> Task<Void, Never>
    private var task: Task<Void, Never>?
    private var stopped = false

    init(start: @escaping @Sendable () -> Task<Void, Never>) { self.start = start }

    func setSettled(_ settled: Bool) {
        guard !stopped else { return }
        if settled {
            task?.cancel()
            task = nil
        } else if task == nil {
            task = start()
        }
    }

    func stop() async {
        stopped = true
        let pending = task
        task = nil
        pending?.cancel()
        await pending?.value
    }
}

extension TelegramPollLoop {
    private func startTypingHeartbeat(destination: TelegramDestination) async -> TelegramTypingHeartbeat {
        let token = self.token
        let sendChatAction = self.sendChatAction
        let delay = typingRefreshNanoseconds
        // Presence must never delay starting the actual conversation.
        let heartbeat = TelegramTypingHeartbeat { Task {
            while !Task.isCancelled {
                do {
                    try await sendChatAction(token, destination, "typing")
                } catch {
                    guard !Task.isCancelled else { break }
                    FileHandle.standardError.write(
                        Data("TelegramPollLoop: sendChatAction failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8)
                    )
                }
                guard delay > 0 else { break }
                do { try await Task.sleep(nanoseconds: delay) }
                catch { break }
            }
        } }
        await heartbeat.setSettled(false)
        return heartbeat
    }

    func makeTurnProgressCard(
        destination: TelegramDestination,
        turnId: UUID,
        errorContext: String,
        update: TelegramUpdate?,
        message: TelegramMessage?,
        text: String?
    ) -> TelegramTurnProgressCardDriver {
        TelegramTurnProgressCardDriver(
            token: token,
            destination: destination,
            turnId: turnId,
            minimumEditInterval: turnCardMinimumEditIntervalSeconds,
            heartbeatNanoseconds: turnCardHeartbeatNanoseconds,
            stalledAfter: turnCardStalledAfterSeconds,
            clock: turnCardClock,
            sleeper: turnCardSleeper,
            sendCard: sendMessageWithReplyMarkupReturningId,
            editCard: { token, chatId, messageId, text, replyMarkup in
                try await editMessageTextWithReplyMarkup(
                    token,
                    chatId,
                    messageId,
                    text,
                    replyMarkup
                )
            },
            deleteCard: deleteMessage,
            recordFailure: { redactedError in
                await recordError(
                    context: errorContext,
                    error: redactedError,
                    update: update,
                    message: message,
                    text: text
                )
            },
            persistCard: { record in
                try await turnCardLedger.upsert(record)
            },
            removePersistedCard: { turnId in
                try await turnCardLedger.remove(turnId: turnId)
            }
        )
    }

    func makeAssistantDelivery(
        destination: TelegramDestination,
        turnId: UUID,
        errorContext: String,
        update: TelegramUpdate?,
        message: TelegramMessage?,
        text: String?,
        approvalId: String? = nil
    ) -> TelegramAssistantDeliveryDriver {
        return TelegramAssistantDeliveryDriver(
            token: token,
            destination: destination,
            turnId: turnId,
            sendRichDraft: sendRichMessageDraft,
            sendRichFinal: sendRichMessage,
            richDraftInterval: draftEditIntervalSeconds,
            recordFailure: { redactedError in
                await recordError(
                    context: errorContext,
                    error: redactedError,
                    update: update,
                    message: message,
                    text: text
                )
            },
            persistDelivery: { delivery in
                if let update {
                    try await TelegramUpdateInbox(offsetURL: offsetURL).recordAssistantDelivery(
                        updateId: update.updateId, delivery: delivery
                    )
                } else if let approvalId {
                    guard try await approvalInbox.annotateChatContinuation(
                        approvalId, done: false,
                        assistantDelivery: JSONValue.parse(JSONEncoder().encode(delivery))
                    ) else { throw TelegramBotError.underlying("Approval answer delivery could not be recorded.") }
                } else {
                    throw TelegramBotError.underlying("Assistant answer has no durable delivery owner.")
                }
            },
            sendGeneratedImage: { path in
                do { try await sendChatAction(token, destination, "upload_photo") }
                catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: upload_photo action failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                }
                try await sendPhoto(token, destination, path, nil)
            }
        )
    }

    func makeProgressSink(
        delivery: TelegramAssistantDeliveryDriver? = nil,
        card: TelegramTurnProgressCardDriver
    ) -> TelegramChatProgressSink {
        return { event in
            if case .textDelta(let accumulated) = event {
                await delivery?.onDelta(accumulated)
            }
            await card.record(progress: event)
        }
    }

    func retainedAssistantDelivery(for claim: TelegramUpdateClaim) async throws -> TelegramAssistantDeliveryState? {
        if claim.noRecoverableAnswer { return nil }
        if let delivery = claim.assistantDelivery, delivery.imagePaths != nil { return delivery }
        guard let sessionId = claim.assistantSessionId, let runId = claim.assistantRunId else { return claim.assistantDelivery }
        let saved = try await TelegramSessionStore(dataRoot: dataRoot).savedReply(sessionId: sessionId, runId: runId)
        var delivery = claim.assistantDelivery ?? saved
        if delivery?.imagePaths == nil { delivery?.imagePaths = saved?.imagePaths }
        // No wire attempt can precede the delivery row. This canonical reply
        // survived a stop or restart between model settlement and that handoff.
        return try await TelegramUpdateInbox(offsetURL: offsetURL).recordAssistantDelivery(
            updateId: claim.updateId, delivery: delivery, recovering: true
        )
    }

    func repairInterruptedTurnCardsIfNeeded() async {
        let result = await turnCardRestartRepairer.repairOnce(
            token: token,
            editCard: editMessageTextWithReplyMarkup,
            deleteCard: deleteMessage,
            isActive: { await turnCoordinator.activeTurnIDs().contains($0) }
        )
        for failure in result.failures {
            await recordError(context: "turn_card_restart_repair", error: failure)
        }
    }

    static func progressMessage(for event: TelegramChatProgressEvent) -> String? {
        switch event {
        case .replyTextSettled:
            return nil
        case .status(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .notice(_, let text):
            let trimmed = TelegramTurnPresentationRenderer.userFacingProgress(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .toolResult:
            return nil
        case .textDelta:
            return nil  // native draft preview, never a discrete message
        case .toolUse(let name, let input):
            let lower = name.lowercased()
            switch lower {
            case "read_skill":
                if let skill = progressInputString(input, keys: ["name", "skill", "id"]) {
                    return "Loading skill: \(skill)"
                }
                return "Loading skill"
            default:
                return ToolActivityPresentation.progress(name, args: input?.stringFields ?? [:])
            }
        }
    }

    static func progressInputString(_ input: JSONValue?, keys: [String]) -> String? {
        guard case .object(let obj)? = input else { return nil }
        for key in keys {
            if case .string(let value)? = obj[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    func runChatHandlerWithRetry(
        destination: TelegramDestination,
        text: String,
        attachments: [TelegramMediaAttachment] = [],
        progress: @escaping TelegramChatProgressSink,
        replyTo: TelegramReplyContext? = nil,
        fromUserId: Int? = nil,
        suppressUserAppend: Bool = false,
        sessionId: String? = nil,
        runId: String? = nil
    ) async throws -> String {
        let typing = await startTypingHeartbeat(destination: destination)
        let displayProgress: TelegramChatProgressSink = { event in
            if case .replyTextSettled(let settled) = event {
                await typing.setSettled(settled)
            } else {
                await typing.setSettled(false)
            }
            await progress(event)
        }
        return try await withTaskCancellationHandler {
            do {
                let reply = try await runChatHandlerAttempts(
                    destination: destination, text: text, attachments: attachments,
                    progress: displayProgress, replyTo: replyTo, fromUserId: fromUserId,
                    suppressUserAppend: suppressUserAppend, sessionId: sessionId, runId: runId
                )
                await typing.stop()
                return reply
            } catch {
                await typing.stop()
                throw error
            }
        } onCancel: {
            Task { await typing.stop() }
        }
    }

    private func runChatHandlerAttempts(
        destination: TelegramDestination,
        text: String,
        attachments: [TelegramMediaAttachment],
        progress: @escaping TelegramChatProgressSink,
        replyTo: TelegramReplyContext?,
        fromUserId: Int?,
        suppressUserAppend: Bool,
        sessionId: String?,
        runId: String?
    ) async throws -> String {
        // The retired model/effort/fast/persona commands, said in words.
        // This is the single choke point every non-slash Telegram text turn
        // passes through, so the words reach the preference writers without
        // a round trip through the model. It fires only on an unambiguous
        // whole-message request (and never when an image is attached);
        // everything else falls straight through to the chat handler.
        if attachments.isEmpty,
           let spoken = await spokenPreferenceReply(destination: destination, text: text) {
            return spoken
        }

        let totalAttempts = max(1, chatRetryAttempts + 1)
        var lastError: Error?
        for attempt in 0..<totalAttempts {
            let context = TelegramChatAttemptContext(
                attemptIndex: attempt,
                totalAttempts: totalAttempts,
                replyTo: replyTo,
                fromUserId: fromUserId,
                suppressUserAppend: suppressUserAppend,
                sessionId: sessionId,
                runId: runId,
                threadId: destination.threadId
            )
            do {
                // Prefer the attachment-aware handler when staged images exist
                // (telegram-vision-in) so the bytes reach the model. The
                // attachment handler is also used for plain text when it's the
                // only handler wired.
                if let attachmentChatHandler {
                    return try await attachmentChatHandler(destination.chatId, text, attachments, progress, context)
                }
                // A staged image must NEVER silently fall through to a
                // text-only handler — the model would answer the caption
                // blind, exactly the failure the vision-in port removes
                // (gpt-5.5 review). Tripwire + honest reply instead.
                if !attachments.isEmpty {
                    await emitAttachmentDroppedTrace(
                        kind: "image",
                        reason: "no attachment-capable chat handler wired",
                        chatId: destination.chatId, updateId: 0)
                    return "(I received your image but this bot configuration "
                        + "has no vision-capable handler wired — the image was "
                        + "not processed.)"
                }
                if let progressChatHandler {
                    return try await progressChatHandler(destination.chatId, text, progress, context)
                }
                if let chatHandler {
                    return try await chatHandler(destination.chatId, text)
                }
                throw TelegramBotError.unavailable
            } catch {
                lastError = error
                guard attempt + 1 < totalAttempts, Self.isRetryableChatHandlerError(error) else {
                    throw error
                }
                FileHandle.standardError.write(
                    Data("TelegramPollLoop: retrying chat handler after transient failure: \(Self._tgRedactToken(String(describing: error)))\n".utf8)
                )
                await progress(.status(text: "Still can't reach the model — trying again."))
                await writeStatePatch([
                    "lastChatRetryAt": .string(_tgNowString()),
                    "lastChatRetryFailedAttempt": .int(Int64(attempt + 1)),
                    "lastChatRetryNextAttempt": .int(Int64(attempt + 2)),
                    "lastChatRetrySuppressUserAppend": .bool(true),
                    "lastChatRetryError": .string(Self._tgRedactToken(String(describing: error))),
                ])
                // A3.4: honor a provider Retry-After when the failure carried
                // one (the typed failure carries the delay). Wait
                // max(ladder backoff, Retry-After) so we neither hammer a 429
                // before its window nor shorten the ladder's own floor.
                let delayNanos = max(
                    chatRetryDelayNanoseconds,
                    Self.retryAfterNanoseconds(for: error)
                )
                if delayNanos > 0 {
                    try await Task.sleep(nanoseconds: delayNanos)
                }
            }
        }
        throw lastError ?? TelegramBotError.unavailable
    }

    static func retryAfterNanoseconds(for error: Error) -> UInt64 {
        UInt64(min(ProviderRecoveryPolicy.retryAfterSeconds(in: error) ?? 0, 300)) * 1_000_000_000
    }

    static func isRetryableChatHandlerError(_ error: Error) -> Bool {
        ProviderRecoveryPolicy.permitsWholeTurnRetry(error)
    }

    static func chatErrorNotice(for error: Error) -> String {
        ProviderRecoveryPolicy.personMessage(error)
            ?? "The reply could not be completed; try again."
    }

    static func providerUsageNotice(for error: Error) -> String? {
        guard case .rateLimited = ProviderFailure.classify(error) else { return nil }
        return ProviderFailure.classify(error)?.errorDescription
    }
}
