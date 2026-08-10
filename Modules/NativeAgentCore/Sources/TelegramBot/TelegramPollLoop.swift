import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import ProviderRouting

// MARK: - TelegramPollLoop

/// Periodic long-poll worker that conforms to BackgroundLoops.LoopRunner.
/// `interval` is the gap BETWEEN ticks; each tick blocks up to ~25s inside
/// `longPoll` while Telegram holds the connection open. Set `interval` low
/// (default 2s) so back-to-back polls flow without idle gaps.
public struct TelegramPollLoop: LoopRunner {
    public let loopId: String = "telegram_poll"
    public let interval: TimeInterval
    /// A tick runs the WHOLE chat turn (long poll + transcription + tool
    /// loop with invoke_claude subprocess turns). The scheduler's default
    /// 300s budget cancelled any 5-minute turn mid-LLM-call and silently
    /// consumed the rest of the update batch (audit 2026-06-09).
    public var tickTimeoutOverride: TimeInterval? { 3600 }
    let token: String
    let allowedChatIds: Set<Int64>
    let allowedUserIds: Set<Int64>
    let requireMention: Bool
    let bot: SwiftNativeTelegramBot
    let session: URLSession
    let dataRoot: URL
    let offsetURL: URL
    let sendMessage: @Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Void
    let sendPhoto: @Sendable (_ token: String, _ chatId: Int, _ imagePath: String, _ caption: String?) async throws -> Void
    let sendChatAction: @Sendable (_ token: String, _ chatId: Int, _ action: String) async throws -> Void
    let answerCallbackQuery: @Sendable (_ token: String, _ callbackId: String, _ text: String) async throws -> Void
    let syncCommandMenu: TelegramCommandMenuSync?
    let approvalHandler: (any TelegramApprovalHandling)?
    let chatHandler: TelegramChatHandler?
    let progressChatHandler: TelegramProgressChatHandler?
    /// Preferred over `progressChatHandler` when set: carries inbound image
    /// attachments onto the chat turn (telegram-vision-in). Falls back to the
    /// text-only handlers when nil.
    let attachmentChatHandler: TelegramProgressChatHandlerWithAttachments?
    let voiceDownloader: (any TelegramMediaDownloading)?
    let voiceTranscriber: (any TelegramVoiceTranscribing)?
    let voiceMaxBytes: Int
    /// Downloads inbound images (reuses the two-stage TelegramMediaDownloader).
    /// Separate from voiceDownloader so vision-in works even when voice
    /// transcription is unconfigured. nil disables image ingestion.
    let photoDownloader: (any TelegramMediaDownloading)?
    let photoMaxBytes: Int
    let chatRetryAttempts: Int
    let chatRetryDelayNanoseconds: UInt64
    let typingRefreshNanoseconds: UInt64
    let turnCoordinator: TelegramTurnCoordinator
    // chat-smoothness phase 5: growing-draft transport + cadence.
    let sendMessageReturningId: @Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Int
    let editMessageText: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void
    let sendMessageWithReplyMarkup: @Sendable (_ token: String, _ chatId: Int, _ text: String, _ replyMarkup: JSONValue) async throws -> Void
    let editMessageTextWithReplyMarkup: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String, _ replyMarkup: JSONValue?) async throws -> Void
    let draftEditIntervalSeconds: TimeInterval
    /// U5 W-D: gates the whole tick after a longPoll transport failure so an
    /// offline Mac probes at 1s→60s (exponential, jittered) instead of every
    /// scheduler tick. Actor reference — state survives across ticks even
    /// though the loop itself is a struct.
    let pollBackoff: TelegramExponentialBackoff
    /// U5 W-D: gates setMyCommands re-attempts after a sync failure (5s→300s)
    /// — previously a failed sync retried on EVERY tick forever.
    let commandMenuBackoff: TelegramExponentialBackoff

    public init(
        interval: TimeInterval = 2,
        token: String,
        allowedChatIds: Set<Int64> = [],
        allowedUserIds: Set<Int64> = [],
        requireMention: Bool = false,
        bot: SwiftNativeTelegramBot = SwiftNativeTelegramBot(),
        session: URLSession = .shared,
        dataRoot: URL? = nil,
        offsetURL: URL = defaultTelegramOffsetURL(),
        sendMessage: @escaping @Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Void = TelegramPollLoop.defaultSendMessage,
        sendPhoto: @escaping @Sendable (_ token: String, _ chatId: Int, _ imagePath: String, _ caption: String?) async throws -> Void = TelegramPollLoop.defaultSendPhoto,
        sendChatAction: @escaping @Sendable (_ token: String, _ chatId: Int, _ action: String) async throws -> Void = TelegramPollLoop.defaultSendChatAction,
        answerCallbackQuery: @escaping @Sendable (_ token: String, _ callbackId: String, _ text: String) async throws -> Void = TelegramPollLoop.defaultAnswerCallbackQuery,
        sendMessageReturningId: @escaping @Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Int = TelegramPollLoop.defaultSendMessageReturningId,
        editMessageText: @escaping @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void = TelegramPollLoop.defaultEditMessageText,
        sendMessageWithReplyMarkup: @escaping @Sendable (_ token: String, _ chatId: Int, _ text: String, _ replyMarkup: JSONValue) async throws -> Void = TelegramPollLoop.defaultSendMessageWithReplyMarkup,
        editMessageTextWithReplyMarkup: @escaping @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String, _ replyMarkup: JSONValue?) async throws -> Void = TelegramPollLoop.defaultEditMessageTextWithReplyMarkup,
        draftEditIntervalSeconds: TimeInterval = 2.0,
        syncCommandMenu: TelegramCommandMenuSync? = nil,
        approvalHandler: (any TelegramApprovalHandling)? = nil,
        chatHandler: TelegramChatHandler? = nil,
        progressChatHandler: TelegramProgressChatHandler? = nil,
        attachmentChatHandler: TelegramProgressChatHandlerWithAttachments? = nil,
        voiceDownloader: (any TelegramMediaDownloading)? = TelegramMediaDownloader(),
        voiceTranscriber: (any TelegramVoiceTranscribing)? = nil,
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes,
        photoDownloader: (any TelegramMediaDownloading)? = TelegramMediaDownloader(),
        photoMaxBytes: Int = TelegramPollLoop.defaultPhotoMaxBytes,
        chatRetryAttempts: Int = 2,
        chatRetryDelayNanoseconds: UInt64 = 750_000_000,
        typingRefreshNanoseconds: UInt64 = 4_000_000_000,
        turnCoordinator: TelegramTurnCoordinator = .shared,
        pollBackoff: TelegramExponentialBackoff = TelegramExponentialBackoff(),
        commandMenuBackoff: TelegramExponentialBackoff = TelegramExponentialBackoff(
            baseDelay: 5, maxDelay: 300
        )
    ) {
        self.interval = interval
        self.token = token
        self.allowedChatIds = allowedChatIds
        self.allowedUserIds = allowedUserIds
        self.requireMention = requireMention
        self.bot = bot
        self.session = session
        self.dataRoot = dataRoot ?? Self.inferDataRoot(from: offsetURL)
        self.offsetURL = offsetURL
        self.sendMessage = sendMessage
        self.sendPhoto = sendPhoto
        self.sendChatAction = sendChatAction
        self.answerCallbackQuery = answerCallbackQuery
        self.sendMessageReturningId = sendMessageReturningId
        self.editMessageText = editMessageText
        self.sendMessageWithReplyMarkup = sendMessageWithReplyMarkup
        self.editMessageTextWithReplyMarkup = editMessageTextWithReplyMarkup
        self.draftEditIntervalSeconds = draftEditIntervalSeconds
        self.syncCommandMenu = syncCommandMenu
        self.approvalHandler = approvalHandler
        self.chatHandler = chatHandler
        self.progressChatHandler = progressChatHandler
        self.attachmentChatHandler = attachmentChatHandler
        self.voiceDownloader = voiceDownloader
        self.voiceTranscriber = voiceTranscriber
        self.voiceMaxBytes = max(1, voiceMaxBytes)
        self.photoDownloader = photoDownloader
        self.photoMaxBytes = max(1, photoMaxBytes)
        self.chatRetryAttempts = max(0, chatRetryAttempts)
        self.chatRetryDelayNanoseconds = chatRetryDelayNanoseconds
        self.typingRefreshNanoseconds = typingRefreshNanoseconds
        self.turnCoordinator = turnCoordinator
        self.pollBackoff = pollBackoff
        self.commandMenuBackoff = commandMenuBackoff
    }


    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        // U5 W-D comms resilience: while a poll-failure backoff window is
        // open, the whole tick is a no-op (one timestamp comparison). The
        // scheduler keeps its cheap 2s cadence; this gate is what turns
        // "offline Mac = error spam every tick" into 1s→60s exponential
        // probing with jitter. Reset on the first successful poll.
        //
        // HEALTH-NEUTRAL: this skip means "I am not polling BECAUSE I am
        // failing". Reported as a plain skip it reset the scheduler's
        // consecutive-failure streak between every real failure (2s cadence,
        // backoff window open in between), so the failure-streak push could
        // never fire and a revoked token / offline Mac was silent forever.
        guard await pollBackoff.shouldAttempt() else {
            return .backingOff(reason: "Telegram poll backoff active")
        }

        await syncCommandMenuIfNeeded()

        let store = SwiftNativePersistenceCore()
        let current = await store.readJSON(offsetURL, defaultValue: .object(["offset": .int(0)]))
        var offset = 0
        if case .object(let obj) = current, let v = obj["offset"] {
            if case .int(let i) = v { offset = Int(i) }
            else if case .double(let d) = v { offset = Int(d) }
        }

        let result: TelegramPollResult
        do {
            result = try await bot.longPoll(
                token: token, offset: offset,
                timeoutSeconds: 25, session: session
            )
        } catch {
            let retryDelay = await pollBackoff.recordFailure()
            let failures = await pollBackoff.failureCount()
            FileHandle.standardError.write(Data(
                "TelegramPollLoop: poll failed (failure #\(failures), next attempt in \(String(format: "%.1f", retryDelay))s): \(Self._tgRedactToken(String(describing: error)))\n".utf8
            ))
            await recordError(context: "poll", error: String(describing: error))
            await writeStatePatch([
                "pollBackoffFailures": .int(Int64(failures)),
                "pollBackoffRetryDelaySeconds": .double(retryDelay),
            ])
            return .failed(error: "Telegram long poll: \(error)")
        }
        await pollBackoff.recordSuccess()
        await writeStatePatch([
            "lastPollAt": .string(_tgNowString()),
            "lastError": .null,
            "pollBackoffFailures": .int(0),
            "pollBackoffRetryDelaySeconds": .null,
            "lastChatRetryError": .null,
            "lastChatRetryFailedAttempt": .null,
            "lastChatRetryNextAttempt": .null,
            "lastChatRetrySuppressUserAppend": .null,
        ])

        var persistedOffset = offset
        for update in result.updates {
            await recordSeen(update: update, message: update.message)
            let updateOffset = update.updateId + 1
            if updateOffset > persistedOffset {
                if await persistOffset(updateOffset, store: store) {
                    persistedOffset = updateOffset
                }
            }
            if let callback = update.callbackQuery,
               await handleModelSelectionCallback(update: update, callback: callback) {
                continue
            }
            if let callback = update.callbackQuery,
               await handleApprovalCallback(update: update, callback: callback) {
                continue
            }
            guard let msg = update.message else {
                await recordBlocked(reason: "no_message", update: update, message: nil, text: nil)
                continue
            }
            // Caption fallback: an image-only send carries its text in
            // `caption`, not `text`. Prefer an explicit `text`; fall back to the
            // caption so a captioned photo keeps its prompt.
            let captionText = Self.caption(from: msg)
            let textFromMessage = (msg.text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? captionText
            let voiceAttachment = Self.voiceAttachment(from: msg)
            // telegram-vision-in: detect an inbound image so a photo-only
            // message isn't dropped as "empty" and so we can download + inject
            // it onto the chat turn the model already consumes.
            let photoAttachment = Self.photoAttachment(from: msg)
            guard textFromMessage?.isEmpty == false
                    || voiceAttachment != nil
                    || photoAttachment != nil else {
                await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
                continue
            }
            // Allowlist enforcement applies BEFORE slash dispatch so commands
            // from unauthorized users can't run either. When both sets are
            // empty, no allowlist is active (back-compat: accept all). When
            // either set is non-empty, the message must match at least one:
            // chat.id ∈ allowedChatIds OR from.id ∈ allowedUserIds.
            let hasAllowlist = !allowedChatIds.isEmpty || !allowedUserIds.isEmpty
            if hasAllowlist {
                let chatOk = allowedChatIds.contains(Int64(msg.chatId))
                let userOk: Bool = {
                    guard let fid = msg.fromUserId else { return false }
                    return allowedUserIds.contains(Int64(fid))
                }()
                if !chatOk && !userOk {
                    FileHandle.standardError.write(Data("TelegramPollLoop: dropping update \(update.updateId) — chat_id \(msg.chatId) / from \(msg.fromUserId ?? 0) not allowlisted\n".utf8))
                    await recordBlocked(reason: "not_allowlisted", update: update, message: msg, text: textFromMessage)
                    continue
                }
            }
            let text: String
            let receiptKind: String
            if let existing = textFromMessage, !existing.isEmpty {
                text = existing
                receiptKind = "reply"
            } else if let voiceAttachment {
                // attachmentChatHandler is text-capable too (production now
                // wires ONLY it — gpt-5.5 delta catch: voice notes were
                // blocked as chat_handler_not_configured after the rewire).
                guard chatHandler != nil || progressChatHandler != nil
                        || attachmentChatHandler != nil else {
                    await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: nil)
                    continue
                }
                guard let voiceDownloader, let voiceTranscriber else {
                    let notice = "(I got your voice note, but Telegram voice transcription is not configured.)"
                    do {
                        try await sendMessage(token, msg.chatId, notice)
                        await recordReceipt(kind: "voice_transcription_unavailable", update: update, message: msg, text: "[Telegram voice message]", reply: notice)
                    } catch {
                        await recordError(context: "send_voice_unavailable_notice", error: String(describing: error), update: update, message: msg, text: nil)
                    }
                    continue
                }
                do {
                    try await sendChatAction(token, msg.chatId, "typing")
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: voice typing action failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                }
                do {
                    try await sendMessage(token, msg.chatId, "Transcribing voice message")
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: voice progress send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                }
                do {
                    let downloaded = try await voiceDownloader.download(
                        token: token,
                        attachment: voiceAttachment,
                        maxBytes: voiceMaxBytes
                    )
                    // HARD cap after download (mirror of the photo guard
                    // below): getFile.file_size can be absent or
                    // underreported — never trust the pre-flight alone.
                    if let bytes = downloaded.bytes {
                        guard bytes.count <= voiceMaxBytes else {
                            throw TelegramMediaDownloadError.oversized(
                                reportedBytes: bytes.count, capBytes: voiceMaxBytes)
                        }
                    }
                    let transcription = try await voiceTranscriber.transcribe(downloaded)
                    let transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !transcript.isEmpty else {
                        throw TelegramVoiceTranscriptionError.malformedResponse
                    }
                    await recordVoiceTranscription(
                        update: update,
                        message: msg,
                        attachment: downloaded,
                        transcription: transcription
                    )
                    text = """
                    [Telegram voice message]
                    Transcript: \(transcript)
                    """
                    receiptKind = "voice_reply"
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: voice transcription failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                    await recordError(context: "voice_transcription", error: String(describing: error), update: update, message: msg, text: nil)
                    let notice = Self.voiceTranscriptionNotice(for: error)
                    do {
                        try await sendMessage(token, msg.chatId, notice)
                        await recordReceipt(kind: "voice_transcription_error", update: update, message: msg, text: "[Telegram voice message]", reply: notice)
                    } catch {
                        await recordError(context: "send_voice_error_notice", error: String(describing: error), update: update, message: msg, text: nil)
                    }
                    continue
                }
            } else if photoAttachment != nil {
                // telegram-vision-in: a photo-only send with no text/caption.
                // The image is downloaded + injected below; the model needs a
                // non-empty prompt or the chat turn is rejected as bad input.
                guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
                    await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: nil)
                    continue
                }
                text = "[The user sent an image with no caption. Look at it and respond.]"
                receiptKind = "photo_reply"
            } else {
                await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
                continue
            }
            if text.hasPrefix("/") {
                _ = await handleSlashCommand(update: update, message: msg, text: text)
                continue
            }
            // Non-slash text: route to chat-orchestration when wired.
            guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
                await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: text)
                continue
            }
            // requireMention: in group/supergroup chats (negative chat.id),
            // drop non-mention messages so the bot doesn't reply to every
            // group line. Private chats (positive chat.id) bypass — every
            // message is addressed to the bot. Mention proxy: text must
            // contain "@" (full bot-username verification would need a
            // getMe() round-trip we don't cache yet).
            if requireMention && msg.chatId < 0 && !text.contains("@") {
                FileHandle.standardError.write(Data("TelegramPollLoop: dropping update \(update.updateId) — requireMention=true, no @-mention in group chat \(msg.chatId)\n".utf8))
                await recordBlocked(reason: "mention_required", update: update, message: msg, text: text)
                continue
            }
            // telegram-vision-in: download the inbound image (if any) and stage
            // it as an attachment to thread onto the chat turn below. Tripwire:
            // a present-but-unprocessable attachment emits a
            // telegram.attachment_dropped trace AND a user-visible reply —
            // never a silent drop. On any failure we `continue` (the image was
            // the point of the turn; falling through to a blind text-only reply
            // would be the silent-drop bug).
            var stagedImageAttachments: [TelegramMediaAttachment] = []
            if let photoAttachment {
                // No downloader wired (image ingestion disabled): tripwire +
                // tell the user instead of dropping silently.
                guard let photoDownloader else {
                    await emitAttachmentDroppedTrace(
                        kind: photoAttachment.kind,
                        reason: "image ingestion is not configured",
                        chatId: msg.chatId,
                        updateId: update.updateId
                    )
                    let notice = Self.attachmentDroppedNotice(reason: "image ingestion is not configured")
                    do {
                        try await sendMessage(token, msg.chatId, notice)
                        await recordReceipt(kind: "photo_dropped", update: update, message: msg, text: text, reply: notice)
                    } catch {
                        await recordError(context: "send_photo_dropped_notice", error: String(describing: error), update: update, message: msg, text: text)
                    }
                    continue
                }
                do {
                    let downloaded = try await photoDownloader.download(
                        token: token,
                        attachment: photoAttachment,
                        maxBytes: photoMaxBytes
                    )
                    guard let bytes = downloaded.bytes, !bytes.isEmpty else {
                        throw TelegramMediaDownloadError.malformedResponse
                    }
                    // HARD cap after download: getFile.file_size can be absent
                    // or underreported — never trust the pre-flight alone
                    // (gpt-5.5 review). Oversized bytes must not reach the
                    // chat path.
                    guard bytes.count <= photoMaxBytes else {
                        throw TelegramMediaDownloadError.oversized(
                            reportedBytes: bytes.count, capBytes: photoMaxBytes)
                    }
                    let mime = Self.imageMime(
                        forFilename: downloaded.captureFilename,
                        fallbackMime: downloaded.mimeType
                    )
                    stagedImageAttachments = [TelegramMediaAttachment(
                        kind: downloaded.kind,
                        fileId: downloaded.fileId,
                        mimeType: mime,
                        sizeBytes: downloaded.sizeBytes ?? bytes.count,
                        bytes: bytes,
                        captureFilename: downloaded.captureFilename
                    )]
                } catch {
                    // Download/oversize/unsupported: tripwire trace + user reply.
                    let reason: String = {
                        if let e = error as? TelegramMediaDownloadError {
                            switch e {
                            case .oversized(let reported, let cap):
                                return "image is too large (\(reported / (1024 * 1024))MB, cap \(cap / (1024 * 1024))MB)"
                            case .missingFilePath: return "Telegram returned no file path"
                            case .httpError(let status): return "Telegram download failed (HTTP \(status))"
                            case .malformedResponse: return "Telegram download response was malformed"
                            }
                        }
                        return String(describing: error)
                    }()
                    FileHandle.standardError.write(Data("TelegramPollLoop: photo download failed for update \(update.updateId): \(Self._tgRedactToken(reason))\n".utf8))
                    await emitAttachmentDroppedTrace(
                        kind: photoAttachment.kind,
                        reason: reason,
                        chatId: msg.chatId,
                        updateId: update.updateId
                    )
                    await recordError(context: "photo_ingest", error: reason, update: update, message: msg, text: text)
                    let notice = Self.attachmentDroppedNotice(reason: reason)
                    do {
                        try await sendMessage(token, msg.chatId, notice)
                        await recordReceipt(kind: "photo_dropped", update: update, message: msg, text: text, reply: notice)
                    } catch {
                        await recordError(context: "send_photo_dropped_notice", error: String(describing: error), update: update, message: msg, text: text)
                    }
                    continue
                }
            }
            if await turnCoordinator.snapshot(chatId: msg.chatId).isRunning {
                let notice = "A Telegram turn is already running for this chat. Use /stop to cancel it before sending another message."
                do {
                    try await sendMessage(token, msg.chatId, notice)
                    await recordReceipt(kind: "busy_notice", update: update, message: msg, text: text, reply: notice)
                } catch {
                    await recordError(context: "send_busy_notice", error: String(describing: error), update: update, message: msg, text: text)
                }
                continue
            }
            await turnCoordinator.recordLastUserMessage(chatId: msg.chatId, text: text)
            // chat-smoothness phase 5: growing draft — the reply streams into
            // one message via throttled edits; finalize tells us what (if
            // anything) still needs a plain send. Declared OUTSIDE the do so
            // the error path can convert a dangling partial draft into the
            // honest error notice instead of leaving stale text behind.
            // A Telegram message is human-interactive work even though it
            // arrives through the utility-priority long-poll loop. Without an
            // explicit promotion this child inherits the scheduler priority,
            // so local context/history preparation can be starved behind a
            // concurrent build while the provider itself remains healthy.
            // The coordinator still owns this exact task for /stop and normal
            // lifecycle cancellation; only its scheduling priority changes.
            let normalTurnTask = Task(priority: .userInitiated) {
                let draft = TelegramDraftStreamer(
                    token: token,
                    chatId: msg.chatId,
                    editIntervalSeconds: draftEditIntervalSeconds,
                    sendReturningId: sendMessageReturningId,
                    editMessage: editMessageText
                )
                do {
                    let typingTask = await startTypingHeartbeat(chatId: msg.chatId)
                    defer { typingTask?.cancel() }
                    let progress = makeProgressSink(chatId: msg.chatId, draft: draft)
                    let generatedImages = TelegramGeneratedImageCollector()
                    let capturingProgress: TelegramChatProgressSink = { event in
                        await generatedImages.record(event)
                        await progress(event)
                    }
                    let reply = try await runChatHandlerWithRetry(
                        chatId: msg.chatId,
                        text: text,
                        attachments: stagedImageAttachments,
                        progress: capturingProgress,
                        replyTo: msg.replyTo,
                        fromUserId: msg.fromUserId
                    )
                    try Task.checkCancellation()
                    if !reply.isEmpty {
                        do {
                            for chunk in await draft.finalize(reply: reply) {
                                try await sendMessage(token, msg.chatId, chunk)
                            }
                            let imagePaths = await generatedImages.snapshot()
                            for imagePath in imagePaths {
                                do {
                                    try await sendChatAction(token, msg.chatId, "upload_photo")
                                    try await sendPhoto(token, msg.chatId, imagePath, nil)
                                } catch {
                                    FileHandle.standardError.write(Data("TelegramPollLoop: generated image send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                                    await recordError(context: "send_generated_image", error: String(describing: error), update: update, message: msg, text: text)
                                }
                            }
                            await recordReceipt(kind: receiptKind, update: update, message: msg, text: text, reply: reply)
                        } catch {
                            FileHandle.standardError.write(Data("TelegramPollLoop: reply send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                            await recordError(context: "send_reply", error: String(describing: error), update: update, message: msg, text: text)
                        }
                    } else {
                        // A live draft must not dangle with partial text when the
                        // turn produced nothing. If no draft exists, send the
                        // notice as a new message so the failure is never silent.
                        let notice = "(the reply came back empty - check the Mac error log)"
                        await recordError(context: "empty_reply", error: "chat handler returned empty output", update: update, message: msg, text: text)
                        await deliverDraftOrSendNotice(
                            notice,
                            draft: draft,
                            receiptKind: "empty_reply_notice",
                            sendErrorContext: "send_empty_reply_notice",
                            update: update,
                            message: msg,
                            text: text
                        )
                    }
                } catch is CancellationError {
                    let notice = "(Telegram turn stopped.)"
                    if await draft.abortDelivering(notice: notice) {
                        await recordReceipt(kind: "stopped_notice", update: update, message: msg, text: text, reply: notice)
                    } else {
                        do {
                            try await sendMessage(token, msg.chatId, notice)
                            await recordReceipt(kind: "stopped_notice", update: update, message: msg, text: text, reply: notice)
                        } catch {
                            await recordError(context: "send_stop_notice", error: String(describing: error), update: update, message: msg, text: text)
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: chat handler failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                    await recordError(context: "chat_handler", error: String(describing: error), update: update, message: msg, text: text)
                    let notice = Self.chatErrorNotice(for: error)
                    // Prefer editing the partial draft into the error notice; a
                    // separate message only when there's no draft (or the edit
                    // failed).
                    if await draft.abortDelivering(notice: notice) {
                        await recordReceipt(kind: "error_notice", update: update, message: msg, text: text, reply: notice)
                    } else {
                        do {
                            try await sendMessage(token, msg.chatId, notice)
                            await recordReceipt(kind: "error_notice", update: update, message: msg, text: text, reply: notice)
                        } catch {
                            await recordError(context: "send_error_notice", error: String(describing: error), update: update, message: msg, text: text)
                        }
                    }
                }
            }
            guard let turnId = await turnCoordinator.beginTurn(
                chatId: msg.chatId,
                text: text,
                task: normalTurnTask
            ) else {
                normalTurnTask.cancel()
                let notice = "A Telegram turn is already running for this chat. Use /stop to cancel it before sending another message."
                do {
                    try await sendMessage(token, msg.chatId, notice)
                    await recordReceipt(kind: "busy_notice", update: update, message: msg, text: text, reply: notice)
                } catch {
                    await recordError(context: "send_busy_notice", error: String(describing: error), update: update, message: msg, text: text)
                }
                continue
            }
            await normalTurnTask.value
            await turnCoordinator.finishTurn(chatId: msg.chatId, turnId: turnId)
        }

        let finalOffset = max(persistedOffset, result.nextOffset)
        if finalOffset != persistedOffset || result.updates.isEmpty {
            _ = await persistOffset(finalOffset, store: store)
        }
        return .completed(result: "Telegram poll processed \(result.updates.count) update(s)")
    }
}
