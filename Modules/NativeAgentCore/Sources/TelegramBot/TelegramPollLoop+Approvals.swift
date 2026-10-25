import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`; approval commands/callbacks use ApprovalInbox's life-bound continuation; the unstamped legacy continuation importer and its duplicate record are deleted |

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
            // The reply returns to its recorded topic; acknowledge the command here.
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
        await turnCoordinator.beginUpdateProcessing(update.updateId)
        let admitted = await turnCoordinator.runCommandUntilAdmitted(destination: parsed.destination) { admissionReady in
            admissionReady()
            _ = await resolveApprovalCallback(update: update, callback: callback)
            // Cancellation cannot prevent settlement of the durable ingress
            // claim after its command finishes.
            await Task {
                do {
                    _ = try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).transition(
                        updateId: update.updateId, from: [.processing, .queued], to: .completed
                    )
                } catch {
                    await recordError(context: "update_inbox_complete", error: String(describing: error), update: update)
                }
                await turnCoordinator.endUpdateProcessing(update.updateId)
            }.value
        }
        if !admitted {
            await Task {
                do {
                    _ = try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).transition(
                        updateId: update.updateId, from: [.processing, .queued], to: .pending
                    )
                } catch {
                    await recordError(context: "approval_callback_release", error: String(describing: error), update: update)
                }
                await turnCoordinator.endUpdateProcessing(update.updateId)
            }.value
        }
        return true
    }

    private func resolveApprovalCallback(update: TelegramUpdate, callback: JSONValue) async -> Bool {
        guard let parsed = TelegramApprovalCallback(callback) else { return false }
        // Approval callbacks obey the same inbound allowlist as messages.
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
                choice: parsed.command.choice,
                chatId: parsed.chatId,
                fromUserId: parsed.fromUserId
            )
            await answerRecordedCallback(
                parsed.callbackId,
                text: resolution.acknowledgement,
                context: "approval_callback_answer",
                update: update
            )
            // An approval that settled, or a mirrored card (not an approval
            // record) that was just answered: its buttons are done either way.
            let record = try? await approvalInbox.get(parsed.command.id)
            if record == nil || record?.status != "pending" {
                await terminalizeApprovalKeyboard(
                    chatId: parsed.chatId, messageId: parsed.messageId,
                    text: resolution.acknowledgement, update: update
                )
            }
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
            // Settled, or a card answered elsewhere already: clear stale buttons.
            let record = try? await approvalInbox.get(parsed.command.id)
            if record == nil || record?.status != "pending" {
                await terminalizeApprovalKeyboard(
                    chatId: parsed.chatId, messageId: parsed.messageId,
                    text: record == nil ? "This card was already answered or withdrawn." : reply, update: update
                )
            }
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


    /// Report the approval's retained result to its exact conversation, without
    /// another user message or tool replay. ApprovalInbox owns admission and life.
    private func deliverApprovalContinuation(
        approvalId: String,
        prompt: String,
        acknowledgement: String,
        destination: TelegramDestination,
        fromUserId: Int?,
        sessionId: String?
    ) async {
        guard attachmentChatHandler != nil else {
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
            // Never admit a reporting turn without its durable claim.
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
                // Mark the reporting turn started before any of its effects.
                do {
                    guard try await inbox.annotateChatContinuation(approvalId, done: false) else { return }
                } catch {
                    // Keep the unstarted record for its owner to settle or resume.
                    await recordError(
                        context: "approval_continuation_start_record",
                        error: String(describing: error)
                    )
                    let notice = "\(acknowledgement) I could not record that follow-up safely, so I stopped before writing the rest — ask again if you still need it."
                    try? await sendMessage(token, destination, notice)
                    return
                }
                let card = await makeTurnProgressCard(
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
                    text: nil,
                    approvalId: approvalId
                )
                var answerOwed = false
                do {
                    let progress = makeProgressSink(delivery: delivery, card: card)
                    let (reply, imagePaths) = try await runChatHandler(
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
                    let saved = TelegramAssistantDeliveryState(reply: TelegramRichMessageRenderer.sanitize(
                        TelegramRichMessageRenderer.stripBoldMarkers(deliveredText)), imagePaths: imagePaths)
                    guard try await inbox.annotateChatContinuation(approvalId, done: false,
                        assistantDelivery: JSONValue.parse(JSONEncoder().encode(saved))) else {
                        throw TelegramBotError.underlying("Approval answer delivery could not be recorded.")
                    }
                    switch await delivery.finalize(reply: saved.reply, savedDelivery: saved) {
                    case .held: answerOwed = true
                    case .delivered:
                        await card.transition(.completed(summary: "Reply delivered"))
                    case .failed(let reason):
                        answerOwed = true
                        await recordError(
                            context: "send_approval_continuation",
                            error: reason
                        )
                        await card.transition(.failed(reason: "Reply delivery failed: \(reason)"))
                    case .outcomeUnknown(let reason):
                        answerOwed = true
                        await recordError(
                            context: "send_approval_continuation_outcome_unknown",
                            error: reason
                        )
                        await card.transition(.outcomeUnknown(
                            reason: "Reply delivery could not be confirmed: \(reason)"
                        ))
                    }
                } catch is CancellationError {
                    // This task is already cancelled; run the terminal UI work in a fresh one.
                    await Task {
                        await delivery.stop()
                        await card.transition(.canceled(reason: "Stopped by user"))
                    }.value
                } catch {
                    await card.transition(.failed(reason: Self.chatErrorNotice(for: error)))
                    let safeError = Self._tgRedactToken(String(describing: error))
                    let notice = "\(acknowledgement) NativeAgent could not continue the reply automatically: \(safeError)"
                    await delivery.stop()
                    try? await sendMessage(token, destination, notice)
                }
                if !answerOwed { await finishApprovalContinuation(approvalId: approvalId) }
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

    /// Delivery settlement completes before returning.
    func finishApprovalContinuation(approvalId: String) async {
        do {
            _ = try await approvalInbox.annotateChatContinuation(approvalId, done: true)
        } catch {
            await recordError(context: "approval_continuation_forget", error: String(describing: error))
        }
    }

    func recoverApprovalAnswer(approvalId: String, destination: TelegramDestination,
                               resendUnknown: Bool = false) async throws -> (TelegramAssistantDeliveryOutcome, String)? {
        let key = Data(approvalId.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return try await SwiftNativePersistenceCore().withFileLock(dataRoot.appendingPathComponent("telegram/\(key).delivery")) {
            let current = try await approvalInbox.get(approvalId)
            guard case .object(let state)? = current.chatContinuation,
                  state["done"] != .bool(true), let raw = state["assistantDelivery"] else { return nil }
            let saved = try JSONDecoder().decode(TelegramAssistantDeliveryState.self, from: raw.serializedData(pretty: false))
            let delivery = makeAssistantDelivery(destination: destination, turnId: UUID(), errorContext: "recover_approval_answer",
                update: nil, message: nil, text: nil, approvalId: approvalId)
            let outcome = await delivery.finalize(reply: saved.reply, savedDelivery: saved, resendUnknown: resendUnknown)
            if case .delivered = outcome { await finishApprovalContinuation(approvalId: approvalId) }
            return (outcome, saved.reply)
        }
    }

    func retryApprovalAnswer(args: [String], update: TelegramUpdate, message: TelegramMessage, text: String) async throws -> Bool {
        for approval in try await approvalInbox.list(filter: .resolved) {
            guard case .object(let state)? = approval.chatContinuation,
                  state["done"] != .bool(true), let raw = state["assistantDelivery"],
                  let queued = state["delivery"] else { continue }
            let continuation = try JSONDecoder().decode(TelegramPendingApprovalContinuation.self, from: queued.serializedData(pretty: false))
            guard continuation.destination == message.destination else { continue }
            let retained = try JSONDecoder().decode(TelegramAssistantDeliveryState.self, from: raw.serializedData(pretty: false))
            if retained.isDelivered { continue }
            if await turnCoordinator.snapshot(destination: message.destination).isRunning {
                await sendCommandReply("I'm still delivering that answer.", kind: "retry_busy", update: update, message: message, text: text)
                return true
            }
            if let (outcome, reply) = try await recoverApprovalAnswer(approvalId: approval.id, destination: message.destination,
                                                                    resendUnknown: args == ["resend"]) {
                switch outcome {
                case .held: break
                case .delivered:
                    await recordReceipt(kind: "retry_reply", update: update, message: message, text: text, reply: reply)
                case .failed(let reason), .outcomeUnknown(let reason):
                    await sendCommandReply(reason, kind: "retry_delivery_pending", update: update, message: message, text: text)
                }
            }
            return true
        }
        return false
    }

    /// Recover only continuations the approval owner retains in this life.
    func replayApprovalContinuationsIfNeeded() async {
        guard await turnCoordinator.claimApprovalRecovery() else { return }
        do { try await reconcileSavedReplies() }
        catch { await recordError(context: "approval_answer_recovery", error: String(describing: error)) }
        let records: [(approval: ApprovalRecord, delivery: TelegramPendingApprovalContinuation)]
        do {
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
            // The shared approval reconciler now owns generic receipt turns.
            // Keep old queued evidence, but never race its delivery or
            // settlement with the shared owner, even for a started claim.
            if case .object(let payload) = approval.payload,
               payload["kind"] == .string("chat_tool_approval") || payload["kind"] == .string("telegram_tool_approval") {
                continue
            }
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
            if state["assistantDelivery"] != nil { continue }
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
/// The approval's retained Telegram delivery payload; its owner holds the life stamp.
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
