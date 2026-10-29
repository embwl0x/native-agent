import Foundation
import ChatTurnRuntime
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatSessionWork
// Blueprint: | `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`: `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |

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
        // Presence must never delay starting the actual conversation.
        let heartbeat = TelegramTypingHeartbeat { Task {
            while !Task.isCancelled {
                do {
                    try await Self.defaultSendChatAction(token, destination, "typing")
                } catch {
                    guard !Task.isCancelled else { break }
                    FileHandle.standardError.write(
                        Data("TelegramPollLoop: sendChatAction failed: \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8)
                    )
                }
                do { try await Task.sleep(nanoseconds: 4_000_000_000) }
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
    ) async -> TelegramTurnProgressCardDriver {
        let face = await TelegramProgressFace(dataRoot: dataRoot, call: partFace)
        return TelegramTurnProgressCardDriver(
            token: token,
            face: face,
            destination: destination,
            turnId: turnId,
            sendCard: Self.defaultSendMessageWithReplyMarkupReturningId,
            editCard: Self.defaultEditMessageTextWithReplyMarkup,
            deleteCard: Self.defaultDeleteMessage,
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
        approvalId: String? = nil,
        silent: Bool = false
    ) -> TelegramAssistantDeliveryDriver {
        return TelegramAssistantDeliveryDriver(
            token: token,
            destination: destination,
            turnId: turnId,
            sendRichDraft: Self.defaultSendRichMessageDraft,
            sendRichFinal: silent ? Self.defaultSendSilentRichMessage : Self.defaultSendRichMessage,
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
                    try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).recordAssistantDelivery(
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
            holdDelivery: {
                let session: String?
                let run: String?
                if let update {
                    let claim = try TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).claim(updateId: update.updateId)
                    if claim.phase == .stopped { return true }
                    session = claim.assistantSessionId
                    run = claim.assistantRunId
                } else if let approvalId {
                    let approval = try await approvalInbox.get(approvalId)
                    guard case .object(let state)? = approval.chatContinuation, let raw = state["delivery"] else {
                        throw TelegramBotError.underlying("Approval answer has no retained conversation.")
                    }
                    if state["status"] == .string("stopped") { return true }
                    session = try JSONDecoder().decode(TelegramPendingApprovalContinuation.self,
                        from: raw.serializedData(pretty: false)).sessionId
                    run = nil
                } else { throw TelegramBotError.underlying("Assistant answer has no durable delivery owner.") }
                return try !CodexCompletionReadout.permitsDelivery(sessionId: session, runId: run,
                    configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot)
                    || TurnQuietHoursWindow.holdsResidentWake(session: session, dataRoot: dataRoot)
            },
            sendGeneratedImage: { path, bytes in
                do { try await Self.defaultSendChatAction(token, destination, "upload_photo") }
                catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: upload_photo action failed: \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8))
                }
                try await Self.defaultSendPhoto(token, destination, path, bytes, nil)
            }
        )
    }

    func makeProgressSink(
        delivery: TelegramAssistantDeliveryDriver? = nil,
        card: TelegramTurnProgressCardDriver
    ) -> TelegramChatProgressSink {
        return { event in
            if case .delta(let chunk) = event {
                await delivery?.onDelta(chunk)
            }
            await card.record(progress: event)
        }
    }

    func retainedAssistantDelivery(for claim: TelegramUpdateClaim) async throws -> TelegramAssistantDeliveryState? {
        if let delivery = claim.assistantDelivery, delivery.imagePaths != nil { return delivery }
        guard let sessionId = claim.assistantSessionId, let runId = claim.assistantRunId else { return claim.assistantDelivery }
        var saved: TelegramAssistantDeliveryState?
        if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId, runId: runId) {
            saved = TelegramAssistantDeliveryState(reply: TelegramRichMessageRenderer.sanitize(
                TelegramRichMessageRenderer.stripBoldMarkers(response.output)), imagePaths: Self.replyImagePaths(response))
        }
        var delivery = claim.assistantDelivery ?? saved
        if delivery?.imagePaths == nil { delivery?.imagePaths = saved?.imagePaths }
        guard delivery != nil else { return nil }
        // No wire attempt can precede the delivery row. This canonical reply
        // survived a stop or restart between model settlement and that handoff.
        return try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).recordAssistantDelivery(
            updateId: claim.updateId, delivery: delivery, recovering: true
        )
    }

    /// The images of her reply's face, sent beside its words.
    public static func replyImagePaths(_ response: ChatResponse) -> [String] {
        (response.attachments ?? []).compactMap { $0.type == "image" ? $0.path : nil }
    }

    func repairInterruptedTurnCardsIfNeeded() async {
        let result = await turnCardRestartRepairer.repairOnce(
            token: token,
            editCard: Self.defaultEditMessageTextWithReplyMarkup,
            deleteCard: Self.defaultDeleteMessage,
            isActive: { await turnCoordinator.activeTurnIDs().contains($0) }
        )
        for failure in result.failures {
            await recordError(context: "turn_card_restart_repair", error: failure)
        }
    }

    static func progressMessage(for event: TurnStreamEvent) -> String? {
        switch event {
        case .replyTextSettled:
            return nil
        case .notice(_, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .toolResult:
            return nil
        case .delta, .final, .error:
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
                return ToolActivityPresentation.progress(name, args: input.stringFields)
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

    func runChatHandler(
        destination: TelegramDestination,
        text: String,
        attachments: [TelegramMediaAttachment] = [],
        progress: @escaping TelegramChatProgressSink,
        context: TelegramChatAttemptContext
    ) async throws -> (reply: String, imagePaths: [String]) {
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
                let reply = try await invokeChatHandler(
                    destination: destination, text: text, attachments: attachments,
                    progress: displayProgress, context: context
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

    private func invokeChatHandler(
        destination: TelegramDestination,
        text: String,
        attachments: [TelegramMediaAttachment],
        progress: @escaping TelegramChatProgressSink,
        context: TelegramChatAttemptContext
    ) async throws -> (reply: String, imagePaths: [String]) {
        if let attachmentChatHandler {
            return try await attachmentChatHandler(destination.chatId, text, attachments, progress, context)
        }
        if !attachments.isEmpty {
            await emitAttachmentDroppedTrace(
                kind: "image",
                reason: "no attachment-capable chat handler wired",
                chatId: destination.chatId, updateId: 0)
            return ("(I received your image but this bot configuration "
                + "has no vision-capable handler wired — the image was "
                + "not processed.)", [])
        }
        throw TelegramBotError.underlying("telegram_chat_handler_missing: No conversation handler is connected. The runtime owner must wire Telegram's chat handler in NativeAgent before accepting messages.")
    }

    static func chatErrorNotice(for error: Error) -> String {
        ProviderRecoveryPolicy.personMessage(error)
            ?? "The reply could not be completed; try again."
    }
}
