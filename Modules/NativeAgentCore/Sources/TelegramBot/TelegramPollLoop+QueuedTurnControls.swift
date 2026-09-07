import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func handleQueuedTurnControlCallback(
        update: TelegramUpdate,
        callback: JSONValue
    ) async -> Bool {
        guard let parsed = TelegramQueuedTurnControlCallback(callback) else { return false }
        func answer(_ text: String) async {
            await answerRecordedCallback(
                parsed.callbackId,
                text: text,
                context: "queued_turn_control_callback_answer",
                update: update
            )
        }
        guard isAllowlistedControl(chatId: parsed.chatId, fromUserId: parsed.fromUserId) else {
            await answer("This Telegram control is not authorized.")
            return true
        }
        guard let queued = await turnCoordinator.queuedTurn(
            destination: parsed.destination,
            updateId: parsed.updateId
        ), queued.acknowledgementMessageId == parsed.messageId else {
            await answer("This queued-message control is no longer active.")
            return true
        }
        guard await turnCoordinator.claimCallback(parsed.callbackId) else {
            await answer("This control was already handled.")
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
                    await answer("That message has already started.")
                    return true
                }
            } catch {
                await answer("I couldn't safely remove that message. It is still queued.")
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
                await answer("That message has already started.")
                return true
            }
            await answer("Removed from the queue.")
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
                await answer("That message has already started.")
                return true
            }
            await answer("Steering to this message now.")
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


}
