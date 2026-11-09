import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`: an allowlisted sender's card answers go to the card's matter's Inbox row |

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
                try await Self.defaultSendMessage(token, message.destination, reply)
                await recordReceipt(kind: "approval_unavailable", update: update, message: message, text: text, reply: reply)
            } catch {
                await recordError(context: "send_approval_unavailable", error: String(describing: error), update: update, message: message, text: text)
            }
            return
        }
        let resolution = await approvalHandler.act(command, chatId: message.chatId, messageId: nil, fromUserId: message.fromUserId)
        let reply = TurnSecretRedactor.redactText(resolution.acknowledgement)
        do {
            try await Self.defaultSendMessage(token, message.destination, reply)
            await recordReceipt(kind: "approval_decision", update: update, message: message, text: text, reply: reply)
        } catch {
            await recordError(context: "send_approval_decision", error: String(describing: error), update: update, message: message, text: text)
        }
    }

    func handleApprovalCallback(update: TelegramUpdate, callback: JSONValue) async -> Bool {
        guard let parsed = TelegramApprovalCallback(callback) else { return false }
        await turnCoordinator.beginUpdateProcessing(update.updateId)
        let admitted = await turnCoordinator.runCommandUntilAdmitted(destination: parsed.destination) { admissionReady in
            admissionReady()
            _ = await resolveApprovalCallback(update: update, callback: callback)
            // Cancellation cannot prevent settlement of the durable ingress claim after its command finishes.
            await Task {
                do {
                    _ = try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).transition(
                        updateId: update.updateId, from: [.processing], to: .completed
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
                        updateId: update.updateId, from: [.processing], to: .pending
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
        let authorization = Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds, allowedUserIds: allowedUserIds,
            chatId: parsed.chatId, fromUserId: parsed.fromUserId)
        guard authorization != .allowlistEmpty else {
            await recordBlocked(reason: "allowlist_empty_fail_closed", update: update, message: nil, text: nil)
            await answerRecordedCallback(
                parsed.callbackId,
                text: "Telegram allowlist is empty — add an approved sender in settings.",
                context: "approval_allowlist_callback_answer",
                update: update
            )
            return true
        }
        guard authorization == .allowed else {
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
        let resolution = await approvalHandler.act(parsed.command, chatId: parsed.chatId, messageId: parsed.messageId,
                                                   fromUserId: parsed.fromUserId)
        let reply = TurnSecretRedactor.redactText(resolution.acknowledgement)
        await answerRecordedCallback(parsed.callbackId, text: reply, context: "approval_callback_answer", update: update)
        // A card whose row offers nothing more on Telegram loses its buttons; one whose row could not be read keeps them.
        if resolution.settled == true {
            await terminalizeApprovalKeyboard(chatId: parsed.chatId, messageId: parsed.messageId, text: reply, update: update)
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
            try await Self.defaultEditMessageTextWithReplyMarkup(
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


}
