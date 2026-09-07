import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func handleTurnControlCallback(
        update: TelegramUpdate,
        callback: JSONValue
    ) async -> Bool {
        guard let parsed = TelegramTurnControlCallback(callback) else { return false }
        func answer(_ text: String) async {
            await answerRecordedCallback(
                parsed.callbackId,
                text: text,
                context: "turn_control_callback_answer",
                update: update
            )
        }
        guard isAllowlistedControl(chatId: parsed.chatId, fromUserId: parsed.fromUserId) else {
            await recordBlocked(
                reason: allowedChatIds.isEmpty && allowedUserIds.isEmpty
                    ? "allowlist_empty_fail_closed"
                    : "not_allowlisted",
                update: update,
                message: nil,
                text: nil
            )
            await answer("This Telegram control is not authorized.")
            return true
        }
        guard let card = await turnCoordinator.controlCard(
            destination: parsed.destination,
            turnId: parsed.turnId
        ) else {
            await answer("This work card is no longer active.")
            return true
        }
        let snapshot = await card.snapshot()
        guard snapshot.messageId == parsed.messageId else {
            await answer("This work card control is stale.")
            return true
        }
        guard await turnCoordinator.claimCallback(parsed.callbackId) else {
            await answer("This control was already handled.")
            return true
        }

        switch parsed.action {
        case .status:
            await answer("Refreshing work status.")
            await card.showStatus()
        case .details:
            await answer("Showing safe work details.")
            await card.showDetails()
        case .stop:
            // The callback spinner is released before waiting for cooperative
            // cancellation evidence. Card state moves to canceled only from
            // the turn's own CancellationError path.
            await answer("Stopping this Telegram turn.")
            _ = await requestLiveTurnStop(
                destination: parsed.destination,
                turnId: parsed.turnId
            )
        }
        return true
    }

    func refreshLiveTurnCard(destination: TelegramDestination) async -> Bool {
        guard let card = await turnCoordinator.activeCard(destination: destination) else {
            return false
        }
        await card.showStatus()
        return true
    }

    func requestLiveTurnStop(
        destination: TelegramDestination,
        turnId: UUID? = nil
    ) async -> TelegramTurnCoordinator.StopOutcome {
        await turnCoordinator.requestStop(
            destination: destination,
            turnId: turnId,
            confirmationTimeoutNanoseconds: turnStopConfirmationNanoseconds,
            sleeper: turnCardSleeper
        )
    }

    func isAllowlistedControl(chatId: Int, fromUserId: Int?) -> Bool {
        guard !allowedChatIds.isEmpty || !allowedUserIds.isEmpty else { return false }
        if allowedChatIds.contains(Int64(chatId)) { return true }
        guard let fromUserId else { return false }
        return allowedUserIds.contains(Int64(fromUserId))
    }

}
