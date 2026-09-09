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

    /// The fail-closed sender decision shared by the live poll loop and
    /// Settings coverage. The decision carries the exact receipt reason, so a
    /// refactor cannot turn an empty or nonmatching allowlist into a silent
    /// accept-all path.
    public enum InboundAuthorizationDecision: Equatable, Sendable {
        case allowed
        case allowlistEmpty
        case notAllowlisted
    }

    public static func inboundAuthorizationDecision(
        allowedChatIds: Set<Int64>,
        allowedUserIds: Set<Int64>,
        chatId: Int,
        fromUserId: Int?
    ) -> InboundAuthorizationDecision {
        guard !allowedChatIds.isEmpty || !allowedUserIds.isEmpty else {
            return .allowlistEmpty
        }
        guard allowedChatIds.contains(Int64(chatId))
                || fromUserId.map({ allowedUserIds.contains(Int64($0)) }) == true
        else {
            return .notAllowlisted
        }
        return .allowed
    }

    /// The authorization decision for ordinary group messages. Kept at the
    /// runtime boundary so Settings can prove that its saved `requireMention`
    /// value changes the decision the poll loop actually executes.
    public static func dropsForMissingMention(
        requireMention: Bool,
        chatId: Int,
        text: String
    ) -> Bool {
        requireMention && chatId < 0 && !text.contains("@")
    }
    let offsetURL: URL
    // 2026-09-06: every SEND carries a TelegramDestination so a forum topic's
    // reply lands in that topic. Edits and callback answers are addressed by
    // message id and keep taking a bare chat id — Telegram takes no thread on
    // those.
    let sendMessage: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String) async throws -> Void
    let sendPhoto: @Sendable (_ token: String, _ destination: TelegramDestination, _ imagePath: String, _ caption: String?) async throws -> Void
    let sendChatAction: @Sendable (_ token: String, _ destination: TelegramDestination, _ action: String) async throws -> Void
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
    private actor VoicePermissionNotice {
        var sent = false
        func setSent(_ value: Bool) { sent = value }
    }
    private let voicePermissionNotice = VoicePermissionNotice()
    /// PATCH-2026-08-18: fires when an inbound media path fails specifically
    /// because a macOS privacy (TCC) grant is missing — NOT for ordinary
    /// failures like audio conversion, oversize, or transport. The Telegram
    /// sender already gets a chat notice for every failure kind; this is the
    /// separate app-side signal, because the person who has to go flip the
    /// System Settings switch is at the Mac, not in the chat. Payload is the
    /// capability name (e.g. "speechRecognition"). nil disables the signal.
    let onCapabilityDenied: (@Sendable (String) async -> Void)?
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
    let sendMessageReturningId: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String) async throws -> Int
    let sendRichMessageDraft: (@Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ draftId: Int,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Void)?
    let sendRichMessage: (@Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Int)?
    let sendMessageWithReplyMarkupReturningId: @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ text: String,
        _ replyMarkup: JSONValue
    ) async throws -> Int
    let editMessageText: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void
    let sendMessageWithReplyMarkup: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String, _ replyMarkup: JSONValue) async throws -> Void
    let editMessageTextWithReplyMarkup: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String, _ replyMarkup: JSONValue?) async throws -> Void
    let draftEditIntervalSeconds: TimeInterval
    let turnCardMinimumEditIntervalSeconds: TimeInterval
    let turnCardHeartbeatNanoseconds: UInt64
    let turnCardStalledAfterSeconds: TimeInterval
    let turnCardClock: @Sendable () -> Date
    let turnCardSleeper: @Sendable (_ nanoseconds: UInt64) async throws -> Void
    let turnStopConfirmationNanoseconds: UInt64
    let turnCardLedger: TelegramTurnCardLedger
    let turnCardRestartRepairer: TelegramTurnCardRestartRepairer
    /// 2026-09-06: durable record of an approval continuation that has been
    /// admitted but not yet answered. The tool has ALREADY run by then and the
    /// approval is resolved, so a restart in this window used to lose the
    /// follow-up for good — a second `/approve` is refused as not pending.
    let approvalContinuationLedger: TelegramApprovalContinuationLedger
    /// U5 W-D: gates the whole tick after a longPoll transport failure so an
    /// offline Mac probes at 1s → 60s (doubling, ±20% jitter, re-clamped to
    /// the 60s cap after jitter, reset on the first success) instead of every
    /// scheduler tick. That curve is `TelegramExponentialBackoff`'s default
    /// and nothing overrides it in production. Actor reference — state
    /// survives across ticks even though the loop itself is a struct.
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
        // 2026-09-06: the chat-id-only injection points stay for callers that
        // have no topic to name (the test target, embedders). nil means "use
        // the topic-aware default"; a supplied closure is adapted and simply
        // never sees the thread.
        sendMessage: (@Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Void)? = nil,
        sendPhoto: (@Sendable (_ token: String, _ chatId: Int, _ imagePath: String, _ caption: String?) async throws -> Void)? = nil,
        sendChatAction: (@Sendable (_ token: String, _ chatId: Int, _ action: String) async throws -> Void)? = nil,
        answerCallbackQuery: @escaping @Sendable (_ token: String, _ callbackId: String, _ text: String) async throws -> Void = TelegramPollLoop.defaultAnswerCallbackQuery,
        sendMessageReturningId: (@Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Int)? = nil,
        sendRichMessageDraft: (@Sendable (_ token: String, _ destination: TelegramDestination, _ draftId: Int, _ richMessage: TelegramInputRichMessage) async throws -> Void)? = nil,
        sendRichMessage: (@Sendable (_ token: String, _ destination: TelegramDestination, _ richMessage: TelegramInputRichMessage) async throws -> Int)? = nil,
        sendMessageWithReplyMarkupReturningId: (@Sendable (_ token: String, _ destination: TelegramDestination, _ text: String, _ replyMarkup: JSONValue) async throws -> Int)? = nil,
        editMessageText: @escaping @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void = TelegramPollLoop.defaultEditMessageText,
        sendMessageWithReplyMarkup: (@Sendable (_ token: String, _ chatId: Int, _ text: String, _ replyMarkup: JSONValue) async throws -> Void)? = nil,
        editMessageTextWithReplyMarkup: (@Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String, _ replyMarkup: JSONValue?) async throws -> Void)? = nil,
        draftEditIntervalSeconds: TimeInterval = 2.0,
        turnCardMinimumEditIntervalSeconds: TimeInterval = 5,
        turnCardHeartbeatNanoseconds: UInt64 = 7_000_000_000,
        turnCardStalledAfterSeconds: TimeInterval = TelegramTurnPresentationRenderer.defaultStalledAfter,
        turnCardClock: @escaping @Sendable () -> Date = Date.init,
        turnCardSleeper: @escaping @Sendable (_ nanoseconds: UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        turnStopConfirmationNanoseconds: UInt64 = 1_500_000_000,
        syncCommandMenu: TelegramCommandMenuSync? = TelegramPollLoop.defaultSyncCommandMenu,
        approvalHandler: (any TelegramApprovalHandling)? = nil,
        chatHandler: TelegramChatHandler? = nil,
        progressChatHandler: TelegramProgressChatHandler? = nil,
        attachmentChatHandler: TelegramProgressChatHandlerWithAttachments? = nil,
        voiceDownloader: (any TelegramMediaDownloading)? = TelegramMediaDownloader(),
        voiceTranscriber: (any TelegramVoiceTranscribing)? = nil,
        onCapabilityDenied: (@Sendable (String) async -> Void)? = nil,
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
        let resolvedDataRoot = dataRoot ?? Self.inferDataRoot(from: offsetURL)
        self.dataRoot = resolvedDataRoot
        self.offsetURL = offsetURL
        if let legacySendMessage = sendMessage {
            self.sendMessage = { token, destination, text in
                try await legacySendMessage(token, destination.chatId, text)
            }
        } else {
            self.sendMessage = Self.defaultSendMessage
        }
        if let legacySendPhoto = sendPhoto {
            self.sendPhoto = { token, destination, path, caption in
                try await legacySendPhoto(token, destination.chatId, path, caption)
            }
        } else {
            self.sendPhoto = Self.defaultSendPhoto
        }
        if let legacySendChatAction = sendChatAction {
            self.sendChatAction = { token, destination, action in
                try await legacySendChatAction(token, destination.chatId, action)
            }
        } else {
            self.sendChatAction = Self.defaultSendChatAction
        }
        self.answerCallbackQuery = answerCallbackQuery
        let resolvedSendMessageReturningId: @Sendable (String, TelegramDestination, String) async throws -> Int
        if let legacySendMessageReturningId = sendMessageReturningId {
            resolvedSendMessageReturningId = { token, destination, text in
                try await legacySendMessageReturningId(token, destination.chatId, text)
            }
        } else {
            resolvedSendMessageReturningId = Self.defaultSendMessageReturningId
        }
        self.sendMessageReturningId = resolvedSendMessageReturningId
        self.sendRichMessageDraft = sendRichMessageDraft
        self.sendRichMessage = sendRichMessage
        self.sendMessageWithReplyMarkupReturningId = sendMessageWithReplyMarkupReturningId
            ?? { token, destination, text, _ in
                try await resolvedSendMessageReturningId(token, destination, text)
            }
        self.editMessageText = editMessageText
        if let legacySendMessageWithReplyMarkup = sendMessageWithReplyMarkup {
            self.sendMessageWithReplyMarkup = { token, destination, text, markup in
                try await legacySendMessageWithReplyMarkup(token, destination.chatId, text, markup)
            }
        } else {
            self.sendMessageWithReplyMarkup = Self.defaultSendMessageWithReplyMarkup
        }
        self.editMessageTextWithReplyMarkup = editMessageTextWithReplyMarkup
            ?? { token, chatId, messageId, text, _ in
                try await editMessageText(token, chatId, messageId, text)
            }
        self.draftEditIntervalSeconds = draftEditIntervalSeconds
        self.turnCardMinimumEditIntervalSeconds = max(0, turnCardMinimumEditIntervalSeconds)
        self.turnCardHeartbeatNanoseconds = turnCardHeartbeatNanoseconds
        self.turnCardStalledAfterSeconds = max(0, turnCardStalledAfterSeconds)
        self.turnCardClock = turnCardClock
        self.turnCardSleeper = turnCardSleeper
        self.turnStopConfirmationNanoseconds = turnStopConfirmationNanoseconds
        let cardLedger = TelegramTurnCardLedger(
            fileURL: resolvedDataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("work_cards.json")
        )
        self.turnCardLedger = cardLedger
        self.turnCardRestartRepairer = TelegramTurnCardRestartRepairer(ledger: cardLedger)
        self.approvalContinuationLedger = TelegramApprovalContinuationLedger(
            fileURL: resolvedDataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("approval_continuations.json")
        )
        self.syncCommandMenu = syncCommandMenu
        self.approvalHandler = approvalHandler
        self.chatHandler = chatHandler
        self.progressChatHandler = progressChatHandler
        self.attachmentChatHandler = attachmentChatHandler
        self.voiceDownloader = voiceDownloader
        self.voiceTranscriber = voiceTranscriber
        self.onCapabilityDenied = onCapabilityDenied
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

    /// True ONLY for a macOS Speech Recognition authorization denial.
    ///
    /// The typed case is matched FIRST — `TelegramVoiceTranscriptionError` is
    /// the error the transcribers actually throw, and pattern-matching it is
    /// exact. The lowercased-string fallback exists for errors that arrive
    /// untyped (an NSError bubbled from a future backend), and is deliberately
    /// narrow: it must not catch `.speechUnavailable`, whose message mentions
    /// speech but is a recognizer-availability problem no TCC switch fixes.
    static func isSpeechPermissionDenial(_ error: Error) -> Bool {
        if let typed = error as? TelegramVoiceTranscriptionError {
            if case .speechPermissionDenied = typed { return true }
            // A typed error that is NOT the denial case is a definitive no —
            // never fall through to the fuzzy string check for it.
            return false
        }
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        return description.contains("speech recognition permission denied")
            || description.contains("speechpermissiondenied")
    }

    /// The exact words a lost turn gets. One sentence: what happened, and what
    /// the sender can do about it. No apology theatre, no invented outcome —
    /// the turn is NOT replayed, so it must not promise one.
    static let lostTurnNotice =
        "I lost my answer to your last message when I restarted — say it again and I'll pick it up."

    /// Tell the sender, at most once, that their turn died mid-flight
    /// (fable51 #9).
    ///
    /// AT MOST ONCE is structural, not bookkeeping (a send failure or crash after
    /// the durable flip means no notice and no retry — the anti-spam trade): the caller has already
    /// flipped the durable claim `processing → outcomeUnknown`, and
    /// `recoverableClaims()` never returns an outcome-unknown claim again. So
    /// a restart loop cannot re-speak this, and the phase flip is the marker.
    /// The notice is sent AFTER that flip on purpose — a crash in between
    /// loses the notice, which is strictly better than a boot loop spamming
    /// the chat.
    ///
    /// Gated on the allowlist because a claim is admitted durably BEFORE
    /// authorization runs: an unauthorized chat can leave a `processing`
    /// claim behind, and it must never receive a word from her.
    func notifyLostTurn(_ claim: TelegramUpdateClaim) async {
        // The flip is the marker. If it didn't happen (a concurrent writer got
        // there first), someone else owns this claim — stay quiet.
        guard claim.phase == .outcomeUnknown,
              let message = claim.update.message else { return }
        guard Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds,
            allowedUserIds: allowedUserIds,
            chatId: message.chatId,
            fromUserId: message.fromUserId
        ) == .allowed else { return }
        do {
            try await sendMessage(token, message.destination, Self.lostTurnNotice)
        } catch {
            // The notice failing is itself worth a receipt — the sender is
            // now silently short one answer AND one explanation.
            await recordError(
                context: "recover_lost_turn_notice",
                error: String(describing: error),
                update: claim.update,
                message: message
            )
        }
    }

    public func tick() async {
        let turnsAlreadyRunning = await turnCoordinator.activeTurnIDs()
        _ = await tickOutcome()
        // Direct/diagnostic callers historically observe the completed turn.
        // The production scheduler calls tickOutcome(), which intentionally
        // returns after admission so the next Telegram poll can receive live
        // controls while this coordinator drains the turn independently. Do
        // not wait on a turn that predated this tick: status/stop ingress must
        // remain usable in direct tests and diagnostics too.
        await turnCoordinator.waitUntilIdle(excluding: turnsAlreadyRunning)
    }

    public func shutdown() async {
        await turnCoordinator.shutdown()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        await repairInterruptedTurnCardsIfNeeded()
        await replayApprovalContinuationsIfNeeded()
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
        await syncCommandMenuIfNeeded()

        let cursor = TelegramOffsetCursor(fileURL: offsetURL)
        var offset: Int
        do {
            offset = try cursor.load()
        } catch {
            await recordError(context: "load_offset", error: String(describing: error))
            return .failed(error: "Telegram offset cursor unavailable: \(error.localizedDescription)")
        }

        // Admit every Telegram update durably before acknowledging it upstream.
        // Pending and queued claims are safe to replay after restart. A claim left in
        // `processing` by a dead process is not replayed automatically because
        // a tool or external send may already have occurred; it is settled as
        // outcome-unknown and the offset advances conservatively.
        let updateInbox = TelegramUpdateInbox(offsetURL: offsetURL)
        let recoveredClaims: [TelegramUpdateClaim]
        do {
            let snapshots = try await updateInbox.recoverableClaims()
            var reconciled: [TelegramUpdateClaim] = []
            reconciled.reserveCapacity(snapshots.count)
            for claim in snapshots {
                // A `.processing` claim owned by a turn running in THIS process
                // is not an orphan: the durable claim stays processing for the
                // whole turn so a crash leaves recoverable ingress, and this
                // pass runs on every tick.
                if claim.phase == .processing,
                   await turnCoordinator.isUpdateProcessing(claim.updateId) {
                    reconciled.append(claim)
                } else if claim.phase == .processing {
                    let quarantined = try await updateInbox.transition(
                        updateId: claim.updateId,
                        from: [.processing],
                        to: .outcomeUnknown
                    )
                    reconciled.append(quarantined)
                    await recordError(
                        context: "recover_update_outcome_unknown",
                        error: "update \(claim.updateId) was processing when the prior Telegram loop stopped; automatic replay was suppressed"
                    )
                    // Not replaying is right — the turn's tool effects may
                    // already have landed. Saying nothing was not: the sender's
                    // message was consumed and only errors.jsonl knew. Speak
                    // once, on the surface it happened on.
                    await notifyLostTurn(quarantined)
                } else {
                    reconciled.append(claim)
                }
            }
            recoveredClaims = reconciled
        } catch {
            await recordError(context: "update_inbox_load", error: String(describing: error))
            return .failed(error: "Telegram durable inbox unavailable: \(error.localizedDescription)")
        }

        if let acknowledged = recoveredClaims
            .filter({ $0.phase != .pending })
            .map({ $0.updateId + 1 })
            .max(),
           acknowledged > offset {
            guard let advanced = await persistOffset(acknowledged, cursor: cursor) else {
                return .failed(error: "Telegram could not reconcile durable inbox offset")
            }
            offset = advanced
        }

        let result: TelegramPollResult
        var recoveredWork = recoveredClaims.contains { $0.phase == .pending }
        if !recoveredWork {
            for claim in recoveredClaims where claim.phase == .queued {
                let destination = claim.update.message?.destination ?? .chat(0)
                if await turnCoordinator.queuedTurn(
                    destination: destination,
                    updateId: claim.updateId
                ) == nil {
                    recoveredWork = true
                    break
                }
            }
        }
        if recoveredWork {
            // The durable inbox is the transport for this tick. Do not make a
            // network outage block already-admitted user work.
            result = TelegramPollResult(updates: [], nextOffset: offset)
        } else {
            guard await pollBackoff.shouldAttempt() else {
                return .backingOff(reason: "Telegram poll backoff active")
            }
            do {
                result = try await bot.longPoll(
                    token: token, offset: offset,
                    timeoutSeconds: 25, session: session
                )
            } catch is CancellationError {
                // Scheduler/app shutdown is expected control flow. It must not
                // write errors.jsonl, advance transport backoff, or make the
                // next launch look like it inherited a network failure.
                return .skipped(reason: "Telegram poll cancelled")
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
        }

        var updatesById: [Int: TelegramUpdate] = [:]
        for update in result.updates { updatesById[update.updateId] = update }
        // Durable bytes win if Telegram returns the same id with a payload that
        // differs from the one already admitted before a crash.
        for claim in recoveredClaims where claim.phase == .pending || claim.phase == .queued {
            updatesById[claim.updateId] = claim.update
        }
        let updates = updatesById.values.sorted { $0.updateId < $1.updateId }

        var persistedOffset = offset
        for candidateUpdate in updates {
            let claim: TelegramUpdateClaim
            do {
                claim = try await updateInbox.ensurePending(candidateUpdate)
            } catch {
                await recordError(context: "update_inbox_claim", error: String(describing: error), update: candidateUpdate)
                return .failed(error: "Telegram update \(candidateUpdate.updateId) could not be claimed durably")
            }
            // The bytes already admitted to disk are canonical for this update
            // id. Never process a later transport representation instead.
            let update = claim.update
            switch claim.phase {
            case .completed, .outcomeUnknown:
                continue
            case .processing:
                // 2026-09-06: a turn running in this process now holds its
                // claim in `.processing` for the whole turn. Leave that one
                // alone — settling it here would tell the sender the answer
                // was lost while it is still being written.
                if await turnCoordinator.isUpdateProcessing(claim.updateId) {
                    continue
                }
                // Same-process ticks are single-flight, so this can only be an
                // unexpected persisted ambiguity. Never duplicate effects.
                _ = try? await updateInbox.transition(
                    updateId: update.updateId,
                    from: [.processing],
                    to: .outcomeUnknown
                )
                continue
            case .pending:
                break
            case .queued:
                // The coordinator already mirrors this durable claim in the
                // current process. Rehydrate only after restart; otherwise
                // every control/status poll would duplicate the queue card.
                if await turnCoordinator.queuedTurn(
                    destination: claim.update.message?.destination ?? .chat(0),
                    updateId: claim.updateId
                ) != nil {
                    continue
                }
                break
            }
            await recordSeen(update: update)
            let updateOffset = update.updateId + 1
            if updateOffset > persistedOffset {
                guard let advanced = await persistOffset(updateOffset, cursor: cursor) else {
                    return .failed(error: "Telegram update \(update.updateId) was claimed but its offset could not be persisted")
                }
                persistedOffset = advanced
            }
            if claim.phase == .pending {
            // 2026-09-06: the running id is registered BEFORE the claim enters
            // `.processing`, never after. Registering it only when the detached
            // turn started left a window — ingress still had voice
            // transcription and photo download to await — in which the
            // every-tick recovery pass saw a `.processing` claim with no
            // in-process owner and quarantined a live turn as outcome-unknown.
            // The sender got the lost-turn notice and then the reply.
            await turnCoordinator.beginUpdateProcessing(update.updateId)
            do {
                let processing = try await updateInbox.transition(
                    updateId: update.updateId,
                    from: [.pending],
                    to: .processing
                )
                guard processing.phase == .processing else {
                    await turnCoordinator.endUpdateProcessing(update.updateId)
                    return .failed(error: "Telegram update \(update.updateId) could not enter processing")
                }
            } catch {
                await turnCoordinator.endUpdateProcessing(update.updateId)
                await recordError(context: "update_inbox_processing", error: String(describing: error), update: update)
                return .failed(error: "Telegram update \(update.updateId) could not enter processing")
            }
            }

            var shouldCompleteClaim = true
            updateProcessing: do {
            if let callback = update.callbackQuery,
               await handleQueuedTurnControlCallback(update: update, callback: callback) {
                break updateProcessing
            }
            if let callback = update.callbackQuery,
               await handleTurnControlCallback(update: update, callback: callback) {
                break updateProcessing
            }
            if let callback = update.callbackQuery,
               await handleModelSelectionCallback(update: update, callback: callback) {
                break updateProcessing
            }
            if let callback = update.callbackQuery,
               await handleApprovalCallback(update: update, callback: callback) {
                break updateProcessing
            }
            guard let msg = update.message else {
                await recordBlocked(reason: "no_message", update: update, message: nil, text: nil)
                break updateProcessing
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
            let unsupportedAttachmentKind = Self.unsupportedAttachmentKind(from: msg)
            guard textFromMessage?.isEmpty == false
                    || voiceAttachment != nil
                    || photoAttachment != nil
                    || unsupportedAttachmentKind != nil else {
                await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
                break updateProcessing
            }
            // Allowlist enforcement applies BEFORE slash dispatch so commands
            // from unauthorized users can't run either. The allowlist is the
            // ONLY perimeter in front of execution (YOLO removed the inner
            // gates 2026-08-12), so an EMPTY allowlist FAILS CLOSED: every
            // message drops with an allowlist_empty receipt until the owner
            // adds an approved sender or group. The old back-compat branch
            // (both sets empty → accept all) meant one config wipe silently
            // opened the front door — User's call, 2026-08-13: "if they don't
            // put something in there, have it fail closed."
            // Match rule: chat.id ∈ allowedChatIds OR from.id ∈ allowedUserIds.
            switch Self.inboundAuthorizationDecision(
                allowedChatIds: allowedChatIds,
                allowedUserIds: allowedUserIds,
                chatId: msg.chatId,
                fromUserId: msg.fromUserId
            ) {
            case .allowlistEmpty:
                FileHandle.standardError.write(Data("TelegramPollLoop: dropping update \(update.updateId) — allowlist is EMPTY (fail-closed); add an approved sender/group in Telegram settings\n".utf8))
                await recordBlocked(reason: "allowlist_empty_fail_closed", update: update, message: msg, text: textFromMessage)
                break updateProcessing
            case .notAllowlisted:
                FileHandle.standardError.write(Data("TelegramPollLoop: dropping update \(update.updateId) — chat_id \(msg.chatId) / from \(msg.fromUserId ?? 0) not allowlisted\n".utf8))
                await recordBlocked(reason: "not_allowlisted", update: update, message: msg, text: textFromMessage)
                break updateProcessing
            case .allowed:
                break
            }
            if let unsupportedAttachmentKind,
               textFromMessage?.isEmpty != false, voiceAttachment == nil, photoAttachment == nil {
                // Preserve the no-turn drop, but an admitted sender deserves
                // truthful evidence. Never reply to outsiders or unmentioned
                // group traffic, and never manufacture attachment text.
                await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
                if !Self.dropsForMissingMention(requireMention: requireMention, chatId: msg.chatId, text: "") {
                    await notifyUnsupportedAttachment(kind: unsupportedAttachmentKind, update: update, message: msg)
                }
                break updateProcessing
            }
            let text: String
            let receiptKind: String
            // 2026-09-06: a CAPTIONED voice note used to take this branch and
            // its audio was never downloaded — the caption alone became the
            // turn and the recording was dropped in silence. Text wins only
            // when there is no voice to hear, or when nothing here can hear it
            // (no downloader/transcriber), which keeps the old text route and
            // the old "not configured" notice exactly as they were.
            if let existing = textFromMessage, !existing.isEmpty,
               voiceAttachment == nil || voiceDownloader == nil || voiceTranscriber == nil {
                text = existing
                receiptKind = "reply"
            } else if let voiceAttachment {
                // attachmentChatHandler is text-capable too (production now
                // wires ONLY it — gpt-5.5 delta catch: voice notes were
                // blocked as chat_handler_not_configured after the rewire).
                guard chatHandler != nil || progressChatHandler != nil
                        || attachmentChatHandler != nil else {
                    await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: nil)
                    break updateProcessing
                }
                guard let voiceDownloader, let voiceTranscriber else {
                    let notice = "(I got your voice note, but Telegram voice transcription is not configured.)"
                    do {
                        try await sendMessage(token, msg.destination, notice)
                        await recordReceipt(kind: "voice_transcription_unavailable", update: update, message: msg, text: "[Telegram voice message]", reply: notice)
                    } catch {
                        await recordError(context: "send_voice_unavailable_notice", error: String(describing: error), update: update, message: msg, text: nil)
                    }
                    break updateProcessing
                }
                do {
                    try await sendChatAction(token, msg.destination, "typing")
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: voice typing action failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                }
                do {
                    if await !voicePermissionNotice.sent {
                        try await sendMessage(token, msg.destination, "Transcribing voice message")
                    }
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
                    await voicePermissionNotice.setSent(false)
                    let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawTranscript.isEmpty else {
                        throw TelegramVoiceTranscriptionError.malformedResponse
                    }
                    // W5 L1#11: domain-noun correction runs ONLY here, on the
                    // transcript lane. Typed Telegram text never passes through
                    // it. The original stays in the receipt row.
                    let correction = TelegramTranscriptTermCorrection.correct(
                        rawTranscript,
                        extra: TelegramTranscriptTermCorrection.installTerms(dataRoot: dataRoot)
                    )
                    let transcript = correction.text
                    await recordVoiceTranscription(
                        update: update,
                        message: msg,
                        attachment: downloaded,
                        transcription: transcription,
                        correction: correction
                    )
                    // 2026-09-06: a caption on a voice note is the sender's
                    // typed instruction ABOUT the recording, so it leads and
                    // the transcript follows.
                    if let caption = textFromMessage, !caption.isEmpty {
                        text = """
                        \(caption)

                        [Telegram voice message]
                        Transcript: \(transcript)
                        """
                    } else {
                        text = """
                        [Telegram voice message]
                        Transcript: \(transcript)
                        """
                    }
                    receiptKind = "voice_reply"
                } catch where error is CancellationError || Self.isSpeechPermissionDenial(error) {
                    let awaitingPermission = Self.isSpeechPermissionDenial(error)
                    if awaitingPermission, await !voicePermissionNotice.sent {
                        await recordError(context: "voice_transcription", error: String(describing: error), update: update, message: msg, text: nil)
                        await onCapabilityDenied?("speechRecognition")
                        do {
                            try await sendMessage(token, msg.destination, "The voice note is saved. On the Mac, open Telegram settings → Set up Telegram voice to allow speech recognition. Transcription will retry automatically after access is granted.")
                            await voicePermissionNotice.setSent(true)
                        } catch {
                            await recordError(context: "send_voice_permission_notice", error: String(describing: error), update: update, message: msg, text: nil)
                        }
                    }
                    // Transcription runs before the turn is registered and before
                    // Agent has any durable user-visible outcome for this update.
                    // App/scheduler cancellation must therefore release the
                    // admitted claim for replay. Treating it like an ordinary
                    // media failure inherits the canceled task when sending the
                    // notice, then silently settles the inbox row as completed.
                    // 2026-09-06: no turn runs for this update any more, so the
                    // ingress registration goes with the claim.
                    await turnCoordinator.endUpdateProcessing(update.updateId)
                    do {
                        // 2026-09-06: `.queued` belongs in the from-set for the
                        // same reason the photo branch takes it — a claim
                        // rehydrated as queued after a restart never re-enters
                        // `.processing`, so cancelling mid-transcription made
                        // this transition a silent no-op and the tick returned
                        // .failed instead of releasing the claim for replay.
                        let pending = try await updateInbox.transition(
                            updateId: update.updateId,
                            from: [.processing, .queued],
                            to: .pending
                        )
                        guard pending.phase == .pending else {
                            return .failed(error: "Telegram voice update \(update.updateId) could not be released for retry")
                        }
                    } catch {
                        await recordError(
                            context: "voice_transcription_retry_release",
                            error: String(describing: error),
                            update: update,
                            message: msg,
                            text: nil
                        )
                        return .failed(error: "Telegram voice update \(update.updateId) could not be released for retry")
                    }
                    // Permission is resolved by the explained foreground setup
                    // control. Keep the original update durable across restarts,
                    // and let other messages proceed while this note waits.
                    if awaitingPermission { continue }
                    return .skipped(reason: "Telegram voice transcription cancelled; durable update retained for retry")
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: voice transcription failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                    await recordError(context: "voice_transcription", error: String(describing: error), update: update, message: msg, text: nil)
                    // Ordinary media failures settle with a notice; permission
                    // failures above retain the original note for replay.
                    let notice = Self.voiceTranscriptionNotice(for: error)
                    do {
                        try await sendMessage(token, msg.destination, notice)
                        await recordReceipt(kind: "voice_transcription_error", update: update, message: msg, text: "[Telegram voice message]", reply: notice)
                    } catch {
                        await recordError(context: "send_voice_error_notice", error: String(describing: error), update: update, message: msg, text: nil)
                    }
                    break updateProcessing
                }
            } else if photoAttachment != nil {
                // telegram-vision-in: a photo-only send with no text/caption.
                // The image is downloaded + injected below; the model needs a
                // non-empty prompt or the chat turn is rejected as bad input.
                guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
                    await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: nil)
                    break updateProcessing
                }
                text = "[The user sent an image with no caption. Look at it and respond.]"
                receiptKind = "photo_reply"
            } else {
                await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
                break updateProcessing
            }
            if text.hasPrefix("/") {
                // 2026-09-06: a group delivers `/cmd@OtherBot` to every bot in
                // the room, and slash dispatch runs BEFORE the mention filter.
                // The command parser stripped the `@suffix` without reading it,
                // so `/stop@SomeOtherBot` stopped this agent's own turn. A
                // command addressed to another bot is dropped here; a bare
                // `/cmd` and `/cmd@ThisBot` are handled as before, and an
                // unknown own-identity (getMe failed) stays permissive.
                if let addressedBot = TelegramCommandRegistry.addressedBotUsername(text: text),
                   let ownUsername = await resolveBotUsername(),
                   addressedBot.compare(ownUsername, options: .caseInsensitive) != .orderedSame {
                    await recordBlocked(
                        reason: "command_for_other_bot",
                        update: update,
                        message: msg,
                        text: text
                    )
                    break updateProcessing
                }
                // 2026-09-06: the command runs in its own task and settles its
                // own claim there. Handling it inline meant the poll loop waited
                // out the chat's flood cooldown; detaching only the reply send
                // meant `/restart` armed termination and this claim was marked
                // completed while the reply was still on the wire. The task owns
                // both, so nothing after the reply happens before it is out.
                await runSlashCommandDetached(update: update, message: msg, text: text)
                shouldCompleteClaim = false
                break updateProcessing
            }
            // Non-slash text: route to chat-orchestration when wired.
            guard chatHandler != nil || progressChatHandler != nil || attachmentChatHandler != nil else {
                await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: text)
                break updateProcessing
            }
            // requireMention: in group/supergroup chats (negative chat.id),
            // drop non-mention messages so the bot doesn't reply to every
            // group line. Private chats (positive chat.id) bypass — every
            // message is addressed to the bot. Mention proxy: text must
            // contain "@" (full bot-username verification would need a
            // getMe() round-trip we don't cache yet).
            if Self.dropsForMissingMention(
                requireMention: requireMention,
                chatId: msg.chatId,
                text: text
            ) {
                FileHandle.standardError.write(Data("TelegramPollLoop: dropping update \(update.updateId) — requireMention=true, no @-mention in group chat \(msg.chatId)\n".utf8))
                await recordBlocked(reason: "mention_required", update: update, message: msg, text: text)
                break updateProcessing
            }
            if let unsupportedAttachmentKind {
                // A supported text caption still follows its original route;
                // the notice makes clear that its attached file was not read.
                await notifyUnsupportedAttachment(kind: unsupportedAttachmentKind, update: update, message: msg)
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
                        try await sendMessage(token, msg.destination, notice)
                        await recordReceipt(kind: "photo_dropped", update: update, message: msg, text: text, reply: notice)
                    } catch {
                        await recordError(context: "send_photo_dropped_notice", error: String(describing: error), update: update, message: msg, text: text)
                    }
                    break updateProcessing
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
                } catch is CancellationError {
                    // 2026-09-06: the same release the voice branch does. The
                    // download runs before the turn is registered and before the
                    // sender has any durable outcome, so app/scheduler
                    // cancellation must return the admitted claim for replay.
                    // Treated as an ordinary download failure it inherited the
                    // cancelled task when sending the notice and then settled the
                    // claim completed — the photo was consumed and never answered.
                    // A rehydrated queued claim is released too: its turn never
                    // started either.
                    await turnCoordinator.endUpdateProcessing(update.updateId)
                    do {
                        let pending = try await updateInbox.transition(
                            updateId: update.updateId,
                            from: [.processing, .queued],
                            to: .pending
                        )
                        guard pending.phase == .pending else {
                            return .failed(error: "Telegram photo update \(update.updateId) could not be released for retry")
                        }
                    } catch {
                        await recordError(
                            context: "photo_download_retry_release",
                            error: String(describing: error),
                            update: update,
                            message: msg,
                            text: text
                        )
                        return .failed(error: "Telegram photo update \(update.updateId) was cancelled but could not be released for retry")
                    }
                    return .skipped(reason: "Telegram photo download cancelled; durable update retained for retry")
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
                        try await sendMessage(token, msg.destination, notice)
                        await recordReceipt(kind: "photo_dropped", update: update, message: msg, text: text, reply: notice)
                    } catch {
                        await recordError(context: "send_photo_dropped_notice", error: String(describing: error), update: update, message: msg, text: text)
                    }
                    break updateProcessing
                }
            }
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
            // Admission and task creation are one actor operation. Creating the
            // Task first and handing it to beginTurn afterward let the body cross
            // provider/tool/send boundaries before a concurrent approval
            // continuation won the chat slot and the loser was cancelled.
            // `stagedImageAttachments` is accumulated while decoding this
            // update. Freeze that mutable local before it crosses the
            // coordinator's @Sendable task boundary.
            let turnImageAttachments = stagedImageAttachments
            let turnOperation: @Sendable (UUID) async -> Void = { turnId in
                    if let queuedMessageId = claim.queueAcknowledgementMessageId {
                        let preview = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
                        try? await editMessageTextWithReplyMarkup(
                            token,
                            msg.chatId,
                            queuedMessageId,
                            "Running now · \(preview)",
                            TelegramTurnControlCallback.clearedReplyMarkup
                        )
                    }
                    // This process owns the update from here until the settle
                    // below; the recovery pass must not mistake a running turn
                    // for one a dead process abandoned. 2026-09-06: registered
                    // BEFORE the durable transition, never after — a tick that
                    // landed in between saw `.processing` with no owner and
                    // quarantined a live turn.
                    await turnCoordinator.beginUpdateProcessing(update.updateId)
                    do {
                        let processing = try await updateInbox.transition(
                            updateId: update.updateId,
                            from: [.queued],
                            to: .processing
                        )
                        guard processing.phase == .processing else {
                            await turnCoordinator.endUpdateProcessing(update.updateId)
                            return
                        }
                        // 2026-09-06: `.completed` used to be written HERE,
                        // before the card and the chat handler ran. A crash in
                        // the turn then left a claim recovery never reopens
                        // (it opens pending/processing/queued only), so the
                        // sender's message was consumed in silence. The claim
                        // now settles after the reply has been handed off.
                    } catch {
                        await turnCoordinator.endUpdateProcessing(update.updateId)
                        await recordError(
                            context: "queued_update_start",
                            error: String(describing: error),
                            update: update,
                            message: msg,
                            text: text
                        )
                        return
                    }
                    let card = makeTurnProgressCard(
                        destination: msg.destination,
                        turnId: turnId,
                        errorContext: "turn_card",
                        update: update,
                        message: msg,
                        text: text
                    )
                    guard await turnCoordinator.attachCard(
                        card,
                        destination: msg.destination,
                        turnId: turnId
                    ) else {
                        _ = try? await updateInbox.transition(
                            updateId: update.updateId,
                            from: [.processing],
                            to: .outcomeUnknown
                        )
                        // 2026-09-06: this exit used to leave the update id in
                        // the running set forever, so a later `.processing`
                        // claim for it could never be recovered.
                        await turnCoordinator.endUpdateProcessing(update.updateId)
                        return
                    }
                    await card.start()
                    await card.transition(.working(action: nil))
                    let delivery = makeAssistantDelivery(
                        destination: msg.destination,
                        turnId: turnId,
                        errorContext: "send_reply",
                        update: update,
                        message: msg,
                        text: text
                    )
                do {
                    let typingTask = await startTypingHeartbeat(destination: msg.destination)
                    defer { typingTask?.cancel() }
                    let progress = makeProgressSink(delivery: delivery, card: card)
                    let generatedImages = TelegramGeneratedImageCollector()
                    let capturingProgress: TelegramChatProgressSink = { event in
                        await generatedImages.record(event)
                        await progress(event)
                    }
                    let reply = try await runChatHandlerWithRetry(
                        destination: msg.destination,
                        text: text,
                        attachments: turnImageAttachments,
                        progress: capturingProgress,
                        replyTo: msg.replyTo,
                        fromUserId: msg.fromUserId
                    )
                    try Task.checkCancellation()
                    if !reply.isEmpty {
                        let deliveryOutcome = await delivery.finalize(reply: reply)
                        switch deliveryOutcome {
                        case .delivered:
                            let imagePaths = await generatedImages.snapshot()
                            switch await deliverGeneratedImages(
                                imagePaths,
                                destination: msg.destination,
                                errorContext: "send_generated_image",
                                update: update,
                                message: msg,
                                text: text
                            ) {
                            case .delivered:
                                await recordReceipt(kind: receiptKind, update: update, message: msg, text: text, reply: reply)
                                await card.transition(.completed(summary: "Reply delivered"))
                            case .failed(let reason):
                                await card.transition(.failed(
                                    reason: "Reply text delivered, but generated media failed: \(reason)"
                                ))
                            case .outcomeUnknown(let reason):
                                await card.transition(.outcomeUnknown(
                                    reason: "Reply text delivered; generated media delivery could not be confirmed: \(reason)"
                                ))
                            }
                        case .failed(let reason):
                            await recordError(context: "send_reply", error: reason, update: update, message: msg, text: text)
                            await card.transition(.failed(reason: "Reply delivery failed: \(reason)"))
                        case .outcomeUnknown(let reason):
                            await recordError(context: "send_reply_outcome_unknown", error: reason, update: update, message: msg, text: text)
                            await card.transition(.outcomeUnknown(
                                reason: "Reply delivery could not be confirmed: \(reason)"
                            ))
                        }
                    } else {
                        // A live draft must not dangle with partial text when the
                        // turn produced nothing. If no draft exists, send the
                        // notice as a new message so the failure is never silent.
                        let notice = "(the reply came back empty - check the Mac error log)"
                        await recordError(context: "empty_reply", error: "chat handler returned empty output", update: update, message: msg, text: text)
                        await card.transition(.failed(reason: "The reply came back empty"))
                        await deliverDraftOrSendNotice(
                            notice,
                            delivery: delivery,
                            receiptKind: "empty_reply_notice",
                            sendErrorContext: "send_empty_reply_notice",
                            update: update,
                            message: msg,
                            text: text
                        )
                    }
                } catch is CancellationError {
                    let notice = "(Telegram turn stopped.)"
                    await card.transition(.canceled(reason: "Stopped by user"))
                    if await delivery.abortDelivering(notice: notice) {
                        await recordReceipt(kind: "stopped_notice", update: update, message: msg, text: text, reply: notice)
                    } else {
                        // The canceled work card is already durable evidence.
                        // Do not manufacture a second standalone notice when
                        // no assistant draft exists to terminalize.
                        await recordReceipt(kind: "turn_canceled", update: update, message: msg, text: text, reply: notice)
                    }
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: chat handler failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                    await recordError(context: "chat_handler", error: String(describing: error), update: update, message: msg, text: text)
                    await card.transition(.failed(reason: String(describing: error)))
                    let notice = Self.chatErrorNotice(for: error)
                    // Prefer editing the partial draft into the error notice; a
                    // separate message only when there's no draft (or the edit
                    // failed).
                    if await delivery.abortDelivering(notice: notice) {
                        await recordReceipt(kind: "error_notice", update: update, message: msg, text: text, reply: notice)
                    } else {
                        do {
                            try await sendMessage(token, msg.destination, notice)
                            await recordReceipt(kind: "error_notice", update: update, message: msg, text: text, reply: notice)
                        } catch {
                            await recordError(context: "send_error_notice", error: String(describing: error), update: update, message: msg, text: text)
                        }
                    }
                }
                // 2026-09-06: the reply (or its honest notice) has been handed
                // off, so this update is finished. A crash before this point
                // leaves `.processing`, which restart recovery settles as
                // outcome-unknown and tells the sender about.
                do {
                    _ = try await updateInbox.transition(
                        updateId: update.updateId,
                        from: [.processing],
                        to: .completed
                    )
                } catch {
                    await recordError(
                        context: "queued_update_complete",
                        error: String(describing: error),
                        update: update,
                        message: msg,
                        text: text
                    )
                }
                await turnCoordinator.endUpdateProcessing(update.updateId)
            }
            if await turnCoordinator.startTrackedTurn(
                destination: msg.destination,
                text: text,
                priority: .userInitiated,
                operation: turnOperation
            ) != nil {
                shouldCompleteClaim = false
            } else {
                guard await turnCoordinator.canEnqueue(destination: msg.destination) else {
                    let notice = "The Telegram queue is full. Let one of the 20 queued messages finish, or remove one, then try again."
                    do {
                        try await sendMessage(token, msg.destination, notice)
                        await recordReceipt(kind: "queue_full_notice", update: update, message: msg, text: text, reply: notice)
                    } catch {
                        await recordError(context: "send_queue_full_notice", error: String(describing: error), update: update, message: msg, text: text)
                    }
                    break updateProcessing
                }
                let durableQueued: TelegramUpdateClaim
                do {
                    durableQueued = try await updateInbox.transition(
                        updateId: update.updateId,
                        from: [.processing],
                        to: .queued
                    )
                    guard durableQueued.phase == .queued else {
                        await recordError(context: "queue_update", error: "durable queue transition failed", update: update, message: msg, text: text)
                        break updateProcessing
                    }
                } catch {
                    await recordError(context: "queue_update", error: String(describing: error), update: update, message: msg, text: text)
                    break updateProcessing
                }
                let preview = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
                var acknowledgementMessageId = durableQueued.queueAcknowledgementMessageId
                if acknowledgementMessageId == nil {
                    do {
                        let sentMessageId = try await sendMessageWithReplyMarkupReturningId(
                            token,
                            msg.destination,
                            "Queued · \(preview)",
                            TelegramQueuedTurnControlCallback.replyMarkup(updateId: update.updateId)
                        )
                        acknowledgementMessageId = sentMessageId
                        do {
                            let recorded = try await updateInbox.recordQueueAcknowledgement(
                                updateId: update.updateId,
                                messageId: sentMessageId
                            )
                            guard recorded.phase == .queued,
                                  recorded.queueAcknowledgementMessageId == sentMessageId else {
                                await recordError(context: "queue_acknowledgement_record", error: "durable acknowledgement binding failed", update: update, message: msg, text: text)
                                break updateProcessing
                            }
                        } catch {
                            await recordError(context: "queue_acknowledgement_record", error: String(describing: error), update: update, message: msg, text: text)
                        }
                        await recordReceipt(kind: "queued_notice", update: update, message: msg, text: text, reply: "Queued")
                    } catch {
                        await recordError(context: "send_queued_notice", error: String(describing: error), update: update, message: msg, text: text)
                    }
                }
                let queuePosition = await turnCoordinator.enqueueTrackedTurn(
                    updateId: update.updateId,
                    destination: msg.destination,
                    text: text,
                    acknowledgementMessageId: acknowledgementMessageId,
                    operation: turnOperation,
                    onStart: { messageId in
                        guard let messageId else { return }
                        try? await editMessageTextWithReplyMarkup(
                            token,
                            msg.chatId,
                            messageId,
                            "Running now · \(preview)",
                            TelegramTurnControlCallback.clearedReplyMarkup
                        )
                    }
                )
                guard queuePosition != nil else {
                    _ = try? await updateInbox.transition(
                        updateId: update.updateId,
                        from: [.queued],
                        to: .completed
                    )
                    break updateProcessing
                }
                shouldCompleteClaim = false
            }
            await turnCoordinator.recordLastUserMessage(destination: msg.destination, text: text)
            }
            guard shouldCompleteClaim else { continue }
            // 2026-09-06: the claim settles here, so no turn owns it in this
            // process any more. Release the ingress registration with it, or
            // the set grows for the life of the process.
            await turnCoordinator.endUpdateProcessing(update.updateId)
            do {
                // `.queued` belongs in the from-set: a claim rehydrated as
                // queued after restart never re-enters `.processing`, and if
                // its handling exits WITHOUT re-enqueueing (the re-enqueue
                // paths set shouldCompleteClaim = false) it is finished. With
                // `[.processing]` alone the transition silently no-op'd, the
                // tick returned .failed, and the still-queued claim made every
                // later tick skip getUpdates and replay the same failure
                // forever.
                let completed = try await updateInbox.transition(
                    updateId: update.updateId,
                    from: [.processing, .queued],
                    to: .completed
                )
                guard completed.phase == .completed else {
                    return .failed(error: "Telegram update \(update.updateId) could not be settled")
                }
            } catch {
                await recordError(context: "update_inbox_complete", error: String(describing: error), update: update)
                return .failed(error: "Telegram update \(update.updateId) completed but its durable claim could not settle")
            }
        }

        let finalOffset = max(persistedOffset, result.nextOffset)
        if finalOffset != persistedOffset || result.updates.isEmpty {
            guard await persistOffset(finalOffset, cursor: cursor) != nil else {
                return .failed(error: "Telegram final poll offset could not be persisted")
            }
        }
        await updateInbox.pruneTerminalClaims()
        return .completed(result: "Telegram poll processed \(updates.count) update(s)")
    }
}
