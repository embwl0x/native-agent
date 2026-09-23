import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension TelegramPollLoop {
    func startTypingHeartbeat(destination: TelegramDestination) async -> Task<Void, Never>? {
        let token = self.token
        let sendChatAction = self.sendChatAction
        let delay = typingRefreshNanoseconds
        // Presence must never delay starting the actual conversation.
        return Task {
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
        }
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
        text: String?
    ) -> TelegramAssistantDeliveryDriver {
        let ordinary = TelegramDraftStreamer(
            token: token,
            destination: destination,
            editIntervalSeconds: draftEditIntervalSeconds,
            sendReturningId: sendMessageReturningId,
            editMessage: editMessageText
        )
        return TelegramAssistantDeliveryDriver(
            token: token,
            destination: destination,
            turnId: turnId,
            ordinary: ordinary,
            sendOrdinary: sendMessage,
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

    func repairInterruptedTurnCardsIfNeeded() async {
        let result = await turnCardRestartRepairer.repairOnce(
            token: token,
            editCard: editMessageTextWithReplyMarkup,
            deleteCard: deleteMessage
        )
        for failure in result.failures {
            await recordError(context: "turn_card_restart_repair", error: failure)
        }
    }

    func deliverGeneratedImages(
        _ imagePaths: [String],
        destination: TelegramDestination,
        errorContext: String,
        update: TelegramUpdate?,
        message: TelegramMessage?,
        text: String?
    ) async -> TelegramAssistantDeliveryOutcome {
        for imagePath in imagePaths {
            do {
                try await sendChatAction(token, destination, "upload_photo")
            } catch {
                // Native action is only a secondary status signal. Its failure
                // does not change the photo's delivery truth.
                FileHandle.standardError.write(Data(
                    "TelegramPollLoop: upload_photo action failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8
                ))
            }
            do {
                try await sendPhoto(token, destination, imagePath, nil)
            } catch {
                let reason = TelegramTurnPresentationReducer.sanitized(String(describing: error))
                    ?? "generated media delivery failed"
                await recordError(
                    context: errorContext,
                    error: reason,
                    update: update,
                    message: message,
                    text: text
                )
                if TelegramTurnReplyDeliveryFailure.isAmbiguous(error) {
                    return .outcomeUnknown(reason: reason)
                }
                return .failed(reason: reason)
            }
        }
        return .delivered(messageId: nil)
    }

    static func progressMessage(for event: TelegramChatProgressEvent) -> String? {
        switch event {
        case .status(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .notice(_, let text):
            let trimmed = TelegramTurnPresentationRenderer.userFacingProgress(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .toolResult:
            return nil
        case .textDelta:
            return nil  // draft-streamer lane, never a discrete message
        case .toolUse(let name, let input):
            let lower = name.lowercased()
            switch lower {
            case "read_skill":
                if let skill = progressInputString(input, keys: ["name", "skill", "id"]) {
                    return "Loading skill: \(skill)"
                }
                return "Loading skill"
            case "list_skills":
                return "Checking skills"
            case "tool_load":
                if let tool = progressInputString(input, keys: ["name", "tool", "id"]) {
                    return "Loading tool: \(tool)"
                }
                return "Loading tool"
            case "tool_catalog", "list_tools":
                return "Checking tools"
            case "git_log":
                return "Checking recent commits"
            case "git_status":
                return "Checking repo status"
            case "git_diff":
                return "Checking repo diff"
            case "repo_dirty_summary":
                return "Checking repo state"
            case "read_file", "file_excerpt":
                return "Reading file"
            case "list_dir":
                return "Listing folder"
            case "recall_memory", "recall_search":
                return "Searching memory"
            case "claude_message", "invoke_claude", "codex_message", "invoke_codex", "omp_message", "agent_swarm":
                return "Starting background work"
            case "search_kg":
                return "Searching knowledge graph"
            default:
                return "Using tool: \(name)"
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
        sessionId: String? = nil
    ) async throws -> String {
        let typingTask = await startTypingHeartbeat(destination: destination)
        return try await withTaskCancellationHandler {
            do {
                let reply = try await runChatHandlerAttempts(
                    destination: destination, text: text, attachments: attachments,
                    progress: progress, replyTo: replyTo, fromUserId: fromUserId,
                    suppressUserAppend: suppressUserAppend, sessionId: sessionId
                )
                typingTask?.cancel()
                await typingTask?.value
                return reply
            } catch {
                typingTask?.cancel()
                await typingTask?.value
                throw error
            }
        } onCancel: {
            typingTask?.cancel()
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
        sessionId: String?
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
                    "lastChatRetryError": .string(String(describing: error)),
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
