import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func handleTurnControlCallback(
        update: TelegramUpdate,
        callback: JSONValue
    ) async -> Bool {
        guard let parsed = TelegramTurnControlCallback(callback) else { return false }
        guard isAllowlistedControl(chatId: parsed.chatId, fromUserId: parsed.fromUserId) else {
            await recordBlocked(
                reason: allowedChatIds.isEmpty && allowedUserIds.isEmpty
                    ? "allowlist_empty_fail_closed"
                    : "not_allowlisted",
                update: update,
                message: nil,
                text: nil
            )
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "This Telegram control is not authorized.",
                update: update
            )
            return true
        }
        guard let card = await turnCoordinator.controlCard(
            chatId: parsed.chatId,
            turnId: parsed.turnId
        ) else {
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "This work card is no longer active.",
                update: update
            )
            return true
        }
        let snapshot = await card.snapshot()
        guard snapshot.messageId == parsed.messageId else {
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "This work card control is stale.",
                update: update
            )
            return true
        }
        guard await turnCoordinator.claimCallback(parsed.callbackId) else {
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "This control was already handled.",
                update: update
            )
            return true
        }

        switch parsed.action {
        case .status:
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "Refreshing work status.",
                update: update
            )
            await card.showStatus()
        case .details:
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "Showing safe work details.",
                update: update
            )
            await card.showDetails()
        case .stop:
            // The callback spinner is released before waiting for cooperative
            // cancellation evidence. Card state moves to canceled only from
            // the turn's own CancellationError path.
            await answerTurnControlCallback(
                parsed.callbackId,
                text: "Stopping this Telegram turn.",
                update: update
            )
            _ = await requestLiveTurnStop(
                chatId: parsed.chatId,
                turnId: parsed.turnId
            )
        }
        return true
    }

    func refreshLiveTurnCard(chatId: Int) async -> Bool {
        guard let card = await turnCoordinator.activeCard(chatId: chatId) else {
            return false
        }
        await card.showStatus()
        return true
    }

    func requestLiveTurnStop(
        chatId: Int,
        turnId: UUID? = nil
    ) async -> TelegramTurnCoordinator.StopOutcome {
        await turnCoordinator.requestStop(
            chatId: chatId,
            turnId: turnId,
            confirmationTimeoutNanoseconds: turnStopConfirmationNanoseconds,
            sleeper: turnCardSleeper
        )
    }

    private func isAllowlistedControl(chatId: Int, fromUserId: Int?) -> Bool {
        guard !allowedChatIds.isEmpty || !allowedUserIds.isEmpty else { return false }
        if allowedChatIds.contains(Int64(chatId)) { return true }
        guard let fromUserId else { return false }
        return allowedUserIds.contains(Int64(fromUserId))
    }

    private func answerTurnControlCallback(
        _ callbackId: String,
        text: String,
        update: TelegramUpdate
    ) async {
        do {
            try await answerCallbackQuery(token, callbackId, text)
        } catch {
            await recordError(
                context: "turn_control_callback_answer",
                error: String(describing: error),
                update: update,
                message: nil,
                text: nil
            )
        }
    }
}
