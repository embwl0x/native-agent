import Foundation
import ApprovalInbox
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
                try await sendMessage(token, message.destination, reply)
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
            // 2026-09-06: `/approve <id>` may be typed in any topic of the
            // supergroup, but the interrupted turn lives in the topic the
            // approval was raised in. The continuation, its card and its reply
            // go there; the acknowledgement for the typed command stays where
            // the command was typed, so the person who typed it sees an answer.
            let continuationDestination = resolution.destination ?? message.destination
            if let prompt = resolution.continuationPrompt {
                if continuationDestination != message.destination {
                    try? await sendMessage(token, message.destination, resolution.acknowledgement)
                }
                await deliverApprovalContinuation(
                    approvalId: command.id,
                    prompt: prompt,
                    acknowledgement: resolution.acknowledgement,
                    destination: continuationDestination,
                    fromUserId: message.fromUserId,
                    sessionId: resolution.sessionId
                )
            } else {
                try await sendMessage(token, message.destination, resolution.acknowledgement)
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
                try await sendMessage(token, message.destination, reply)
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
            await answerRecordedCallback(
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
            await answerRecordedCallback(
                parsed.callbackId,
                text: "This Telegram chat is not allowlisted.",
                context: "approval_unauthorized_callback_answer",
                update: update
            )
            return true
        }
        guard let approvalHandler else {
            await answerRecordedCallback(
                parsed.callbackId,
                text: "Approval commands are not wired.",
                context: "approval_unavailable_callback_answer",
                update: update
            )
            return true
        }
        guard await turnCoordinator.claimCallback(parsed.callbackId) else {
            await answerRecordedCallback(
                parsed.callbackId,
                text: "This approval callback was already handled.",
                context: "approval_duplicate_callback_answer",
                update: update
            )
            return true
        }
        do {
            let resolution = try await approvalHandler.resolveTelegramApproval(
                id: parsed.command.id,
                decision: parsed.command.decision,
                chatId: parsed.chatId,
                fromUserId: parsed.fromUserId
            )
            await answerRecordedCallback(
                parsed.callbackId,
                text: resolution.acknowledgement,
                context: "approval_callback_answer",
                update: update
            )
            await terminalizeApprovalKeyboard(
                chatId: parsed.chatId,
                messageId: parsed.messageId,
                text: resolution.acknowledgement,
                update: update
            )
            if let prompt = resolution.continuationPrompt {
                await deliverApprovalContinuation(
                    approvalId: parsed.command.id,
                    prompt: prompt,
                    acknowledgement: resolution.acknowledgement,
                    // 2026-09-06: the recorded topic wins over the topic the
                    // button was pressed in (a forwarded card, General).
                    destination: resolution.destination ?? parsed.destination,
                    fromUserId: parsed.fromUserId,
                    sessionId: resolution.sessionId
                )
            }
        } catch {
            let reply = "Approval update failed: \(Self._tgRedactToken(String(describing: error)))"
            await answerRecordedCallback(
                parsed.callbackId,
                text: reply,
                context: "approval_callback_error_answer",
                update: update
            )
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


    /// Resume the exact Telegram conversation whose non-blocking approval just
    /// completed. The prompt is internal (`suppressUserAppend`) and carries the
    /// redacted replay result, so the assistant can finish the interrupted
    /// request without fabricating a second user message or rerunning the tool.
    ///
    /// 2026-09-06: the hand-off is durable. The record below is written BEFORE
    /// the turn is admitted and completed only once the continuation has been
    /// answered, so a restart in between resumes it instead of leaving the
    /// sender with a tool that ran and an answer that never came.
    private func deliverApprovalContinuation(
        approvalId: String,
        prompt: String,
        acknowledgement: String,
        destination: TelegramDestination,
        fromUserId: Int?,
        sessionId: String?
    ) async {
        guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
            try? await sendMessage(token, destination, acknowledgement)
            // Nothing here can continue the turn, so nothing is owed on the
            // next start either (no-op unless this is a replay).
            _ = try? await approvalInbox.annotateChatContinuation(approvalId, done: true)
            return
        }
        let pending = TelegramPendingApprovalContinuation(
            approvalId: approvalId,
            prompt: prompt,
            acknowledgement: acknowledgement,
            chatId: destination.chatId,
            threadId: destination.threadId,
            fromUserId: fromUserId,
            sessionId: sessionId
        )
        do {
            guard try await approvalInbox.queueChatContinuation(approvalId, delivery: pending.toJSON()) else { return }
        } catch {
            // 2026-09-06: a continuation that cannot be recorded is REFUSED.
            // The tool behind this approval has already run, and the whole
            // point of the record is to say whether its turn started; running
            // without it means a restart in the wrong moment either replays the
            // tool's effects or reports nothing at all. A refused follow-up
            // costs the sender a reply it is told about and can ask for again.
            await recordError(
                context: "approval_continuation_record",
                error: String(describing: error)
            )
            let notice = "\(acknowledgement) I could not record that follow-up safely, so I stopped before writing the rest — ask again if you still need it."
            try? await sendMessage(token, destination, notice)
            return
        }
        let inbox = approvalInbox
        let operation: @Sendable (UUID) async -> Void = { turnId in
                // The turn is running: from here a replay could repeat tool
                // calls, so a restart reports the loss instead of replaying.
                //
                // 2026-09-06: that write is the ONLY thing standing between a
                // restart and a second run of tools that already ran, so its
                // failure aborts the continuation instead of being swallowed.
                // The record on disk is still unclaimed; a turn that
                // ran anyway would be replayed verbatim after a restart.
                do {
                    guard try await inbox.annotateChatContinuation(approvalId, done: false) else { return }
                } catch {
                    // The record is LEFT in place, still unclaimed. That
                    // is the state a restart replays verbatim, which is safe
                    // precisely because this turn never ran: the tool's result
                    // is already inside the prompt. Removing it would throw the
                    // only remaining route to the answer away.
                    await recordError(
                        context: "approval_continuation_start_record",
                        error: String(describing: error)
                    )
                    let notice = "\(acknowledgement) I could not record that follow-up safely, so I stopped before writing the rest — ask again if you still need it."
                    try? await sendMessage(token, destination, notice)
                    return
                }
                let card = makeTurnProgressCard(
                    destination: destination,
                    turnId: turnId,
                    errorContext: "approval_continuation_card",
                    update: nil,
                    message: nil,
                    text: nil
                )
                guard await turnCoordinator.attachCard(
                    card,
                    destination: destination,
                    turnId: turnId
                ) else {
                    await finishApprovalContinuation(approvalId: approvalId)
                    return
                }
                await card.start()
                await card.transition(.working(action: "Continuing after approval"))
                let delivery = makeAssistantDelivery(
                    destination: destination,
                    turnId: turnId,
                    errorContext: "approval_assistant_delivery",
                    update: nil,
                    message: nil,
                    text: nil
                )
                let typingTask = await startTypingHeartbeat(destination: destination)
                defer { typingTask?.cancel() }
                do {
                    let progress = makeProgressSink(delivery: delivery, card: card)
                    let reply = try await runChatHandlerWithRetry(
                        destination: destination,
                        text: prompt,
                        attachments: [],
                        progress: progress,
                        replyTo: nil,
                        fromUserId: fromUserId,
                        suppressUserAppend: true,
                        sessionId: sessionId
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
                        try? await sendMessage(token, destination, notice)
                    }
                }
                await finishApprovalContinuation(approvalId: approvalId)
            }
        if await turnCoordinator.startTrackedTurn(
            destination: destination,
            text: prompt,
            operation: operation
        ) == nil {
            await turnCoordinator.enqueueApprovalContinuation(
                destination: destination,
                text: prompt,
                operation: operation
            )
        }
    }

    /// 2026-09-06: await completion before returning, so restart repair cannot
    /// report a lost answer that was already delivered.
    private func finishApprovalContinuation(approvalId: String) async {
        do {
            _ = try await approvalInbox.annotateChatContinuation(approvalId, done: true)
        } catch {
            await recordError(context: "approval_continuation_forget", error: String(describing: error))
        }
    }

    /// 2026-09-06: once per process, answer for the approval continuations the
    /// previous process was holding. One that never started is replayed
    /// verbatim — the tool already ran and its result is inside the prompt, so
    /// running the turn repeats nothing. One that HAD started may have called
    /// tools of its own, so it is never replayed: the sender is told what
    /// happened, which is still better than the silence this used to be.
    func replayApprovalContinuationsIfNeeded() async {
        guard await turnCoordinator.claimApprovalRecovery() else { return }
        let records: [(approval: ApprovalRecord, delivery: TelegramPendingApprovalContinuation)]
        do {
            // 2026-09-18: import the old hand-off without ever resetting a claim.
            // Leave legacy bytes alone; completed approval markers prevent reimport.
            let legacyPath = dataRoot.appendingPathComponent("telegram/approval_continuations.json")
            if FileManager.default.fileExists(atPath: legacyPath.path) {
                let legacy = try JSONDecoder().decode(
                    TelegramLegacyApprovalContinuations.self, from: Data(contentsOf: legacyPath))
                guard legacy.schemaVersion == 1 else {
                    throw TelegramBotError.underlying("unsupported Telegram approval continuation schema")
                }
                for raw in legacy.continuations {
                    let delivery = try JSONDecoder().decode(
                        TelegramPendingApprovalContinuation.self, from: raw.serializedData(pretty: false))
                    guard case .object(let value) = raw, case .bool(let started)? = value["started"] else {
                        throw TelegramBotError.underlying("malformed Telegram approval continuation")
                    }
                    _ = try await approvalInbox.queueChatContinuation(delivery.approvalId,
                        delivery: delivery.toJSON(), alreadyStarted: started)
                }
            }
            records = try await approvalInbox.list(filter: .resolved).compactMap { approval in
                guard case .object(let state)? = approval.chatContinuation,
                      state["done"] != .bool(true), let raw = state["delivery"],
                      let delivery = try? JSONDecoder().decode(
                        TelegramPendingApprovalContinuation.self, from: raw.serializedData(pretty: false))
                else { return nil }
                return (approval, delivery)
            }
        } catch {
            await recordError(context: "approval_continuation_replay", error: String(describing: error))
            return
        }
        for (approval, record) in records {
            guard Self.inboundAuthorizationDecision(
                allowedChatIds: allowedChatIds,
                allowedUserIds: allowedUserIds,
                chatId: record.chatId,
                fromUserId: record.fromUserId
            ) == .allowed else {
                // Paused work remains durable for an admitted future restart.
                continue
            }
            guard case .object(let state)? = approval.chatContinuation else { continue }
            guard state["started"] == nil else {
                let notice = "\(record.acknowledgement) I restarted before I could write the rest of that answer — ask again if you still need it."
                do {
                    try await sendMessage(token, record.destination, notice)
                } catch {
                    await recordError(
                        context: "approval_continuation_interrupted_notice",
                        error: String(describing: error)
                    )
                }
                await finishApprovalContinuation(approvalId: record.approvalId)
                continue
            }
            await deliverApprovalContinuation(
                approvalId: record.approvalId,
                prompt: record.prompt,
                acknowledgement: record.acknowledgement,
                destination: record.destination,
                fromUserId: record.fromUserId,
                sessionId: record.sessionId
            )
        }
    }
}

/// One approval continuation that has been admitted but not yet answered.
///
/// 2026-09-06: the approval resolution runs the tool FIRST and only then hands
/// the reply back as a continuation turn. Between those two moments the record
/// is resolved, so a second `/approve` is refused as "not pending" — a restart
/// in that window lost the answer to an action that had already happened, with
/// no way for anyone to ask for it again. This is the durable half of that
/// hand-off: written before the turn is admitted, marked when it actually
/// starts, completed when it is answered. The approval owns that state.
struct TelegramPendingApprovalContinuation: Sendable, Codable, Equatable {
    let approvalId: String
    let prompt: String
    let acknowledgement: String
    let chatId: Int
    let threadId: Int?
    let fromUserId: Int?
    let sessionId: String?

    func toJSON() throws -> JSONValue {
        try JSONValue.parse(JSONEncoder().encode(self))
    }

    var destination: TelegramDestination {
        TelegramDestination(chatId: chatId, threadId: threadId)
    }
}

/// Read-only compatibility for hand-offs filed before the approval owned them.
private struct TelegramLegacyApprovalContinuations: Decodable {
    let schemaVersion: Int
    let continuations: [JSONValue]
}
