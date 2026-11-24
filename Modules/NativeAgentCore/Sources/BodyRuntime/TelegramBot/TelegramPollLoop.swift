import SenseCore
import Foundation
import NativeAgentShared
import MacNerves
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import MindCore

// Blueprint: | `TelegramPollLoop.swift` | Durable admission; complete media preparation; admitted generation never replays from missing output; `tickOutcome` reconciles and processes durable claims before polling and processing new updates |

// MARK: - TelegramPollLoop

/// Keep the inter-tick gap short: each long poll already waits up to about 25 seconds for incoming work.
public struct TelegramPollLoop: LoopRunner {
    public let loopId: String = "telegram_poll"
    public let wake: OrganWake
    let token: String
    let allowedChatIds: Set<Int64>
    let allowedUserIds: Set<Int64>
    let requireMention: Bool
    let bot: SwiftNativeTelegramBot
    let longPollSession = TelegramLongPollSession()
    public var lastSuccessfulPollAt: Date? { get async { await longPollSession.lastSuccessfulPollAt } }
    let dataRoot: URL
    let partFace: PartFaces.Call

    /// Share fail-closed sender decisions with Settings so empty or nonmatching allowlists cannot become accept-all.
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

    static func controlAuthorizationDecision(
        allowedChatIds: Set<Int64>, allowedUserIds: Set<Int64>, chatId: Int, fromUserId: Int?
    ) -> InboundAuthorizationDecision {
        let admission = inboundAuthorizationDecision(allowedChatIds: allowedChatIds, allowedUserIds: allowedUserIds,
            chatId: chatId, fromUserId: fromUserId)
        guard admission == .allowed else { return admission }
        guard let fromUserId,
              allowedUserIds.contains(Int64(fromUserId)) || (chatId > 0 && chatId == fromUserId) else { return .notAllowlisted }
        return .allowed
    }

    /// Settings and live polling must share the group-message decision so requireMention controls actual admission.
    public static func dropsForMissingMention(
        requireMention: Bool,
        chatId: Int,
        text: String,
        entities: JSONValue? = nil,
        botUsername: String? = nil
    ) -> Bool {
        guard requireMention && chatId < 0 else { return false }
        guard let botUsername else { return true }
        return !mentionedUsernames(in: text, entities: entities).contains(botUsername.lowercased())
    }

