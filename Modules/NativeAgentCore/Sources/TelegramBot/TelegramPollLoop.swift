import AuthoredCapabilities
import Foundation
import NativeAgentShared
import ApprovalInbox
import NativeAgentCore
import MacControl
import os
import PersistenceCore
import BackgroundLoops
import ProviderRouting
import TurnTrace
import Transcripts
import ChatTurnRuntime
import ChatTurnContracts
import Experiences

// Blueprint: | `TelegramPollLoop.swift` | `TelegramPollLoop`: authenticated update intake; tracked media preparation retains unstarted updates on shutdown and settles explicit Stop; saved reply recovery and checkpoint settlement |

// MARK: - TelegramPollLoop

/// Periodic long-poll worker that conforms to BackgroundLoops.LoopRunner.
/// `interval` is the gap BETWEEN ticks; each tick blocks up to ~25s inside
/// `longPoll` while Telegram holds the connection open. Set `interval` low
/// (default 2s) so back-to-back polls flow without idle gaps.
public struct TelegramPollLoop: LoopRunner {
    public let loopId: String = "telegram_poll"
    public let interval: TimeInterval
    /// Bounds long-poll intake; tracked conversation tasks own their work.
    public var tickTimeoutOverride: TimeInterval? { 3600 }
    let token: String
    let allowedChatIds: Set<Int64>
    let allowedUserIds: Set<Int64>
    let requireMention: Bool
    let bot: SwiftNativeTelegramBot
    let longPollSession = TelegramLongPollSession()
    public var lastSuccessfulPollAt: Date? { get async { await longPollSession.lastSuccessfulPollAt } }
    let dataRoot: URL
    let partFace: PartFaces.Call

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
                  fields["type"]?.stringValue == "mention",
                  let offset = (fields["offset"]?.integerValue.flatMap(Int.init(exactly:)) ?? fields["offset"]?.stringValue.flatMap(Int.init)),
                  let length = (fields["length"]?.integerValue.flatMap(Int.init(exactly:)) ?? fields["length"]?.stringValue.flatMap(Int.init)),
                  offset >= 0, length > 0, offset <= source.length,
                  length <= source.length - offset else { return false }
            return source.substring(with: NSRange(location: offset, length: length))
                .compare("@\(botUsername)", options: .caseInsensitive) == .orderedSame
        }
    }
    let offsetURL: URL
    let legacyOffsetURL: URL
    var botIdentity: String { String(token.prefix { $0 != ":" }) }
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
    /// Signal only missing TCC grants on the Mac, by capability name; nil disables the signal.
    let onCapabilityDenied: (@Sendable (String) async -> Void)?
    let voiceMaxBytes: Int
    let photoMaxBytes: Int
    let turnCoordinator: TelegramTurns
    let revokeDriverControl: @Sendable () async -> Void
    let turnCardLedger: TelegramTurnCardLedger
    let turnCardRestartRepairer: TelegramTurnCardRestartRepairer
    /// Retain admitted continuations awaiting replies; their approved tools have already run.
    let approvalInbox: SwiftNativeApprovalInbox
    /// Poll-failure backoff retains its default curve and state across ticks.
    let pollBackoff: TelegramExponentialBackoff
    /// Back off command-menu sync failures from 5 to 300 seconds.
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
        answerCallbackQuery: @escaping @Sendable (_ token: String, _ callbackId: String, _ text: String) async throws -> Void = TelegramPollLoop.defaultAnswerCallbackQuery,
        syncCommandMenu: TelegramCommandMenuSync? = TelegramPollLoop.defaultSyncCommandMenu,
        approvalHandler: (any TelegramApprovalHandling)? = nil,
        attachmentChatHandler: TelegramProgressChatHandlerWithAttachments? = nil,
        voiceTranscriber: SwiftAppleSpeechTranscriber? = nil,
        onCapabilityDenied: (@Sendable (String) async -> Void)? = nil,
        voiceMaxBytes: Int = TelegramConfig.defaultVoiceMaxBytes,
        photoMaxBytes: Int = TelegramPollLoop.defaultPhotoMaxBytes,
        turnCoordinator: TelegramTurns = .shared
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
        self.partFace = partFace
        self.legacyOffsetURL = offsetURL
        self.offsetURL = offsetURL.deletingLastPathComponent()
            .appendingPathComponent("bots", isDirectory: true)
            .appendingPathComponent(Self.botStorageIdentity(token), isDirectory: true)
            .appendingPathComponent(offsetURL.lastPathComponent)
        self.answerCallbackQuery = answerCallbackQuery
        let cardLedger = TelegramTurnCardLedger.shared(
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
        let runId = response.runId, reply = response.output, imagePaths = Self.replyImagePaths(response)
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
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
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        guard !(await turnCoordinator.isUpdateProcessing(original.updateId)) else { return "owed" }
        return try await inbox.withAssistantDeliveryLock(updateId: original.updateId) {
        let claim = try inbox.claim(updateId: original.updateId)
        if let reason = claim.quarantineReason { throw TelegramBotError.underlying(reason) }
        guard let message = claim.update.message else {
            throw TelegramBotError.underlying("telegram_claim_message_missing: Saved update \(claim.updateId) has no message. Inspect its update_inbox claim before attempting delivery.")
        }
        // Synthetic outbound claims name the recipient; a private chat id is that user's id.
        guard Self.inboundAuthorizationDecision(
            allowedChatIds: allowedChatIds,
            allowedUserIds: allowedUserIds,
            chatId: message.chatId,
            fromUserId: message.fromUserId
        ) == .allowed || (claim.updateId < 0 && message.chatId > 0
            && allowedUserIds.contains(Int64(message.chatId))) else {
                throw TelegramBotError.underlying("telegram_destination_not_allowed: Saved reply destination is not allowed. Review allowed chat and user IDs in Telegram setup; do not resend to another destination.")
            }
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
        guard let delivery else {
            throw TelegramBotError.underlying("telegram_reply_missing: No saved reply is available for update \(claim.updateId). Inspect its conversation and update_inbox claim before attempting delivery.")
        }
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
        await recoverApprovalRepliesIfNeeded()
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
        let updateInbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
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
            .filter({ $0.phase != .pending && $0.updateId >= 0 })
            .compactMap({ $0.update.nextOffset })
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
            // Backoff gates polling and menu sync without clearing failures; recovery runs above.
            guard await pollBackoff.shouldAttempt() else {
                return .backingOff(reason: "Telegram poll backoff active")
            }
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
                    "TelegramPollLoop: poll failed (failure #\(failures), next attempt in \(String(format: "%.1f", retryDelay))s): \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8
                ))
                await recordError(context: "poll", error: String(describing: error))
                await writeStatePatch([
                    "pollBackoffFailures": .int(Int64(failures)),
                    "pollBackoffRetryDelaySeconds": .double(retryDelay),
                ])
                return .failed(error: TurnSecretRedactor.redactText("Telegram long poll: \(error)"))
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
            case .completed, .outcomeUnknown, .sentUnconfirmed, .failedBeforeAnswer, .quarantined, .stopped:
                continue
            case .awaitingSpeechPermission:
                continue
            case .processing:
                // Recovery leaves claims owned by live in-process turns in .processing.
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
                            try await Self.defaultSendMessage(token, message.destination,
                                "This queued message has no saved conversation binding. Select the conversation and resend it; I haven't run it.")
                        }
                        _ = try await updateInbox.transition(updateId: claim.updateId,
                            from: [.queued], to: .outcomeUnknown)
                    } catch {
                        return .failed(error: "Telegram queued conversation recovery failed: \(error)")
                    }
                    continue
                }
                // This process already owns the claim, waiting in the queue or
                // dequeued and starting (the durable phase leaves `.queued`
                // only once the turn body runs). Rehydrate only after restart;
                // otherwise a tick in that gap runs the message twice.
                if await turnCoordinator.isUpdateProcessing(claim.updateId) { continue }
                if await turnCoordinator.queuedTurn(
                    destination: claim.update.message?.destination ?? .chat(0),
                    updateId: claim.updateId
                ) != nil {
                    continue
                }
                // Restart rehydration: own it from here to its settle, as ingress does.
                await turnCoordinator.beginUpdateProcessing(claim.updateId)
                break
            }
            await recordSeen(update: update)
            guard let updateOffset = update.nextOffset else {
                return .failed(error: "Telegram update ID has no representable successor")
            }
            if updateOffset > persistedOffset {
                guard let advanced = await persistOffset(updateOffset, cursor: cursor) else {
                    return .failed(error: "Telegram update \(update.updateId) was claimed but its offset could not be persisted")
                }
                persistedOffset = advanced
            }
            if claim.phase == .pending {
            // Register the live owner before entering .processing, including media preparation.
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
            // Authorize before slash dispatch: chat OR sender must be allowlisted; empty lists fail closed.
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
                return extras["caption"]?.stringValue ?? ""
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
            if voiceAttachment != nil, voiceTranscriber != nil {
                text = "[Telegram voice message]" + (textFromMessage.map { "\n" + $0 } ?? "")
            } else if let existing = textFromMessage, !existing.isEmpty {
                text = existing
            } else if voiceAttachment != nil {
                let notice = "(I got your voice note, but Telegram voice transcription is not configured.)"
                do {
                    try await Self.defaultSendMessage(token, msg.destination, notice)
                    await recordReceipt(kind: "voice_transcription_unavailable", update: update, message: msg, text: "[Telegram voice message]", reply: notice)
                } catch {
                    await recordError(context: "send_voice_unavailable_notice", error: String(describing: error), update: update, message: msg, text: nil)
                }
                break updateProcessing
            } else if let mediaAttachment {
                text = mediaAttachment.chatTypeAndMime?.type == "file"
                    ? "[The user sent a file with no caption. Read it and respond.]"
                    : "[The user sent an image with no caption. Look at it and respond.]"
            } else {
                await recordBlocked(reason: "empty_or_non_text", update: update, message: msg, text: msg.text)
                break updateProcessing
            }
            if text.hasPrefix("/") {
                // Accept bare commands or a verified @ThisBot suffix before applying the mention filter.
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
                // The tracked command task owns its reply and claim settlement, leaving polling free.
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
            // Pin and register the turn before media work. The poller can
            // keep admitting Stop, callbacks and other destinations meanwhile.
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
                    try await Self.defaultSendMessage(token, msg.destination, notice)
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
            let signalArrival: @Sendable (String, String) -> Void = { turnId, text in
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
                let preparedText = await runTurn(turnId: turnId, update: update, message: msg,
                    text: text, sessionId: turnSessionId) { card in
                    await card.transition(.working(action: voiceAttachment != nil ? "Transcribing voice message" : mediaAttachment != nil ? "Preparing attachment" : nil))
                    let prepared: (text: String, attachments: [TelegramMediaAttachment], receiptKind: String)
                    do {
                        prepared = try await prepareIncomingMedia(text: text, caption: textFromMessage,
                            voice: voiceAttachment, media: mediaAttachment, update: update, message: msg)
                        try Task.checkCancellation()
                    } catch {
                        // No chat turn has started: shutdown may release media
                        // for recovery, while an explicit Stop remains terminal.
                        let canceled = Task.isCancelled || error is CancellationError
                        let shuttingDown = await turnCoordinator.shutdownInterruptedTurn(destination: msg.destination, turnId: turnId)
                        let retryAfterShutdown = canceled && shuttingDown && !runStop.isRaised
                            && (voiceAttachment != nil || mediaAttachment != nil)
                        await settle {
                            let permission = !canceled && Self.isSpeechPermissionDenial(error)
                            await card.transition(canceled ? .canceled(reason: retryAfterShutdown ? "Interrupted by shutdown; message saved for retry" : "Stopped by user") : .failed(reason: Self.chatErrorNotice(for: error)))
                            if permission, await !voicePermissionNotice.sent {
                                await onCapabilityDenied?("speechRecognition")
                                do {
                                    try await Self.defaultSendMessage(token, msg.destination, "The voice note is saved. I've asked the Mac for Speech Recognition: allow it there and I'll transcribe this note and the next ones by myself. If the Mac refused it before, the card in NativeAgent opens the exact pane.")
                                    await voicePermissionNotice.setSent(true)
                                } catch {
                                    await recordError(context: "send_voice_permission_notice", error: String(describing: error), update: update, message: msg, text: nil)
                                }
                            } else if !permission, !canceled {
                                let notice = voiceAttachment != nil ? Self.voiceTranscriptionNotice(for: error) : Self.attachmentDroppedNotice(for: error)
                                do {
                                    try await Self.defaultSendMessage(token, msg.destination, notice)
                                    await recordReceipt(kind: "media_error", update: update, message: msg, text: text, reply: notice)
                                } catch {
                                    await recordError(context: "send_media_error_notice", error: String(describing: error), update: update, message: msg, text: text)
                                }
                            }
                            if !retryAfterShutdown {
                                await recordError(context: "media_preparation", error: String(describing: error), update: update, message: msg, text: text)
                            }
                            do {
                                _ = try await updateInbox.transition(updateId: update.updateId, from: [.processing],
                                    to: permission ? .awaitingSpeechPermission : retryAfterShutdown ? .pending : canceled ? .stopped : .completed,
                                    resolvedSessionId: retryAfterShutdown ? turnSessionId : nil)
                            } catch {
                                await recordError(context: "media_preparation_settlement", error: String(describing: error), update: update, message: msg, text: text)
                            }
                        }
                        return nil
                    }
                    await turnCoordinator.recordLastUserMessage(destination: msg.destination, text: prepared.text, message: msg,
                        updatingCurrent: true)
                    let written = steered.withLock { $0 } ? try await SwiftNativeChatOrchestrationClient.reconcileSteeringMessage(
                        message: steeringText, sessionId: turnSessionId, runId: turnId.uuidString,
                        dataRoot: dataRoot).committed : false
                    return (prepared.text, prepared.attachments, prepared.receiptKind,
                        TelegramChatAttemptContext(replyTo: msg.replyTo, fromUserId: msg.fromUserId,
                            suppressUserAppend: written, sessionId: turnSessionId,
                            runId: turnId.uuidString, threadId: msg.destination.threadId))
                }
                if let preparedText { signalArrival(turnId.uuidString, preparedText) }
            }
            let turnOperation: @Sendable (UUID) async -> Void = { turnId in
                await TurnTraceContext.$turnId.withValue(traceTurnId) {
                    await MacWorkContinuation.$current.withValue(takeover) { await turnBody(turnId) }
                }
                withExtendedLifetime(runStop) {}
            }
            await turnCoordinator.recordLastUserMessage(destination: msg.destination, text: text, message: msg)
            guard let queuePosition = await admitTurn(
                id: queuedTurnId, priority: .userInitiated, update: update, message: msg,
                text: text, input: text, sessionId: turnSessionId,
                queuedNotice: ("Queued", "queued_notice", "send_queued_notice"),
                busyNotice: ("The Telegram queue is full. Let one of the 20 queued messages finish, or remove one, then try again.", "queue_full_notice", "send_queue_full_notice"),
                operation: turnOperation
            ) else { break updateProcessing }
            shouldCompleteClaim = false
            if queuePosition > 0 {
                let preview = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
                // Her turn reads it at its next step and decides what it means for
                // the work; one that ends first leaves it queued to run as its own.
                // Only the person's own words join a turn already working (a sender
                // allowed only by chat speaks as a stranger, in a turn of their own),
                // and media rides only with its own turn.
                if voiceAttachment == nil, mediaAttachment == nil, msg.fromUserId.map({ allowedUserIds.contains(Int64($0)) }) == true {
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
                        guard let removed = await turnCoordinator.removeQueuedTurn(destination: msg.destination, updateId: update.updateId) else {
                            return false
                        }
                        await turnCoordinator.endUpdateProcessing(update.updateId)
                        if let acknowledgement = removed.acknowledgementMessageId {
                            await clearQueueAcknowledgement(chatId: msg.chatId, messageId: acknowledgement,
                                                            runningText: "Read in the reply in progress · \(preview)")
                        }
                        signalArrival(offer.receivingTurnID ?? queuedTurnId.uuidString, text)
                        return true
                    }
                }
            }
            }
            guard shouldCompleteClaim else { continue }
            // Release the ingress registration when this claim settles.
            await turnCoordinator.endUpdateProcessing(update.updateId)
            do {
                // Completed replayed claims may still be .queued when no turn takes ownership.
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

    /// Runs only after the destination's turn owns cancellation and its durable
    /// update claim. No download or transcription can hold the poller's tick.
    func prepareIncomingMedia(
        text: String, caption: String?, voice: TelegramMediaAttachment?, media: TelegramMediaAttachment?,
        update: TelegramUpdate, message: TelegramMessage
    ) async throws -> (text: String, attachments: [TelegramMediaAttachment], receiptKind: String) {
        try Task.checkCancellation()
        if let voice, let voiceTranscriber {
            try? await Self.defaultSendChatAction(token, message.destination, "typing")
            do {
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
        }
        guard let media else { return (text, [], "reply") }
        do {
            let downloaded = try await mediaDownloader.download(token: token, attachment: media,
                maxBytes: chatAttachmentMaxBytes(media))
            try Task.checkCancellation()
            guard let bytes = downloaded.bytes, !bytes.isEmpty else { throw TelegramMediaDownloadError.malformedResponse }
            let mime: String
            if downloaded.kind == "photo" {
                mime = Self.imageMime(forFilename: downloaded.captureFilename, fallbackMime: downloaded.mimeType) ?? "image/jpeg"
            } else {
                guard let resolved = downloaded.chatTypeAndMime else { throw TelegramMediaDownloadError.malformedResponse }
                mime = resolved.mime
            }
            return (text, [TelegramMediaAttachment(kind: downloaded.kind, fileId: downloaded.fileId, mimeType: mime,
                sizeBytes: downloaded.sizeBytes ?? bytes.count, bytes: bytes, captureFilename: downloaded.captureFilename)],
                caption == nil ? (media.chatTypeAndMime?.type == "file" ? "document_reply" : "photo_reply") : "reply")
        } catch {
            if !(error is CancellationError) {
                await emitAttachmentDroppedTrace(kind: media.kind, reason: String(describing: error),
                    chatId: message.chatId, updateId: update.updateId)
            }
            throw error
        }
    }
}

/// A door's Stop registration for one run, finished when the turn operation
/// holding it is released: run to its end, dropped from the queue, or never
/// queued at all.
final class TelegramRunStop: Sendable {
    private let flag: URL
    init(_ flag: URL) { self.flag = flag }
    var isRaised: Bool { ChatCancelFlag.isRaised(flag) }
    deinit { ChatCancelFlag.finish(flag) }
}
