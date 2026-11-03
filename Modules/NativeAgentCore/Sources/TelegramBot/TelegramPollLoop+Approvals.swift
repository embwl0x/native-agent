import Foundation
import NativeAgentShared
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`; approval commands/callbacks carry decisions and terminalize keyboards; shared approval transactions own reporting turns, whose replies use the session's update-delivery journal |

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
        do {
            let resolution = try await approvalHandler.resolveTelegramApproval(
                id: command.id,
                decision: command.decision,
                choice: nil,
                chatId: message.chatId,
                fromUserId: message.fromUserId
            )
            try await Self.defaultSendMessage(token, message.destination, resolution.acknowledgement)
            await recordReceipt(
                kind: "approval_decision",
                update: update,
                message: message,
                text: text,
                reply: resolution.acknowledgement
            )
        } catch {
            let reply = "Approval update failed: \(TurnSecretRedactor.redactText(String(describing: error)))"
            do {
                try await Self.defaultSendMessage(token, message.destination, reply)
                await recordReceipt(kind: "approval_error", update: update, message: message, text: text, reply: reply)
            } catch {
                await recordError(context: "send_approval_error", error: String(describing: error), update: update, message: message, text: text)
            }
        }
    }

    /// A read whose absence is an answer (the card was answered or withdrawn);
    /// every other inbox failure still throws.
    static func approvalIfPresent(_ inbox: SwiftNativeApprovalInbox, _ id: String) async throws -> ApprovalRecord? {
        do { return try await inbox.get(id) }
        catch ApprovalInboxError.notFound { return nil }
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
            let record = try await Self.approvalIfPresent(approvalInbox, parsed.command.id)
            if record == nil || record?.status != "pending" {
                await terminalizeApprovalKeyboard(
                    chatId: parsed.chatId, messageId: parsed.messageId,
                    text: resolution.acknowledgement, update: update
                )
            }
        } catch {
            let reply = "Approval update failed: \(TurnSecretRedactor.redactText(String(describing: error)))"
            await answerRecordedCallback(
                parsed.callbackId,
                text: reply,
                context: "approval_callback_error_answer",
                update: update
            )
            // Only an authoritative read can establish absence or settlement.
            do {
                let record = try await Self.approvalIfPresent(approvalInbox, parsed.command.id)
                if record == nil || record?.status != "pending" {
                    await terminalizeApprovalKeyboard(
                        chatId: parsed.chatId, messageId: parsed.messageId,
                        text: record == nil ? "This card was already answered or withdrawn." : reply, update: update
                    )
                }
            } catch {
                await recordError(context: "approval_callback_readback", error: String(describing: error), update: update)
                await answerRecordedCallback(parsed.callbackId,
                    text: "Approval status is unavailable. The card's controls remain until its decision can be read.",
                    context: "approval_callback_readback_unavailable", update: update)
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
