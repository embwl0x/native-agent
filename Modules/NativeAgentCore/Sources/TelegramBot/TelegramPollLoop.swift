import AuthoredCapabilities
import Foundation
import ApprovalInbox
import NativeAgentCore
import MacControl
import os
import PersistenceCore
import BackgroundLoops
import ProviderRouting
import TurnTrace
import Transcripts
import ChatOrchestration
import Experiences

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
    let longPollSession = TelegramLongPollSession()
    public var lastSuccessfulPollAt: Date? { get async { await longPollSession.lastSuccessfulPollAt } }
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
        text: String,
        entities: JSONValue? = nil,
        botUsername: String? = nil
    ) -> Bool {
        guard requireMention && chatId < 0 else { return false }
        guard let botUsername, case .array(let entities)? = entities else { return true }
        let source = text as NSString
        return !entities.contains { entity in
            guard case .object(let fields) = entity,
                  _tgJSONString(fields["type"]) == "mention",
                  let offset = _tgJSONInt(fields["offset"]),
                  let length = _tgJSONInt(fields["length"]),
                  offset >= 0, length > 0, offset <= source.length,
                  length <= source.length - offset else { return false }
            return source.substring(with: NSRange(location: offset, length: length))
                .compare("@\(botUsername)", options: .caseInsensitive) == .orderedSame
        }
    }
    let offsetURL: URL
    let legacyOffsetURL: URL
    var botIdentity: String { String(token.prefix { $0 != ":" }) }
    // 2026-09-06: every SEND carries a TelegramDestination so a forum topic's
    // reply lands in that topic. Edits and callback answers are addressed by
    // message id and keep taking a bare chat id — Telegram takes no thread on
    // those.
    let sendMessage: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String) async throws -> Void
    let sendPhoto: @Sendable (_ token: String, _ destination: TelegramDestination, _ imagePath: String, _ imageData: Data, _ caption: String?) async throws -> Void
    let sendChatAction: @Sendable (_ token: String, _ destination: TelegramDestination, _ action: String) async throws -> Void
    let answerCallbackQuery: @Sendable (_ token: String, _ callbackId: String, _ text: String) async throws -> Void
    let syncCommandMenu: TelegramCommandMenuSync?
    let approvalHandler: (any TelegramApprovalHandling)?
    let attachmentChatHandler: TelegramProgressChatHandlerWithAttachments?
    let mediaDownloader = TelegramMediaDownloader()
    let voiceTranscriber: SwiftAppleSpeechTranscriber?
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
    let photoMaxBytes: Int
    let turnCoordinator: TelegramTurnCoordinator
    let revokeDriverControl: @Sendable () async -> Void
    // chat-smoothness phase 5: growing-draft transport + cadence.
    let sendMessageReturningId: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String) async throws -> Int
    let sendRichMessageDraft: @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ draftId: Int,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Void
    let sendRichMessage: @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Int
    let sendMessageWithReplyMarkupReturningId: @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ text: String,
        _ replyMarkup: JSONValue
    ) async throws -> Int
    let editMessageText: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void
    let sendMessageWithReplyMarkup: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String, _ replyMarkup: JSONValue) async throws -> Void
    let editMessageTextWithReplyMarkup: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String, _ replyMarkup: JSONValue?) async throws -> Void
    let deleteMessage: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int) async throws -> Void
    let turnCardLedger: TelegramTurnCardLedger
    let turnCardRestartRepairer: TelegramTurnCardRestartRepairer
    /// 2026-09-06: durable record of an approval continuation that has been
    /// admitted but not yet answered. The tool has ALREADY run by then and the
    /// approval is resolved, so a restart in this window used to lose the
    /// follow-up for good — a second `/approve` is refused as not pending.
    let approvalInbox: SwiftNativeApprovalInbox
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
        revokeDriverControl: @escaping @Sendable () async -> Void,
        allowedChatIds: Set<Int64> = [],
        allowedUserIds: Set<Int64> = [],
        requireMention: Bool = false,
        bot: SwiftNativeTelegramBot = SwiftNativeTelegramBot(),
        dataRoot: URL? = nil,
        offsetURL: URL = defaultTelegramOffsetURL(),
        answerCallbackQuery: @escaping @Sendable (_ token: String, _ callbackId: String, _ text: String) async throws -> Void = TelegramPollLoop.defaultAnswerCallbackQuery,
        editMessageText: @escaping @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void = TelegramPollLoop.defaultEditMessageText,
        syncCommandMenu: TelegramCommandMenuSync? = TelegramPollLoop.defaultSyncCommandMenu,
        approvalHandler: (any TelegramApprovalHandling)? = nil,
        attachmentChatHandler: TelegramProgressChatHandlerWithAttachments? = nil,
        voiceTranscriber: SwiftAppleSpeechTranscriber? = nil,
        onCapabilityDenied: (@Sendable (String) async -> Void)? = nil,
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes,
        photoMaxBytes: Int = TelegramPollLoop.defaultPhotoMaxBytes,
        turnCoordinator: TelegramTurnCoordinator = .shared
    ) {
        self.interval = interval
        self.token = token
        self.revokeDriverControl = revokeDriverControl
        self.allowedChatIds = allowedChatIds
        self.allowedUserIds = allowedUserIds
        self.requireMention = requireMention
        self.bot = bot
        let resolvedDataRoot = dataRoot ?? Self.inferDataRoot(from: offsetURL)
        self.dataRoot = resolvedDataRoot
        self.legacyOffsetURL = offsetURL
        self.offsetURL = offsetURL.deletingLastPathComponent()
            .appendingPathComponent("bots", isDirectory: true)
            .appendingPathComponent(Self.botStorageIdentity(token), isDirectory: true)
            .appendingPathComponent(offsetURL.lastPathComponent)
        self.sendMessage = Self.defaultSendMessage
        self.sendPhoto = Self.defaultSendPhoto
        self.sendChatAction = Self.defaultSendChatAction
        self.answerCallbackQuery = answerCallbackQuery
        self.sendMessageReturningId = Self.defaultSendMessageReturningId
        self.sendRichMessageDraft = Self.defaultSendRichMessageDraft
        self.sendRichMessage = Self.defaultSendRichMessage
        self.sendMessageWithReplyMarkupReturningId = Self.defaultSendMessageWithReplyMarkupReturningId
        self.editMessageText = editMessageText
        self.sendMessageWithReplyMarkup = Self.defaultSendMessageWithReplyMarkup
        self.editMessageTextWithReplyMarkup = Self.defaultEditMessageTextWithReplyMarkup
        self.deleteMessage = Self.defaultDeleteMessage
        let cardLedger = TelegramTurnCardLedger(
            fileURL: resolvedDataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("work_cards.json")
        )
        self.turnCardLedger = cardLedger
        self.turnCardRestartRepairer = TelegramTurnCardRestartRepairer(ledger: cardLedger)
        self.approvalInbox = SwiftNativeApprovalInbox(root: resolvedDataRoot)
        self.syncCommandMenu = syncCommandMenu
        self.approvalHandler = approvalHandler
        self.attachmentChatHandler = attachmentChatHandler
        self.voiceTranscriber = voiceTranscriber
        self.onCapabilityDenied = onCapabilityDenied
        self.voiceMaxBytes = max(1, voiceMaxBytes)
        self.photoMaxBytes = max(1, photoMaxBytes)
        self.turnCoordinator = turnCoordinator
        self.pollBackoff = TelegramExponentialBackoff()
        self.commandMenuBackoff = TelegramExponentialBackoff(baseDelay: 5, maxDelay: 300)
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

    public func reconcileSavedReplies() async throws {
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
        for claim in try await inbox.recoverableClaims() where claim.assistantDelivery != nil {
            do { _ = try await recoverReply(claim) }
            catch { _ = await quarantineRecovery(claim, error: error) }
        }
        for approval in try await approvalInbox.list(filter: .resolved) {
            guard case .object(let state)? = approval.chatContinuation, state["done"] != .bool(true),
                  state["assistantDelivery"] != nil, let queued = state["delivery"] else { continue }
            let continuation = try JSONDecoder().decode(TelegramPendingApprovalContinuation.self, from: queued.serializedData(pretty: false))
            guard Self.inboundAuthorizationDecision(allowedChatIds: allowedChatIds, allowedUserIds: allowedUserIds,
                chatId: continuation.chatId, fromUserId: continuation.fromUserId) == .allowed else { continue }
            guard !(await turnCoordinator.snapshot(destination: continuation.destination).isRunning) else { continue }
            _ = try await recoverApprovalAnswer(approvalId: approval.id, destination: continuation.destination)
        }
    }

    private func quarantineRecovery(_ claim: TelegramUpdateClaim, error: Error) async -> TelegramUpdateClaim? {
        do {
            let terminal = try await TelegramUpdateInbox(offsetURL: offsetURL).transition(updateId: claim.updateId,
                from: [claim.phase, .outcomeUnknown], to: .quarantined,
                quarantineReason: Self._tgRedactToken(String(describing: error)))
            if terminal.phase == .quarantined {
                await recordError(context: "recover_update_quarantined", error: "update \(claim.updateId): \(error)")
            }
            return terminal
        } catch {
            await recordError(context: "recover_update_quarantine_failed", error: "update \(claim.updateId): \(error)")
            return nil
        }
    }

    /// The update claim owns every send, including a saved answer after restart.
    public func recoverReply(_ response: ChatResponse, originRunId: String, destination: TelegramDestination? = nil,
                             requesterUserId: Int?, silent: Bool = false, priorVerdict: String? = nil) async throws -> String {
        guard let sessionId = response.sessionId else { throw TelegramBotError.invalidRequest }
        let runId = response.runId, reply = response.output, imagePaths = Self.replyImagePaths(response)
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
        let claims = try await inbox.snapshots()
        var savedClaim = claims.first(where: {
            ($0.assistantRunId == runId || $0.assistantRunId == originRunId || $0.assistantOriginRunId == originRunId || $0.settledAssistantRuns[runId] != nil)
                && $0.assistantSessionId == sessionId
        })
        if savedClaim == nil, let destination {
            savedClaim = try await inbox.reserveReply(runId: runId, sessionId: sessionId, destination: destination,
                delivery: TelegramAssistantDeliveryState(reply: TelegramRichMessageRenderer.sanitize(
                    TelegramRichMessageRenderer.stripBoldMarkers(reply)), imagePaths: imagePaths, silent: silent), priorVerdict: priorVerdict,
                fromUserId: requesterUserId)
        }
        guard let claim = savedClaim else { throw TelegramBotError.underlying("Saved answer has no Telegram update claim.") }
        if let reason = claim.quarantineReason { throw TelegramBotError.underlying(reason) }
        guard destination == nil || claim.update.message?.destination == destination else { throw TelegramBotError.invalidRequest }
        guard !(await turnCoordinator.isUpdateProcessing(claim.updateId)) else { return "owed" }
        if let verdict = claim.settledAssistantRuns[runId] {
            try await settleReplyCheckpoint(sessionId: sessionId, runId: runId, verdict: verdict)
            return verdict
        }
        if claim.assistantRunId != runId {
            guard let prior = claim.assistantDelivery, prior.isDelivered || prior.outcomeUnknown else { return "owed" }
            try await inbox.withAssistantDeliveryLock(updateId: claim.updateId) {
                try await inbox.prepareSuccessor(updateId: claim.updateId, runId: runId, sessionId: sessionId,
                    delivery: TelegramAssistantDeliveryState(reply: TelegramRichMessageRenderer.sanitize(
                        TelegramRichMessageRenderer.stripBoldMarkers(reply)), imagePaths: imagePaths))
            }
        } else if claim.assistantDelivery == nil {
            try await inbox.withAssistantDeliveryLock(updateId: claim.updateId) {
                _ = try await inbox.recordAssistantDelivery(updateId: claim.updateId,
                    delivery: TelegramAssistantDeliveryState(reply: TelegramRichMessageRenderer.sanitize(
                        TelegramRichMessageRenderer.stripBoldMarkers(reply)), imagePaths: imagePaths), recovering: true)
            }
        }
        return try await recoverReply(claim)
    }

    private func recoverReply(_ original: TelegramUpdateClaim) async throws -> String {
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
        guard !(await turnCoordinator.isUpdateProcessing(original.updateId)) else { return "owed" }
        return try await inbox.withAssistantDeliveryLock(updateId: original.updateId) {
        let claim = try inbox.claim(updateId: original.updateId)
        if let reason = claim.quarantineReason { throw TelegramBotError.underlying(reason) }
        guard let message = claim.update.message else { throw TelegramBotError.unavailable }
        // Synthetic outbound claims name the recipient; a private chat id is that user's id.
        guard Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds,
            allowedUserIds: allowedUserIds,
            chatId: message.chatId,
            fromUserId: message.fromUserId
        ) == .allowed || (claim.updateId < 0 && message.chatId > 0
            && allowedUserIds.contains(Int64(message.chatId))) else { throw TelegramBotError.unavailable }
        var delivery = try await retainedAssistantDelivery(for: claim)
        if delivery == nil {
            if let session = claim.assistantSessionId, let run = claim.assistantRunId,
               try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: session).contains(where: { turn in
                   // This run's own file decides; a damaged one may be it, so it is owed.
                   (try? TurnCheckpoint.read(dataRoot: dataRoot, sessionId: session, turnId: turn)).map { $0?.runId == run } ?? true
               }) {
                return "owed"
            }
            delivery = try await inbox.recordAssistantDelivery(updateId: claim.updateId,
                delivery: TelegramAssistantDeliveryState(reply: "Couldn't finish the reply.", imagePaths: []),
                failedBeforeAnswer: true)
        }
        guard let delivery else { throw TelegramBotError.unavailable }
        let phase: TelegramUpdateClaimPhase
        if delivery.isDelivered { phase = .completed }
        else if delivery.outcomeUnknown { phase = .sentUnconfirmed }
        else {
            let driver = makeAssistantDelivery(destination: message.destination, turnId: UUID(),
                errorContext: "recover_saved_reply", update: claim.update, message: message, text: nil,
                silent: delivery.silent == true)
            switch await driver.finalize(reply: delivery.reply, savedDelivery: delivery) {
            case .delivered: phase = .completed
            case .outcomeUnknown: phase = .sentUnconfirmed
            case .held, .failed: return "owed"
            }
        }
        let failedBeforeAnswer = try inbox.claim(updateId: claim.updateId).failedBeforeAnswer
        _ = try await inbox.transition(updateId: claim.updateId,
            from: [.processing, .outcomeUnknown, .completed, .sentUnconfirmed], to: failedBeforeAnswer ? .failedBeforeAnswer : phase)
        let verdict = failedBeforeAnswer ? "failed_before_answer" : phase == .completed ? "completed" : "sent_unconfirmed"
        if let session = claim.assistantSessionId, let run = claim.assistantRunId {
            try await settleReplyCheckpoint(sessionId: session, runId: run, verdict: verdict)
        }
        await inbox.pruneTerminalClaims(dataRoot: dataRoot)
        return verdict
        }
    }

    func settleReplyCheckpoint(sessionId: String, runId: String, verdict: String) async throws {
        try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: sessionId,
                                                                           runId: runId, verdict: verdict)
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
        await turnCardRestartRepairer.shutdown()
        await turnCoordinator.shutdown()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        do {
            try await prepareBotIngressStorage()
        } catch {
            await recordError(context: "bot_ingress_storage", error: String(describing: error))
            return .failed(error: "Telegram bot ingress storage unavailable")
        }
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
                do {
                    if claim.phase == .awaitingSpeechPermission {
                        if voiceTranscriber?.hasSpeechPermission == true {
                            reconciled.append(try await updateInbox.transition(
                                updateId: claim.updateId, from: [.awaitingSpeechPermission], to: .pending
                            ))
                        } else {
                            reconciled.append(claim)
                        }
                        continue
                    }
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
                        await recordError(
                            context: "recover_update_outcome_unknown",
                            error: "update \(claim.updateId) was processing when the prior Telegram loop stopped; automatic replay was suppressed"
                        )
                        // Not replaying is right — the turn's tool effects may
                        // already have landed. Saying nothing was not: the sender's
                        // message was consumed and only errors.jsonl knew. Speak
                        // once, on the surface it happened on.
                        _ = try await recoverReply(quarantined)
                        reconciled.append(quarantined)
                    } else if claim.phase == .outcomeUnknown {
                        _ = try await recoverReply(claim)
                    } else {
                        reconciled.append(claim)
                    }
                } catch {
                    if let terminal = await quarantineRecovery(claim, error: error) { reconciled.append(terminal) }
                }
            }
            recoveredClaims = reconciled
            RepairOwed.settle(dataRoot, operation: "telegram.inbox:" + updateInbox.directory.path,
                evidence: .init(source: updateInbox.directory.path, id: _tgNowString()))
        } catch {
            let failure = updateInbox.repairFailure(error, dataRoot: dataRoot)
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run,
                operation: "telegram.inbox:" + updateInbox.directory.path, owner: failure.owner!,
                words: failure.message, nextCall: failure.nextCall)
            await recordError(context: "update_inbox_load", error: failure.message)
            return .failed(error: failure.message)
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
            // 2026-09-22: menu sync reads state.json; at 0.25s cadence it ran
            // 4x/sec through every backoff window. Recovery above still runs.
            await syncCommandMenuIfNeeded()
            do {
                result = try await bot.longPoll(
                    token: token, offset: offset,
                    timeoutSeconds: 25, session: longPollSession
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
                return .failed(error: Self._tgRedactToken("Telegram long poll: \(error)"))
            }
            let recovered = await pollBackoff.failureCount() > 0
            await pollBackoff.recordSuccess()
            let checkpointDue = await longPollSession.recordSuccessfulPoll()
            if checkpointDue || recovered || !result.updates.isEmpty {
                await writeStatePatch([
                    "lastPollAt": .string(_tgNowString()),
                    "lastError": .null,
                    "pollBackoffFailures": .int(0),
                    "pollBackoffRetryDelaySeconds": .null,
                ])
            }
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
            case .completed, .outcomeUnknown, .sentUnconfirmed, .failedBeforeAnswer, .quarantined:
                continue
            case .awaitingSpeechPermission:
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
                guard claim.resolvedSessionId != nil else {
                    do {
                        if let message = claim.update.message {
                            try await sendMessage(token, message.destination,
                                "This queued message has no saved conversation binding. Select the conversation and resend it; I haven't run it.")
                        }
                        _ = try await updateInbox.transition(updateId: claim.updateId,
                            from: [.queued], to: .outcomeUnknown)
                    } catch {
                        return .failed(error: "Telegram queued conversation recovery failed: \(error)")
                    }
                    continue
                }
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
                shouldCompleteClaim = false
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
            // Supported files and images enter the same admitted chat turn.
            let mediaAttachment = Self.chatAttachment(from: msg)
            let unsupportedAttachmentKind = Self.unsupportedAttachmentKind(from: msg)
            guard textFromMessage?.isEmpty == false
                    || voiceAttachment != nil
                    || mediaAttachment != nil
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
            // Mention offsets refer to the wire text, never a transcript.
            // Gate ordinary group traffic before downloading or acknowledging media.
            let mentionText = msg.text ?? {
                guard case .object(let extras)? = msg.extras else { return "" }
                return _tgJSONString(extras["caption"]) ?? ""
            }()
            let mentionEntities: JSONValue? = {
                guard case .object(let extras)? = msg.extras else { return nil }
                return extras[msg.text == nil ? "caption_entities" : "entities"]
            }()
            if (voiceAttachment != nil || !mentionText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")),
               Self.dropsForMissingMention(
                requireMention: requireMention,
                chatId: msg.chatId,
                text: mentionText,
                entities: mentionEntities,
                botUsername: requireMention && msg.chatId < 0 ? await resolveBotUsername() : nil
               ) {
                await recordBlocked(reason: "mention_required", update: update, message: msg, text: textFromMessage)
                break updateProcessing
            }
            if let unsupportedAttachmentKind,
               textFromMessage?.isEmpty != false, voiceAttachment == nil, mediaAttachment == nil {
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
            // (no transcriber), which keeps the old text route and
            // the old "not configured" notice exactly as they were.
            var stagedMediaAttachments: [TelegramMediaAttachment] = []
            if let existing = textFromMessage, !existing.isEmpty,
               voiceAttachment == nil || voiceTranscriber == nil {
                text = existing
                receiptKind = "reply"
            } else if let voiceAttachment {
                guard attachmentChatHandler != nil else {
                    await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: nil)
                    break updateProcessing
                }
                guard let voiceTranscriber else {
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
                // Kept by id so it goes away once transcription settles, like
                // every other working notice (User 09-27).
                var transcribingNoticeId: Int?
                func dismissTranscribingNotice() async {
                    guard let id = transcribingNoticeId else { return }
                    transcribingNoticeId = nil
                    try? await deleteMessage(token, msg.destination.chatId, id)
                }
                do {
                    if await !voicePermissionNotice.sent {
                        transcribingNoticeId = try await sendMessageReturningId(token, msg.destination, "Transcribing voice message")
                    }
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: voice progress send failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                }
                var publishingTranscript = false
                do {
                    var downloaded = try await mediaDownloader.download(
                        token: token,
                        attachment: voiceAttachment,
                        maxBytes: voiceMaxBytes
                    )
                    let transcription = try await voiceTranscriber.transcribe(downloaded)
                    await voicePermissionNotice.setSent(false)
                    let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawTranscript.isEmpty else {
                        throw TelegramVoiceTranscriptionError.malformedResponse
                    }
                    await recordVoiceTranscription(
                        update: update,
                        message: msg,
                        attachment: downloaded,
                        transcription: transcription
                    )
                    // 2026-09-06: a caption on a voice note is the sender's
                    // typed instruction ABOUT the recording, so it leads and
                    // the transcript follows.
                    if let caption = textFromMessage, !caption.isEmpty {
                        text = """
                        \(caption)

                        [Telegram voice message]
                        \(transcription.utterance.face)
                        """
                    } else {
                        text = """
                        [Telegram voice message]
                        \(transcription.utterance.face)
                        """
                    }
                    receiptKind = "voice_reply"
                    publishingTranscript = true
                    var utterance = transcription.utterance
                    utterance.correctionReferences = []
                    let face = utterance.face + "\nReply with Correction: followed by the complete corrected transcript to replace it."
                    for chunk in Self._tgChunkMessage(face, limit: 4000) {
                        let id: Int
                        if let noticeId = transcribingNoticeId {
                            try await editMessageText(token, msg.chatId, noticeId, chunk)
                            id = noticeId
                            transcribingNoticeId = nil
                        } else {
                            id = try await sendMessageReturningId(token, msg.destination, chunk)
                        }
                        if let sender = msg.fromUserId {
                            utterance.correctionReferences?.append("telegram:\(msg.chatId):\(sender):\(id)")
                        }
                    }
                    downloaded.utterance = utterance
                    stagedMediaAttachments = [downloaded]
                } catch where error is CancellationError || Self.isSpeechPermissionDenial(error) {
                    await dismissTranscribingNotice()
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
                    // Hearing and its face precede the turn; neither may consume
                    // an unanswered note when interrupted.
                    await turnCoordinator.endUpdateProcessing(update.updateId)
                    do {
                        let pending = try await updateInbox.transition(
                            updateId: update.updateId,
                            from: [.processing, .queued],
                            to: awaitingPermission ? .awaitingSpeechPermission : .pending
                        )
                        guard pending.phase == (awaitingPermission ? .awaitingSpeechPermission : .pending) else {
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
                    return .skipped(reason: "Telegram voice intake interrupted; durable update retained for retry")
                } catch {
                    await dismissTranscribingNotice()
                    if publishingTranscript {
                        await turnCoordinator.endUpdateProcessing(update.updateId)
                        do {
                            guard await quarantineRecovery(try updateInbox.claim(updateId: update.updateId), error: error)?.phase == .quarantined else {
                                return .failed(error: "Telegram voice transcript publication failure could not be quarantined")
                            }
                        } catch {
                            await recordError(context: "voice_transcript_face", error: String(describing: error), update: update, message: msg, text: nil)
                            return .failed(error: "Telegram voice transcript publication failure could not be quarantined")
                        }
                        continue
                    }
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
            } else if let mediaAttachment {
                // The engine needs a prompt for an attachment-only send.
                guard attachmentChatHandler != nil else {
                    await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: nil)
                    break updateProcessing
                }
                if mediaAttachment.chatTypeAndMime?.type == "file" {
                    text = "[The user sent a file with no caption. Read it and respond.]"
                    receiptKind = "document_reply"
                } else {
                    text = "[The user sent an image with no caption. Look at it and respond.]"
                    receiptKind = "photo_reply"
                }
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
                // `/cmd` and verified `/cmd@ThisBot` are handled as before.
                if let addressedBot = TelegramCommandRegistry.addressedBotUsername(text: text) {
                    guard let ownUsername = await resolveBotUsername() else {
                        do {
                            let pending = try await updateInbox.transition(
                                updateId: update.updateId, from: [.processing, .queued], to: .pending
                            )
                            guard pending.phase == .pending else {
                                await turnCoordinator.endUpdateProcessing(update.updateId)
                                return .failed(error: "Telegram addressed command could not be retained pending bot identity")
                            }
                        } catch {
                            await turnCoordinator.endUpdateProcessing(update.updateId)
                            await recordError(context: "command_identity_pending", error: String(describing: error), update: update)
                            return .failed(error: "Telegram addressed command could not be retained pending bot identity")
                        }
                        await turnCoordinator.endUpdateProcessing(update.updateId)
                        shouldCompleteClaim = false
                        break updateProcessing
                    }
                    if addressedBot.compare(ownUsername, options: .caseInsensitive) != .orderedSame {
                        await recordBlocked(
                            reason: "command_for_other_bot",
                            update: update,
                            message: msg,
                            text: text
                        )
                        break updateProcessing
                    }
                }
                // 2026-09-06: the command runs in its own task and settles its
                // own claim there. Handling it inline meant the poll loop waited
                // out the chat's flood cooldown; detaching only the reply send
                // meant `/restart` armed termination and this claim was marked
                // completed while the reply was still on the wire. The task owns
                // both, so nothing after the reply happens before it is out.
                await runCommandDetached(update: update, message: msg, text: text)
                shouldCompleteClaim = false
                break updateProcessing
            }
            // Non-slash text: route to chat-orchestration when wired.
            guard attachmentChatHandler != nil else {
                await recordBlocked(reason: "chat_handler_not_configured", update: update, message: msg, text: text)
                break updateProcessing
            }
            var handoffText = text
            if text.contains("@"), let username = await resolveBotUsername() {
                handoffText = text.split(whereSeparator: { $0.isWhitespace })
                    .filter { String($0).compare("@\(username)", options: .caseInsensitive) != .orderedSame }
                    .joined(separator: " ")
            }
            if UserMessageIntentSignals.isControlHandoff(handoffText) {
                await runCommandDetached(update: update, message: msg, text: handoffText)
                shouldCompleteClaim = false
                break updateProcessing
            }
            if let unsupportedAttachmentKind {
                // A supported text caption still follows its original route;
                // the notice makes clear that its attached file was not read.
                await notifyUnsupportedAttachment(kind: unsupportedAttachmentKind, update: update, message: msg)
            }
            // Download the inbound attachment (if any) and stage
            // it as an attachment to thread onto the chat turn below. Tripwire:
            // a present-but-unprocessable attachment emits a
            // telegram.attachment_dropped trace AND a user-visible reply —
            // never a silent drop. On any failure we stop processing (the attachment was
            // the point of the turn; falling through to a blind text-only reply
            // would be the silent-drop bug).
            if let mediaAttachment {
                let maxBytes = chatAttachmentMaxBytes(mediaAttachment)
                do {
                    let downloaded = try await mediaDownloader.download(
                        token: token,
                        attachment: mediaAttachment,
                        maxBytes: maxBytes
                    )
                    guard let bytes = downloaded.bytes, !bytes.isEmpty else {
                        throw TelegramMediaDownloadError.malformedResponse
                    }
                    let mime: String
                    if downloaded.kind == "photo" {
                        mime = Self.imageMime(forFilename: downloaded.captureFilename, fallbackMime: downloaded.mimeType)
                    } else {
                        guard let resolved = downloaded.chatTypeAndMime else {
                            throw TelegramMediaDownloadError.malformedResponse
                        }
                        mime = resolved.mime
                    }
                    stagedMediaAttachments = [TelegramMediaAttachment(
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
                                return "attachment is too large (\(reported) bytes, cap \(cap) bytes)"
                            case .missingFilePath: return "Telegram returned no file path"
                            case .httpError(let status): return "Telegram download failed (HTTP \(status))"
                            case .malformedResponse: return "Telegram download response was malformed"
                            }
                        }
                        return String(describing: error)
                    }()
                    FileHandle.standardError.write(Data("TelegramPollLoop: photo download failed for update \(update.updateId): \(Self._tgRedactToken(reason))\n".utf8))
                    await emitAttachmentDroppedTrace(
                        kind: mediaAttachment.kind,
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
            // `stagedMediaAttachments` is accumulated while decoding this
            // update. Freeze that mutable local before it crosses the
            // coordinator's @Sendable task boundary.
            let turnMediaAttachments = stagedMediaAttachments
            // Pin before admission: card delivery and queue waits must not let
            // a later /new or /resume redirect this message.
            let turnSessionId: String
            do {
                if let saved = claim.resolvedSessionId {
                    turnSessionId = saved
                } else {
                    turnSessionId = try await TelegramSessionStore(dataRoot: dataRoot)
                        .activeSessionId(destination: msg.destination)
                }
            } catch {
                await recordError(context: "turn_session", error: String(describing: error), update: update, message: msg, text: text)
                let notice = Self.chatErrorNotice(for: error)
                do {
                    try await sendMessage(token, msg.destination, notice)
                    await recordReceipt(kind: "error_notice", update: update, message: msg, text: text, reply: notice)
                } catch {
                    await recordError(context: "send_session_error_notice", error: String(describing: error), update: update, message: msg, text: text)
                }
                break updateProcessing
            }
            // Queued behind a working turn in this conversation, it is addressed to
            // that turn under the run it would have as its own. Once that turn
            // reserved it, the claim keeps that run, so after a restart too its row
            // may already be written; this run then finds it rather than writing it again.
            let reserved = claim.phase == .queued ? claim.assistantRunId.flatMap(UUID.init(uuidString:)) : nil
            let queuedTurnId = reserved ?? UUID()
            // Registered for Stop at admission, before any await: a Stop from here
            // on names this run, queued or running; the turn's own acceptance is the
            // same registration. It ends with the turn operation that holds it.
            let traceTurnId = TurnTraceContext.mintTurnId()
            let runStop = TelegramRunStop(ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: turnSessionId,
                                                                runId: queuedTurnId.uuidString, turnId: traceTurnId))
            // Where User was when his "take over" arrived, before any queue.
            let takeover = await MacWorkContinuation.admit(handoffText)
            let steered = OSAllocatedUnfairLock(initialState: reserved != nil)
            let steeringText = TelegramReplyPromptRenderer.messageWithReplyContext(text: text, replyTo: msg.replyTo)
            let signalArrival: @Sendable (String) -> Void = { turnId in
                var arrived: [String: JSONValue] = ["text": .string(text), "chat_id": .int(Int64(msg.chatId)),
                    "user_id": msg.fromUserId.map { .int(Int64($0)) } ?? .null,
                    "session_id": .string(turnSessionId), "turn_id": .string(turnId)]
                // A sender the owner did not allowlist by user speaks as a stranger.
                if msg.fromUserId.map({ !allowedUserIds.contains(Int64($0)) }) ?? true {
                    arrived["agent"] = .string("telegram:" + (msg.fromUserId.map(String.init) ?? "unknown"))
                }
                AbilityStore(dataRoot: dataRoot).signal("message.arrived:telegram", arrived)
            }
            let turnBody: @Sendable (UUID) async -> Void = { turnId in
                    if let queuedMessageId = claim.queueAcknowledgementMessageId {
                        let preview = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
                        await clearQueueAcknowledgement(
                            chatId: msg.chatId,
                            messageId: queuedMessageId,
                            runningText: "Running now · \(preview)"
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
                            from: [.queued, .processing],
                            to: .processing,
                            assistantRunId: turnId.uuidString,
                            assistantSessionId: turnSessionId
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
                    let written = steered.withLock { $0 } ? try await SwiftNativeChatOrchestrationClient.steeringMessageCommitted(
                        message: steeringText, sessionId: turnSessionId, runId: turnId.uuidString,
                        dataRoot: dataRoot, persistence: SwiftNativePersistenceCore()) : false
                    let (reply, imagePaths) = try await runChatHandler(
                        destination: msg.destination,
                        text: text,
                        attachments: turnMediaAttachments,
                        progress: makeProgressSink(delivery: delivery, card: card),
                        replyTo: msg.replyTo,
                        fromUserId: msg.fromUserId,
                        suppressUserAppend: written,
                        sessionId: turnSessionId,
                        runId: turnId.uuidString
                    )
                    try Task.checkCancellation()
                    if !reply.isEmpty {
                        let deliveryOutcome = await delivery.finalize(reply: reply, imagePaths: imagePaths)
                        switch deliveryOutcome {
                        case .held: break
                        case .delivered:
                            try await settleReplyCheckpoint(sessionId: turnSessionId, runId: turnId.uuidString, verdict: "completed")
                            await recordReceipt(kind: receiptKind, update: update, message: msg, text: text, reply: reply)
                            await card.transition(.completed(summary: "Reply delivered"))
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
                        // Stop the preview and persist the empty-reply notice.
                        let notice = "(the reply came back empty - check the Mac error log)"
                        await recordError(context: "empty_reply", error: "chat handler returned empty output", update: update, message: msg, text: text)
                        await card.transition(.failed(reason: "The reply came back empty"))
                        await deliverTurnNotice(
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
                    // This task is already cancelled; run the terminal UI work in a fresh one.
                    await Task {
                        await delivery.stop()
                        await card.transition(.canceled(reason: "Stopped by user"))
                    }.value
                    // The canceled work card is already durable evidence.
                    await recordReceipt(kind: "turn_canceled", update: update, message: msg, text: text, reply: notice)
                } catch {
                    FileHandle.standardError.write(Data("TelegramPollLoop: chat handler failed for update \(update.updateId): \(Self._tgRedactToken(String(describing: error)))\n".utf8))
                    await recordError(context: "chat_handler", error: String(describing: error), update: update, message: msg, text: text)
                    await card.transition(.failed(reason: Self.chatErrorNotice(for: error)))
                    let notice = Self.chatErrorNotice(for: error)
                    await deliverTurnNotice(
                        notice,
                        delivery: delivery,
                        receiptKind: "error_notice",
                        sendErrorContext: "send_error_notice",
                        update: update,
                        message: msg,
                        text: text
                    )
                }
                // 2026-09-06: the reply (or its honest notice) has been handed
                // off, so this update is finished. A crash before this point
                // leaves `.processing`, which restart recovery settles as
                // outcome-unknown and tells the sender about.
                do {
                    let saved = try await Task {
                        try await retainedAssistantDelivery(for: updateInbox.claim(updateId: update.updateId))
                    }.value
                    _ = try await updateInbox.transition(
                        updateId: update.updateId,
                        from: [.processing],
                        to: saved?.isDelivered == true ? .completed : saved?.outcomeUnknown == true ? .sentUnconfirmed : .outcomeUnknown
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
                signalArrival(turnId.uuidString)
            }
            let turnOperation: @Sendable (UUID) async -> Void = { turnId in
                await TurnTraceContext.$turnId.withValue(traceTurnId) {
                    await MacWorkContinuation.$current.withValue(takeover) { await turnBody(turnId) }
                }
                withExtendedLifetime(runStop) {}
            }
            if await turnCoordinator.startTrackedTurn(
                id: queuedTurnId,
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
                        to: .queued,
                        resolvedSessionId: turnSessionId
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
                    turnId: queuedTurnId,
                    updateId: update.updateId,
                    destination: msg.destination,
                    text: text,
                    acknowledgementMessageId: acknowledgementMessageId,
                    operation: turnOperation,
                    onStart: { messageId in
                        guard let messageId else { return }
                        await clearQueueAcknowledgement(
                            chatId: msg.chatId,
                            messageId: messageId,
                            runningText: "Running now · \(preview)"
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
                // Her turn reads it at its next step and decides what it means for
                // the work; one that ends first leaves it queued to run as its own.
                // Only the person's own words join a turn already working (a sender
                // allowed only by chat speaks as a stranger, in a turn of their own),
                // and media rides only with its own turn.
                if turnMediaAttachments.isEmpty, msg.fromUserId.map({ allowedUserIds.contains(Int64($0)) }) == true {
                    let acknowledgement = acknowledgementMessageId
                    let route = ChatToolSessionContext.ReplyRoute(surface: "telegram", destinationId: String(msg.chatId),
                        threadId: msg.destination.threadId.map(String.init), requesterUserId: msg.fromUserId.map(String.init))
                    _ = await ChatTurnSteering.shared.offer(ChatTurnSteering.Offer(id: "telegram:\(update.updateId)", text: steeringText,
                        envelope: TurnEnvelope(surface: "telegram", verifiedChatId: String(msg.chatId),
                            verifiedUserId: msg.fromUserId.map(String.init), deliveryRoute: route),
                        origin: nil, runID: queuedTurnId.uuidString), sessionId: turnSessionId) { offer, committed in
                        guard await turnCoordinator.queuedTurn(destination: msg.destination, updateId: update.updateId) != nil else {
                            return false
                        }
                        if !committed {
                            // Reserved: its run goes on the claim first. Read by her turn:
                            // the claim settles first, so a restart never replays it.
                            do {
                                let read = offer.receivingTurnID != nil
                                let saved = try await updateInbox.transition(updateId: update.updateId, from: [.queued],
                                    to: read ? .completed : .queued, assistantRunId: queuedTurnId.uuidString, assistantSessionId: turnSessionId)
                                guard saved.phase == (read ? .completed : .queued),
                                      saved.assistantRunId == queuedTurnId.uuidString else { return false }
                            } catch {
                                await recordError(context: "steered_update_claim", error: String(describing: error),
                                                  update: update, message: msg, text: text)
                                return false
                            }
                            steered.withLock { $0 = true }
                            return true
                        }
                        // Her turn read it: it leaves the queue.
                        _ = await turnCoordinator.removeQueuedTurn(destination: msg.destination, updateId: update.updateId)
                        if let acknowledgement {
                            await clearQueueAcknowledgement(chatId: msg.chatId, messageId: acknowledgement,
                                                            runningText: "Read in the reply in progress · \(preview)")
                        }
                        signalArrival(offer.receivingTurnID ?? queuedTurnId.uuidString)
                        return true
                    }
                }
            }
            await turnCoordinator.recordLastUserMessage(destination: msg.destination, text: text, message: msg)
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
        await updateInbox.pruneTerminalClaims(dataRoot: dataRoot)
        await turnCardRestartRepairer.scheduleRepair { await repairInterruptedTurnCardsIfNeeded() }
        return .completed(result: "Telegram poll processed \(updates.count) update(s)")
    }
}

/// A door's Stop registration for one run, finished when the turn operation
/// holding it is released: run to its end, dropped from the queue, or never
/// queued at all.
final class TelegramRunStop: Sendable {
    private let flag: URL
    init(_ flag: URL) { self.flag = flag }
    deinit { ChatCancelFlag.finish(flag) }
}