    static func mentionedUsernames(in text: String, entities: JSONValue?) -> [String] {
        guard case .array(let entities)? = entities else { return [] }
        let source = text as NSString
        return entities.compactMap { entity in
            guard case .object(let fields) = entity,
                  fields["type"]?.stringValue == "mention",
                  let offset = (fields["offset"]?.integerValue.flatMap(Int.init(exactly:)) ?? fields["offset"]?.stringValue.flatMap(Int.init)),
                  let length = (fields["length"]?.integerValue.flatMap(Int.init(exactly:)) ?? fields["length"]?.stringValue.flatMap(Int.init)),
                  offset >= 0, length > 1, offset <= source.length,
                  length <= source.length - offset else { return nil }
            let mention = source.substring(with: NSRange(location: offset, length: length))
            let username = mention.dropFirst()
            guard mention.first == "@", username.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }) else { return nil }
            return username.lowercased()
        }
    }
    let offsetURL: URL
    var botIdentity: String { String(token.prefix { $0 != ":" }) }
    let approvalHandler: (any TelegramApprovalHandling)?
    let attachmentChatHandler: TelegramProgressChatHandlerWithAttachments?
    let mediaDownloader = TelegramMediaDownloader()
    let voiceTranscriber: SwiftAppleSpeechTranscriber?
    private actor VoicePermissionNotice {
        var sent = false
        func setSent(_ value: Bool) { sent = value }
    }
    private let voicePermissionNotice = VoicePermissionNotice()
    /// Signal only missing TCC grants on the Mac, by capability name; nil disables the signal.
    let onCapabilityDenied: (@Sendable (String) async -> Void)?
    let voiceMaxBytes: Int
    let photoMaxBytes: Int
    let turnCoordinator: TelegramTurns
    let revokeDriverControl: @Sendable () async -> Void
    let turnCardLedger: TelegramTurnCardLedger
    let turnCardRestartRepairer: TelegramTurnCardRestartRepairer
    let pollBackoff: TelegramExponentialBackoff
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
        partFace: @escaping PartFaces.Call = { _, _, _ in
            .failure(.init(code: "unavailable", message: "The originating Telegram app door is not bound."))
        },
        offsetURL: URL = defaultTelegramOffsetURL(),
        approvalHandler: (any TelegramApprovalHandling)? = nil,
        attachmentChatHandler: TelegramProgressChatHandlerWithAttachments? = nil,
        voiceTranscriber: SwiftAppleSpeechTranscriber? = nil,
        onCapabilityDenied: (@Sendable (String) async -> Void)? = nil,
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes,
        photoMaxBytes: Int = TelegramPollLoop.defaultPhotoMaxBytes,
        turnCoordinator: TelegramTurns = .shared
    ) {
        self.wake = .every(interval)
        self.token = token
        self.revokeDriverControl = revokeDriverControl
        self.allowedChatIds = allowedChatIds
        self.allowedUserIds = allowedUserIds
        self.requireMention = requireMention
        self.bot = bot
        let resolvedDataRoot = dataRoot ?? Self.inferDataRoot(from: offsetURL)
        self.dataRoot = resolvedDataRoot
        self.partFace = partFace
        self.offsetURL = offsetURL.deletingLastPathComponent()
            .appendingPathComponent("bots", isDirectory: true)
            .appendingPathComponent(Self.botStorageIdentity(token), isDirectory: true)
            .appendingPathComponent(offsetURL.lastPathComponent)
        let cardLedger = TelegramTurnCardLedger.shared(
            fileURL: resolvedDataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("work_cards.json")
        )
        self.turnCardLedger = cardLedger
        self.turnCardRestartRepairer = TelegramTurnCardRestartRepairer(ledger: cardLedger)
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

    /// Only the transcriber's authorization denial signals a missing TCC grant.
    static func isSpeechPermissionDenial(_ error: Error) -> Bool {
        if case TelegramVoiceTranscriptionError.speechPermissionDenied = error { return true }
        return false
    }

    public func reconcileSavedReplies() async throws {
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        for claim in try await inbox.recoverableClaims() where claim.assistantDelivery != nil {
            do { _ = try await recoverReply(claim) }
            catch { _ = await quarantineRecovery(claim, error: error) }
        }

    }

    private func quarantineRecovery(_ claim: TelegramUpdateClaim, error: Error) async -> TelegramUpdateClaim? {
        do {
            let terminal = try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).transition(updateId: claim.updateId,
                from: [claim.phase, .outcomeUnknown], to: .quarantined,
                quarantineReason: TurnSecretRedactor.redactText(String(describing: error)))
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
        let runId = response.runId, reply = Self.replyText(response), imagePaths = Self.replyImagePaths(response)
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        let claims = try await inbox.snapshots()
        if response.isSilentCompletion {
            if let claim = claims.first(where: { $0.assistantRunId == runId && $0.assistantSessionId == sessionId }) {
                _ = try await inbox.transition(updateId: claim.updateId, from: [.processing, .outcomeUnknown],
                    to: .completed, noRecoverableAnswer: true)
            }
            try await settleReplyCheckpoint(sessionId: sessionId, runId: runId, verdict: "completed")
            return "completed"
        }
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
                        TelegramRichMessageRenderer.stripBoldMarkers(reply)), imagePaths: imagePaths, silent: prior.silent ?? silent))
            }
        } else if claim.assistantDelivery == nil {
            try await inbox.withAssistantDeliveryLock(updateId: claim.updateId) {
                _ = try await inbox.recordAssistantDelivery(updateId: claim.updateId,
                    delivery: TelegramAssistantDeliveryState(reply: TelegramRichMessageRenderer.sanitize(
                        TelegramRichMessageRenderer.stripBoldMarkers(reply)), imagePaths: imagePaths, silent: silent), recovering: true)
            }
        }
        return try await recoverReply(claim)
    }

    private func recoverReply(_ original: TelegramUpdateClaim) async throws -> String {
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        guard !(await turnCoordinator.isUpdateProcessing(original.updateId)) else { return "owed" }
        return try await inbox.withAssistantDeliveryLock(updateId: original.updateId) {
        let claim = try inbox.claim(updateId: original.updateId)
        if let reason = claim.quarantineReason { throw TelegramBotError.underlying(reason) }
        guard let message = claim.update.message else {
            throw TelegramBotError.underlying("""
                telegram_claim_message_missing: Saved update \(claim.updateId) has no message. Inspect its update_inbox claim \
                before attempting delivery.
                """)
        }
        // Synthetic outbound claims name the recipient; a private chat id is that user's id.
        guard Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds,
            allowedUserIds: allowedUserIds,
            chatId: message.chatId,
            fromUserId: message.fromUserId
        ) == .allowed || (claim.updateId < 0 && message.chatId > 0
            && allowedUserIds.contains(Int64(message.chatId))) else {
                throw TelegramBotError.underlying("""
                    telegram_destination_not_allowed: Saved reply destination is not allowed. Review allowed chat and user IDs in \
                    Telegram setup; do not resend to another destination.
                    """)
            }
        if let session = claim.assistantSessionId, let run = claim.assistantRunId,
           try SwiftNativeChatOrchestrationClient.silentTurn(dataRoot: dataRoot, sessionId: session, runId: run) != nil {
            _ = try await inbox.transition(updateId: claim.updateId, from: [.processing, .outcomeUnknown],
                to: .completed, noRecoverableAnswer: true)
            try await settleReplyCheckpoint(sessionId: session, runId: run, verdict: "completed")
            return "completed"
        }
        guard let delivery = try await retainedAssistantDelivery(for: claim) else { return "owed" }
        let phase: TelegramUpdateClaimPhase
        if delivery.isDelivered { phase = .completed }
        else if delivery.outcomeUnknown { phase = .sentUnconfirmed }
        else {
            let driver = makeAssistantDelivery(destination: message.destination, draftKey: "telegram:update:\(claim.updateId)", turn: nil,
                errorContext: "recover_saved_reply", update: claim.update, message: message, text: nil,
                silent: delivery.silent == true)
            switch await driver.finalize(reply: delivery.reply, savedDelivery: delivery) {
            case .delivered: phase = .completed
            case .outcomeUnknown: phase = .sentUnconfirmed
            case .held, .failed: return "owed"
            }
        }
        let failedBeforeAnswer = try inbox.claim(updateId: claim.updateId).failedBeforeAnswer
        let failedNoticeDelivered = failedBeforeAnswer && phase == .completed
        _ = try await inbox.transition(updateId: claim.updateId,
            from: [.processing, .outcomeUnknown, .completed, .sentUnconfirmed], to: failedNoticeDelivered ? .failedBeforeAnswer : phase)
        let verdict = failedNoticeDelivered ? "failed_before_answer" : phase == .completed ? "completed" : "sent_unconfirmed"
        if let session = claim.assistantSessionId, let run = claim.assistantRunId {
            try await settleReplyCheckpoint(sessionId: session, runId: run, verdict: verdict)
        }
        await inbox.pruneTerminalClaims(dataRoot: dataRoot)
        return verdict
        }
    }

    /// A stopped or failed turn's saved words go out once, closed by the words this door already uses for a stop or a failure.
    static func replyText(_ response: ChatResponse) -> String {
        let ending: String
        switch response.terminalState {
        case .stopped?: ending = "Stopped."
        case .failed?: ending = response.statusDetail ?? "The reply could not be completed; try again."
        default: return response.output
        }
        return [response.output, ending].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func settleReplyCheckpoint(sessionId: String, runId: String, verdict: String) async throws {
        try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: sessionId,
                                                                           runId: runId, verdict: verdict)
    }

    public func tick() async {
        let turnsAlreadyRunning = await turnCoordinator.activeTurnIDs()
        _ = await tickOutcome()
        // Direct callers await only this tick's admitted work; scheduled ticks return after admission so status and Stop remain usable.
        await turnCoordinator.waitUntilIdle(excluding: turnsAlreadyRunning)
    }

    public func shutdown() async {
        await approvalHandler?.stopApprovalDelivery()
        await turnCardRestartRepairer.shutdown()
        await turnCoordinator.shutdown()
        await bot.closeCommandFaces()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        guard !Task.isCancelled else { return .skipped(reason: "Telegram poll cancelled") }
        await approvalHandler?.startApprovalDelivery()
        guard !Task.isCancelled else { return .skipped(reason: "Telegram poll cancelled") }
        do {
            try await prepareBotIngressStorage()
        } catch {
            await recordError(context: "bot_ingress_storage", error: String(describing: error))
            return .failed(error: "Telegram bot ingress storage unavailable")
        }
        let cursor = TelegramOffsetCursor(fileURL: offsetURL)
        var offset: Int
        do {
            offset = try cursor.load()
        } catch {
            await recordError(context: "load_offset", error: String(describing: error))
            return .failed(error: "Telegram offset cursor unavailable: \(error.localizedDescription)")
        }

        // Persist admission before advancing upstream; orphaned processing claims stay outcome-unknown because effects may already have occurred.
        let updateInbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        let recoveredClaims: [TelegramUpdateClaim]
        switch await reconcileRecoveredClaims(updateInbox: updateInbox) {
        case .proceed(let reconciled): recoveredClaims = reconciled
        case .end(let outcome): return outcome
        }

        if let acknowledged = recoveredClaims
            .filter({ $0.phase != .pending && $0.updateId >= 0 })
            .compactMap({ $0.update.nextOffset })
            .max(),
           acknowledged > offset {
            guard let advanced = await persistOffset(acknowledged, cursor: cursor) else {
                return .failed(error: "Telegram could not reconcile durable inbox offset")
            }
            offset = advanced
        }

        // Give accepted work its chance even during a poll outage. A claim still waiting for
        // bot identity must not take the upstream intake slot away from other chats.
        let pending = recoveredClaims.filter { $0.phase == .pending }.sorted { $0.updateId < $1.updateId }
        var persistedOffset = offset
        for claim in pending {
            if let outcome = await processUpdate(claim.update, updateInbox: updateInbox, cursor: cursor,
                                                 persistedOffset: &persistedOffset) { return outcome }
        }

        let result: TelegramPollResult
        switch await pollForUpdates(offset: persistedOffset) {
        case .proceed(let polled): result = polled
        case .end(let outcome): return outcome
        }

        var updatesById: [Int: TelegramUpdate] = [:]
        for update in result.updates { updatesById[update.updateId] = update }
        // Already processed from the durable bytes, even if a claim is still pending.
        for claim in pending { updatesById.removeValue(forKey: claim.updateId) }
        let updates = updatesById.values.sorted { $0.updateId < $1.updateId }

        for candidateUpdate in updates {
            if let outcome = await processUpdate(candidateUpdate, updateInbox: updateInbox, cursor: cursor,
                                                 persistedOffset: &persistedOffset) { return outcome }
        }

        let finalOffset = max(persistedOffset, result.nextOffset)
        if finalOffset != persistedOffset || result.updates.isEmpty {
            guard await persistOffset(finalOffset, cursor: cursor) != nil else {
                return .failed(error: "Telegram final poll offset could not be persisted")
            }
        }
        await updateInbox.pruneTerminalClaims(dataRoot: dataRoot)
        await turnCardRestartRepairer.scheduleRepair { await repairInterruptedTurnCardsIfNeeded() }
        return .completed(result: "Telegram poll processed \(pending.count + updates.count) update(s)")
    }

    /// Reconcile the durable inbox: a live owner keeps its processing claim; an orphaned one becomes outcome-unknown, reported once.
    private func reconcileRecoveredClaims(updateInbox: TelegramUpdateInbox) async -> TickStep<[TelegramUpdateClaim]> {
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
                    // A live in-process owner is not orphaned: its claim stays processing through the turn so a crash preserves recoverable ingress.
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
                        // Report unknown outcomes once on their originating surface without replaying effects.
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
                evidence: .init(source: updateInbox.directory.path, id: NativeTimestampFormat.fractionalZulu(Date())))
        } catch {
            let failure = updateInbox.repairFailure(error, dataRoot: dataRoot)
            guard let owner = failure.owner else {
                await recordError(context: "update_inbox_load", error: failure.message)
                return .end(.failed(error: failure.message))
            }
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run,
                operation: "telegram.inbox:" + updateInbox.directory.path, owner: owner,
                words: failure.message, nextCall: failure.nextCall)
            await recordError(context: "update_inbox_load", error: failure.message)
            return .end(.failed(error: failure.message))
        }
        return .proceed(recoveredClaims)
    }

    /// One upstream poll after durable recovery, gated by transport backoff.
    private func pollForUpdates(offset: Int) async -> TickStep<TelegramPollResult> {
        let result: TelegramPollResult
        guard await pollBackoff.shouldAttempt() else {
            return .end(.backingOff(reason: "Telegram poll backoff active"))
        }
        await syncCommandMenuIfNeeded()
        do {
            result = try await bot.longPoll(
                token: token, offset: offset,
                timeoutSeconds: 25, session: longPollSession
            )
        } catch is CancellationError {
            // Shutdown cancellation must not write outage errors or advance failure backoff.
            return .end(.skipped(reason: "Telegram poll cancelled"))
        } catch {
            let retryDelay = await pollBackoff.recordFailure()
            let failures = await pollBackoff.failureCount()
            FileHandle.standardError.write(Data(
                """
                    TelegramPollLoop: poll failed (failure #\(failures), next attempt in \(String(format: "%.1f", retryDelay))s): \
                    \(TurnSecretRedactor.redactText(String(describing: error)))\n
                    """.utf8
            ))
            await recordError(context: "poll", error: String(describing: error))
            await writeStatePatch([
                "pollBackoffFailures": .int(Int64(failures)),
                "pollBackoffRetryDelaySeconds": .double(retryDelay),
            ])
            return .end(.failed(error: TurnSecretRedactor.redactText("Telegram long poll: \(error)")))
        }
        let recovered = await pollBackoff.failureCount() > 0
        await pollBackoff.recordSuccess()
        let checkpointDue = await longPollSession.recordSuccessfulPoll()
        if checkpointDue || recovered || !result.updates.isEmpty {
            await writeStatePatch([
                "lastPollAt": .string(NativeTimestampFormat.fractionalZulu(Date())),
                "lastError": .null,
                "pollBackoffFailures": .int(0),
                "pollBackoffRetryDelaySeconds": .null,
            ])
        }
        return .proceed(result)
    }

    func retainForSpeechPermission(error: Error, card: TelegramTurnProgressCardDriver,
                                   update: TelegramUpdate, message: TelegramMessage, text: String) async {
        await settle {
            do {
                _ = try await TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot).transition(
                    updateId: update.updateId, from: [.processing], to: .awaitingSpeechPermission)
            } catch {
                await recordError(context: "speech_permission_settlement", error: String(describing: error),
                    update: update, message: message, text: text)
                return
            }
            await card.transition(.failed(reason: Self.chatErrorNotice(for: error)))
            await recordError(context: "media_preparation", error: String(describing: error), update: update, message: message, text: text)
            await onCapabilityDenied?("speechRecognition")
            if await !voicePermissionNotice.sent {
                do {
                    try await Self.defaultSendMessage(token, message.destination, """
                        The voice note is saved. I've asked the Mac for Speech Recognition: allow it there and I'll transcribe this note \
                        and the next ones by myself. If the Mac refused it before, the card in NativeAgent opens the exact pane.
                        """)
                    await voicePermissionNotice.setSent(true)
                } catch {
                    await recordError(context: "send_voice_permission_notice", error: String(describing: error),
                        update: update, message: message, text: nil)
                }
            }
        }
    }

    /// Runs only after the destination's turn owns cancellation and its durable update claim. No download or transcription can hold the poller's tick.
    func prepareIncomingMedia(
        text: String, caption: String?, voice: TelegramMediaAttachment?, media: TelegramMediaAttachment?,
        update: TelegramUpdate, message: TelegramMessage, turn: Turn
    ) async throws -> (text: String, attachments: [TelegramMediaAttachment], receiptKind: String) {
        try Task.checkCancellation()
        if let voice {
            guard let voiceTranscriber else {
                throw TelegramVoiceTranscriptionError.speechUnavailable("Voice transcription is not configured. Enable it on the Mac before resending.")
            }
            do { try await Self.defaultSendChatAction(token, message.destination, "typing") }
            catch { await recordError(context: "voice_typing", error: String(describing: error), update: update, message: message) }
            var downloaded = try await mediaDownloader.download(token: token, attachment: voice, maxBytes: voiceMaxBytes)
            let transcription = try await voiceTranscriber.transcribe(downloaded)
            try Task.checkCancellation()
            guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TelegramVoiceTranscriptionError.malformedResponse
            }
            await voicePermissionNotice.setSent(false)
            await recordVoiceTranscription(update: update, message: message, attachment: downloaded, transcription: transcription)
            var utterance = transcription.utterance
            utterance.correctionReferences = []
            downloaded.utterance = utterance
            let spoken = "[Telegram voice message]\n" + transcription.utterance.face
            return (caption.map { $0 + "\n\n" + spoken } ?? spoken, [downloaded], "voice_reply")
        }
        guard let media else { return (text, [], "reply") }
        // The message's own caption, never a text saved from an earlier attempt: a retry carries no stale missing-media fact.
        let said = caption.flatMap { $0.isEmpty ? nil : $0 } ?? text
        do {
            let downloaded = try await mediaDownloader.download(token: token, attachment: media,
                maxBytes: chatAttachmentMaxBytes(media))
            try Task.checkCancellation()
            guard let bytes = downloaded.bytes, !bytes.isEmpty else { throw TelegramMediaDownloadError.malformedResponse }
            let mime: String
            if downloaded.kind == "photo" {
                guard let photoMime = Self.imageMime(forFilename: downloaded.captureFilename, fallbackMime: downloaded.mimeType) else {
                    throw TelegramMediaDownloadError.malformedResponse
                }
                mime = photoMime
            } else {
                guard let resolved = downloaded.chatTypeAndMime else { throw TelegramMediaDownloadError.malformedResponse }
                mime = resolved.mime
            }
            return (said, [TelegramMediaAttachment(kind: downloaded.kind, fileId: downloaded.fileId, mimeType: mime,
                sizeBytes: downloaded.sizeBytes ?? bytes.count, bytes: bytes, captureFilename: downloaded.captureFilename)],
                caption == nil ? (media.chatTypeAndMime?.type == "file" ? "document_reply" : "photo_reply") : "reply")
        } catch {
            if !(error is CancellationError) {
                await emitAttachmentDroppedTrace(kind: media.kind, reason: String(describing: error),
                    chatId: message.chatId, updateId: update.updateId, turn: turn)
            }
            // A readable caption still reaches the turn with the named missing-media fact; only an attachment-only message fails.
            guard caption?.isEmpty == false, !(error is CancellationError), !Task.isCancelled else { throw error }
            return (said + "\n\n[Telegram attachment preparation]\n" + Self.attachmentDroppedNotice(for: error), [], "reply")
        }
    }
}

/// Keep Stop registered until the owning operation ends, including queue drops and admission failure.
final class TelegramRunStop: Sendable {
    private let flag: URL
    init(_ flag: URL) { self.flag = flag }
    var isRaised: Bool { ChatCancelFlag.isRaised(flag) }
    var readFailure: String? { ChatCancelFlag.readFailure(flag) }
    deinit { ChatCancelFlag.finish(flag) }
}
