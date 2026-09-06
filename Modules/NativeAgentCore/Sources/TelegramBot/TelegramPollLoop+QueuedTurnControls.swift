import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func handleQueuedTurnControlCallback(
        update: TelegramUpdate,
        callback: JSONValue
    ) async -> Bool {
        guard let parsed = TelegramQueuedTurnControlCallback(callback) else { return false }
        guard isAllowlistedQueuedControl(chatId: parsed.chatId, fromUserId: parsed.fromUserId) else {
            await answerQueuedTurnControlCallback(
                parsed.callbackId,
                text: "This Telegram control is not authorized.",
                update: update
            )
            return true
        }
        guard let queued = await turnCoordinator.queuedTurn(
            destination: parsed.destination,
            updateId: parsed.updateId
        ), queued.acknowledgementMessageId == parsed.messageId else {
            await answerQueuedTurnControlCallback(
                parsed.callbackId,
                text: "This queued-message control is no longer active.",
                update: update
            )
            return true
        }
        guard await turnCoordinator.claimCallback(parsed.callbackId) else {
            await answerQueuedTurnControlCallback(
                parsed.callbackId,
                text: "This control was already handled.",
                update: update
            )
            return true
        }

        switch parsed.action {
        case .remove:
            do {
                let completed = try await TelegramUpdateInbox(offsetURL: offsetURL).transition(
                    updateId: parsed.updateId,
                    from: [.queued],
                    to: .completed
                )
                guard completed.phase == .completed else {
                    await answerQueuedTurnControlCallback(
                        parsed.callbackId,
                        text: "That message has already started.",
                        update: update
                    )
                    return true
                }
            } catch {
                await answerQueuedTurnControlCallback(
                    parsed.callbackId,
                    text: "I couldn't safely remove that message. It is still queued.",
                    update: update
                )
                await recordError(
                    context: "queued_turn_remove_settle",
                    error: String(describing: error),
                    update: update
                )
                return true
            }
            guard await turnCoordinator.removeQueuedTurn(
                destination: parsed.destination,
                updateId: parsed.updateId
            ) != nil else {
                await answerQueuedTurnControlCallback(
                    parsed.callbackId,
                    text: "That message has already started.",
                    update: update
                )
                return true
            }
            await answerQueuedTurnControlCallback(
                parsed.callbackId,
                text: "Removed from the queue.",
                update: update
            )
            try? await editMessageTextWithReplyMarkup(
                token,
                parsed.chatId,
                parsed.messageId,
                "Removed from queue · \(queued.promptPreview)",
                TelegramTurnControlCallback.clearedReplyMarkup
            )
        case .steer:
            // Bind the stop to the generation that was active before the
            // promotion. The callback acknowledgement below is an await point:
            // if that old turn finishes naturally there, the promoted item can
            // already be active. An unbound chat-level stop would then cancel
            // the very message the user chose to steer to.
            let interruptedTurnID = await turnCoordinator.activeTurnID(destination: parsed.destination)
            guard await turnCoordinator.promoteQueuedTurn(
                destination: parsed.destination,
                updateId: parsed.updateId
            ) != nil else {
                await answerQueuedTurnControlCallback(
                    parsed.callbackId,
                    text: "That message has already started.",
                    update: update
                )
                return true
            }
            await answerQueuedTurnControlCallback(
                parsed.callbackId,
                text: "Steering to this message now.",
                update: update
            )
            let stopOutcome: TelegramTurnCoordinator.StopOutcome
            if let interruptedTurnID {
                stopOutcome = await requestLiveTurnStop(
                    destination: parsed.destination,
                    turnId: interruptedTurnID
                )
            } else {
                stopOutcome = .notRunning
            }
            if stopOutcome == .outcomeUnknown {
                try? await editMessageTextWithReplyMarkup(
                    token,
                    parsed.chatId,
                    parsed.messageId,
                    "First in queue · current turn is still stopping · \(queued.promptPreview)",
                    TelegramQueuedTurnControlCallback.replyMarkup(updateId: parsed.updateId)
                )
            }
        }
        return true
    }

    private func isAllowlistedQueuedControl(chatId: Int, fromUserId: Int?) -> Bool {
        guard !allowedChatIds.isEmpty || !allowedUserIds.isEmpty else { return false }
        if allowedChatIds.contains(Int64(chatId)) { return true }
        guard let fromUserId else { return false }
        return allowedUserIds.contains(Int64(fromUserId))
    }

    private func answerQueuedTurnControlCallback(
        _ callbackId: String,
        text: String,
        update: TelegramUpdate
    ) async {
        do {
            try await answerCallbackQuery(token, callbackId, text)
        } catch {
            await recordError(
                context: "queued_turn_control_callback_answer",
                error: String(describing: error),
                update: update,
                message: nil,
                text: nil
            )
        }
    }
}
