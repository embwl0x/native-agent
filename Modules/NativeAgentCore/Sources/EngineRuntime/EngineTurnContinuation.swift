import Agents
import Experiences
import AttentionRouting
import BackgroundWork
import BackgroundLoops
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import CognitiveSubstrate
import CryptoKit
import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import StandingBots
import TelegramBot
import SlackBot
import DeviceSync
import Transcripts
import TrustCenter
import TurnTrace
import ApprovalTransactions
import os
// Blueprint: | `EngineTurnContinuation.swift` | `TurnContinuationRuntime`: turns a relaunch interrupted resume, settled Desk waits return, reply settlement |

/// Turns a relaunch interrupted resume through the admitted turn path; a settled Desk wait returns to its conversation as a `returned` happening; approval
/// claims keep their own settlement rules.
public struct TurnContinuationRuntime: Sendable {
    private let dataRoot: URL
    private let engine: NativeAgentEngine
    private let telegramApprovalFiler: @Sendable () -> (any ApprovalFiler)?
    private let makeSender: @Sendable (Bool, String?, @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending

    public init(dataRoot: URL, engine: NativeAgentEngine, telegramApprovalFiler: @escaping @Sendable () -> (any ApprovalFiler)? = { nil },
                makeSender: @escaping @Sendable (Bool, String?, @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending) {
        self.dataRoot = dataRoot
        self.engine = engine
        self.telegramApprovalFiler = telegramApprovalFiler
        self.makeSender = makeSender
    }

    public func resumeAtLaunch(_ checkpoint: TurnCheckpoint,
        resumeMacTurn: @Sendable (TurnCheckpoint, TurnContinuationRuntime) async throws -> Void) async throws {
        // Worker checkpoints belong to their sessionless caller; abandon interrupted answers there so claim recovery cannot also resume them as chat turns.
        if checkpoint.sessionId == "worker-" + checkpoint.runId {
            try checkpoint.remove(dataRoot: dataRoot)
            ExperienceStore.record(dataRoot, checkpoint.runId) { store in
                try await store.append([.letGo(key: "answer", reason: .abandoned)], to: checkpoint.runId)
            }
            return
        }
        if checkpoint.capabilityProfile == "mac", checkpoint.surface == "chat", checkpoint.helperDefinition == nil {
            try await resumeMacTurn(checkpoint, self)
        } else { try await resumeTurn(checkpoint) }
    }

    /// Mirror only person-started Mac, iPhone or Slack anchor replies to Telegram; push only Slack to the phone. Settlement retains intent while delivery
    /// runs off-turn.
    @MainActor
    public static func installReplyMirror() {
        AbandonedTurnReconciliationHook.installReplyMirror { root, session, run in
            try await retainMirrorIntent(sessionId: session, runId: run, dataRoot: root)
        }
    }

    private static let mirrorDoors = ["chat": "Mac", "ios": "iPhone", "slack": "Slack"]

    private static func mirrorLifecycle(dataRoot: URL) -> CodexCompletionLifecycle {
        CodexCompletionLifecycle(receiptURL: dataRoot.appendingPathComponent("chat/anchor-mirror/receipts.jsonl"),
            ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
    }

    private static func retainMirrorIntent(sessionId: String, runId: String, dataRoot: URL, requiresAnchor: Bool = true) async throws {
        guard !requiresAnchor || sessionId == ConversationAnchor.currentSessionId(dataRoot: dataRoot),
              let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId, runId: runId),
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        let read = try await SwiftNativePersistenceCore.withFileLock(path) { try await SwiftNativePersistenceCore.readJSONLReporting(path) }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw CocoaError(.fileReadCorruptFile) }
        guard case .object(let reply)? = read.rows.last(where: {
            if case .object(let row) = $0 { return row["role"] == .string("assistant") && row["runId"] == .string(runId) }; return false
        }), case .string(let rowId)? = reply["id"],
            case .object(let ask)? = read.rows.last(where: {
                if case .object(let row) = $0 { return row["role"] == .string("user") && row["runId"] == .string(runId) }; return false
            }), case .object(let metadata)? = ask["metadata"], metadata["origin"] == nil,
            metadata[CognitiveMechanicalRowKind.metadataKey] == nil, case .object(let envelope)? = metadata["envelope"],
            envelope["agent"] == nil, case .string(let surface)? = envelope["surface"], let door = mirrorDoors[surface] else { return }
        let deliveryId = "anchor-mirror:" + rowId
        let digest = SHA256.hash(data: Data((rowId + "\u{1f}" + response.output).utf8)).map { String(format: "%02x", $0) }.joined()
        var route: AgentBridgeCompletionRoute?
        var preparationError: Error?
        do {
            var notificationId: String?
            if door == "Slack" {
                if case .object(let metadata)? = reply["metadata"], case .object(let intent)? = metadata["resultDelivery"],
                   case .string(let eventID)? = intent["eventId"] {
                    guard eventID.hasPrefix("requested-result:") else {
                        throw NSError(domain: "TurnContinuationRuntime", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The requested result has not been accepted for phone delivery."])
                    }
                    notificationId = String(eventID.dropFirst("requested-result:".count))
                } else { notificationId = deliveryId }
                try await SwiftNativeChatOrchestrationClient.retainRequestedResult(dataRoot: dataRoot, sessionId: sessionId,
                    runId: runId, deliveryId: "requested-result:" + (notificationId ?? deliveryId))
            }
            guard let telegram = try await TelegramSessionStore(dataRoot: dataRoot).outboundDestination(sessionId: sessionId) else { return }
            route = AgentBridgeCompletionRoute(surface: "telegram", sessionId: sessionId,
                destinationId: String(telegram.chatId), threadId: telegram.threadId.map(String.init),
                sourceKey: surface, correlationId: notificationId)
        } catch { preparationError = error }
        let lifecycle = mirrorLifecycle(dataRoot: dataRoot)
        switch try await lifecycle.claim(deliveryId: deliveryId, requestDigest: digest, sessionId: sessionId,
                                         responseRunId: runId, route: route, source: surface) {
        case .start, .inProgress:
            try await lifecycle.cacheResponse(response, deliveryId: deliveryId, requestDigest: digest)
        case .cached: break
        case .settled, .outcomeUnknown, .conflict: throw CodexCompletionLifecycle.LifecycleError.requestConflict
        }
        if let preparationError {
            try await lifecycle.recordDelivery(AgentBridgeCompletionDelivery(status: "owed", surface: "telegram",
                delivery: "anchor_mirror", artifactCount: 1, attempts: 0, reason: preparationError.localizedDescription),
                deliveryId: deliveryId, requestDigest: digest)
            throw preparationError
        }
    }

    public func reconcileReplyMirror() async throws {
        let lifecycle = Self.mirrorLifecycle(dataRoot: dataRoot)
        _ = try await lifecycle.reconcileInterruptedClaims()
        for row in try await lifecycle.reconciliationRows() where (row.status == "owed" || row.status == "sent_unconfirmed") && !row.routeSettled {
            guard let response = row.response else { continue }
            guard let route = row.route else {
                if let session = response.sessionId {
                    try await Self.retainMirrorIntent(sessionId: session, runId: response.runId, dataRoot: dataRoot, requiresAnchor: false)
                }
                continue
            }
            guard let surface = route.sourceKey else { continue }
            let text = "[\(Self.mirrorDoors[surface] ?? surface)]\n" + response.output
            let turn = Turn(run: response.runId, session: response.sessionId)
                .with(\.envelope, .native("reply_mirror:" + row.id, surface: surface))
                .with(\.verifiedSessionID, response.sessionId)
            _ = await AgentBridgeCompletionRouter.deliver(turn: turn, deliveryId: row.id, requestDigest: row.digest,
                text: text, attachments: response.attachments ?? [], route: route,
                sender: makeSender(surface == "chat", route.correlationId, { config, chatID in
                    TelegramPollLoop.inboundAuthorizationDecision(allowedChatIds: config.allowedChatIds,
                        allowedUserIds: config.allowedUserIds, chatId: chatID, fromUserId: chatID > 0 ? chatID : nil) == .allowed
                }), lifecycle: lifecycle, notifyRequestedResult: surface == "slack")
        }
    }

    /// A Desk wait settles when every helper it waits on has its receipt. It is work coming back: a `returned` happening to the conversation of the turn
    /// that waited, whose turn there goes on with the item. A turn that ended interrupted is not a wait: it is blocked where it stopped and never resumed
    /// on its own; one with a checkpoint of its run is the relaunch's to resume. One item's failure is that item's; its siblings proceed.
    public func returnSettledDeskWaits() async throws {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        var failures: [String] = []
        for item in try await store.liveState().items.sorted(by: { $0.handle < $1.handle }) {
            do { try await returnIfSettled(item, store: store) }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("Desk item \(item.alias): \(error.localizedDescription)") }
        }
        guard failures.isEmpty else {
            throw NSError(domain: "NativeAgent.DeskWaits", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }

    private func returnIfSettled(_ item: DeskItem, store: SwiftNativeDeskStore) async throws {
        guard var record = item.continuation, !item.requiresOwnerInput, !item.status.isTerminal else { return }
        let interrupted = record.state == .running ? record.processID != DeskContinuationScope.processID
            : record.state == .ready && record.reason == "turn_interrupted"
        guard record.state == .ready || interrupted else { return }
        let expected = record.revision
        if interrupted {
            guard try !checkpointed(record) else { return }
            record.state = .blocked
            record.reason = "turn_interrupted"
            record.revision = UUID().uuidString
            try await store.setContinuation(item.handle, expectedRevision: expected, record: record)
            return
        }
        var waiting = false
        var unknown: [String] = []
        var settled: [DeskContinuation.Step] = []
        for var step in record.pending {
            switch try helperReceipt(step) {
            case .settled(let receipt):
                step.result = receipt
                step.owner = nil
                settled.append(step)
            case .waiting: waiting = true
            case .unknown(let why): unknown.append("\(step.tool) \(step.id): \(why)")
            }
        }
        guard unknown.isEmpty else {
            record.state = .blocked
            record.reason = "domain_verification_required: " + unknown.prefix(3).joined(separator: ", ")
            record.revision = UUID().uuidString
            try await store.setContinuation(item.handle, expectedRevision: expected, record: record)
            return
        }
        guard !waiting else { return }
        record.settled += settled
        record.pending = []
        let shown = (["Remaining work: " + record.remainingWork]
            + record.settled.suffix(12).map { "\($0.id) \($0.tool): \($0.result ?? "")" }
            + (record.lastReply.isEmpty ? [] : ["Your last reply: " + String(record.lastReply.prefix(1_000))])).joined(separator: "\n")
        // A helper's own wait returns to the agent's mind stream: a turn of the agent's inside a helper's session would speak as the helper.
        let helper = record.helperDefinition != nil
        let reply: String? = try helper ? nil : JSONValue.object(record.envelope).serialize(pretty: false)
        let whose = helper ? "A helper's Desk item" : "Your Desk item"
        // Written before the record lets the wait go, so a quit between the two returns it on the next change, once.
        await Attention.post(Happening(.returned, subject: "desk:" + item.handle, door: "desk",
            words: "What \(whose) \(item.alias) (\"\(String(item.title.prefix(80)))\") waited on came back; it is yours to go on with.",
            once: "desk:" + item.handle + ":" + record.runID, route: helper ? nil : record.sessionID, reply: reply, peers: record.peerSources,
            shows: shown), dataRoot: dataRoot).value
        record.state = .complete
        record.reason = "returned"
        record.revision = UUID().uuidString
        try await store.setContinuation(item.handle, expectedRevision: expected, record: record)
    }

    /// Only a checkpoint of this run assigns its continuation to launch recovery.
    private func checkpointed(_ record: DeskContinuation) throws -> Bool {
        guard let session = record.sessionID else { return false }
        for turn in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: session) {
            if try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: session, turnId: turn)?.runId == record.runID { return true }
        }
        return false
    }

    private enum Receipt { case settled(String), waiting, unknown(String) }

    /// A helper's request settles on its own shelf entry; a queued or running one is still waited on. Any other open step has no receipt a wait reads.
    private func helperReceipt(_ step: DeskContinuation.Step) throws -> Receipt {
        guard step.owner == "helper" else { return .unknown("its outcome has no receipt this wait can read") }
        guard let ownerID = step.ownerID, let botID = UUID(uuidString: ownerID),
              let requestID = step.requestID, let request = UUID(uuidString: requestID) else {
            return .unknown("helper run has no exact request reference")
        }
        let queue = BotRunQueue(dataRoot: dataRoot)
        guard try queue.presence(bot: botID, requestID: request) == .absent else { return .waiting }
        if let detail = try queue.refusal(bot: botID, requestID: request) {
            return .unknown("helper request \(requestID) was refused before execution: \(detail)")
        }
        let entry: ShelfEntry
        do { entry = try ShelfStore(dataRoot: dataRoot).entry(request) }
        catch StandingBotsError.notFound { return .unknown("helper request \(requestID) has no queued request, live claim, or result") }
        guard entry.botId == botID, entry.id == request else { throw DeskContinuationError.unsafe }
        guard entry.runtimeStatus == .completed, !entry.uncertainties.contains("Run receipt pending finalization.") else {
            return .unknown("helper request \(requestID) ended \(entry.runtimeStatus.rawValue)")
        }
        return .settled("helper request \(requestID) completed")
    }

    public func resumeTurn(_ checkpoint: TurnCheckpoint, turn parent: Turn? = nil) async throws {
        guard try DataRootLife.isCurrent(checkpoint.lifeID, in: dataRoot) else { throw CancellationError() }
        guard let surface = text(checkpoint.replyRoute, "surface") else { throw DeskContinuationError.unavailable }
        let route = AgentBridgeCompletionRoute(surface: surface, sessionId: checkpoint.sessionId,
            destinationId: text(checkpoint.replyRoute, "destinationId"), threadId: text(checkpoint.replyRoute, "threadId"),
            sourceKey: text(checkpoint.replyRoute, "sourceKey"), replyTo: text(checkpoint.replyRoute, "replyTo"),
            correlationId: text(checkpoint.replyRoute, "correlationId"), requesterUserId: text(checkpoint.replyRoute, "requesterUserId"))
        let resume: @Sendable () async throws -> Void = {
            try await resumeCheckpoint(checkpoint, route: route, parent: parent)
        }
        if route.kind == .callerResult {
            try await engine.agents.tasks.resume(route, runID: checkpoint.runId, operation: resume)
        } else { try await resume() }
    }

    private func resumeCheckpoint(_ checkpoint: TurnCheckpoint, route: AgentBridgeCompletionRoute, parent: Turn?) async throws {
        guard let saved = TurnEnvelope.fromPersistedMetadata(.object(checkpoint.envelope)),
              let name = checkpoint.capabilityProfile,
              let profile = NativeAgentAppChatSurfaceProfile(rawValue: name),
              let sources = checkpoint.peerSources else {
            throw DeskContinuationError.unavailable
        }
        let envelope = TurnEnvelope(surface: saved.surface, agent: saved.agent,
            verifiedChatId: saved.verifiedChatId, verifiedUserId: saved.verifiedUserId,
            commandSignatureVerified: checkpoint.commandSignatureVerified,
            deliveryRoute: saved.deliveryRoute, declaredRemote: checkpoint.declaredRemote,
            answerExperienceID: saved.answerExperienceID)
        let request = followUpRequest(message: checkpoint.userMessage, sessionID: checkpoint.sessionId,
            fileAccess: checkpoint.fileAccess, surface: checkpoint.surface, envelope: envelope,
            replyRoute: route.chatToolReplyRoute, pinnedRunID: checkpoint.runId)
        _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
        let client = engine.chatClient(profile: profile, approvalFiler: profile == .telegram ? telegramApprovalFiler() : nil)
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let item = try await store.liveState().items.first { $0.continuation?.runID == checkpoint.runId }
        let journal: DeskContinuationTurn?
        if let item, let record = item.continuation {
            guard item.status != .canceled else {
                throw DeskContinuationError.unavailable
            }
            journal = DeskContinuationTurn(store: store, record: record, handle: item.handle)
        } else { journal = nil }
        var turn = request.turn(id: checkpoint.turnId, parent: parent)
            .with(\.peerSteering, PeerDataTaint(restoring: sources))
        if let ceiling = checkpoint.fileAccessCeiling { turn.fileAccessCeiling = ceiling }
        let response = try await runOwnedContinuation(request, helperDefinition: checkpoint.helperDefinition,
            turn: turn, journal: journal) { turn in
            guard let current = try TurnCheckpoint.read(dataRoot: dataRoot,
                sessionId: checkpoint.sessionId, turnId: checkpoint.turnId), current.updatedAt == checkpoint.updatedAt else {
                throw DeskContinuationError.conflict
            }
            return try await client.resumeTurn(current, request: request, turn: turn, work: .init(journal: journal))
        }
        if checkpoint.hasRedeliveryOwner {
            let digest = CodexCompletionTranscriptEvidence.responseDigest(sessionId: checkpoint.sessionId,
                runId: checkpoint.runId, content: response.output, attachments: response.attachments ?? [])
            let delivery = try await settleReply(response: response, route: route, envelope: envelope, turn: turn,
                settlement: .durable(deliveryID: "turn-restart.\(checkpoint.runId)", requestDigest: digest, notifyRequestedResult: false))
            // Settled outcomes belong to the delivery journal; the checkpoint must not redeliver them.
            guard ["completed", "sent_unconfirmed", "failed_before_answer"].contains(delivery) else { return }
            try checkpoint.remove(dataRoot: dataRoot)
            if delivery != "completed" {
                try await journal?.block(reason: "reply_delivery_\(delivery)")
                return
            }
        } else if checkpoint.helperDefinition == nil, let kind = route.kind, kind == .local || kind == .callerResult {
            // Notify transcript and reply-delivery owners after recording replies so readers need not wait for integrity recovery.
            await MainActor.run {
                NotificationCenter.default.post(name: .chatTurnCompleted, object: checkpoint.sessionId)
            }
            if kind == .callerResult {
                StoreChangeBus.shared.emit(StoreChange(store: .replyDelivery,
                    path: dataRoot.appendingPathComponent("chat/messages/\(checkpoint.sessionId).jsonl")))
            }
        }
        if response.terminalState == .completed {
            if let journal, await journal.snapshot().pending.isEmpty { try await journal.delivered() }
        }
    }

    private func runOwnedContinuation(_ request: TurnRequest, helperDefinition: JSONValue?,
        turn: Turn, journal: DeskContinuationTurn?,
        operation: @escaping @Sendable (Turn) async throws -> ChatResponse) async throws -> ChatResponse {
        guard request.surface == "bot" else {
            // A resumed turn keeps its own restored place; it never joins another turn.
            return try await TurnAdmission.shared.runAlone(dataRoot: dataRoot, sessionID: turn.session, runID: turn.run, turn: turn,
                operation: operation)
        }
        guard let saved = helperDefinition else {
            throw DeskContinuationError.unavailable
        }
        let bot = try JSONDecoder().decode(BotDefinition.self, from: saved.serializedData(pretty: false))
        guard bot.sessionID == request.sessionID else {
            throw DeskContinuationError.unavailable
        }
        let runner = BotRunner(dataRoot: dataRoot, session: engine.standingBotSession(continuation: journal))
        let entry = try await runner.resume(bot: bot, message: request.message, parent: turn, scope: .init(), holdUnattended: { _ in
            !(await UnattendedWork.allowed(dataRoot: dataRoot))
        })
        let response = StandingBotContinuity.response(BotTurnReply(reply: entry.actualReply, artifacts: entry.artifacts ?? [],
            status: entry.runtimeStatus, detail: entry.statusDetail, model: entry.model, approvalID: entry.approvalID),
            sessionID: bot.sessionID, runID: entry.id.uuidString)
        // Settle helper work records after completion so continuation cannot re-run them each launch.
        if entry.runtimeStatus == .completed, let journal {
            try await journal.completeResponse(JSONValue.fromEncodable(response), reply: response.output,
                peerSources: turn.peerSteering?.checkpointSources ?? [])
        }
        return response
    }

    private func text(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let value)? = object[key] { return value }
        return nil
    }

    public func continueChatToolApproval(sessionID: String, turn: Turn, prompt: String,
                                         fileAccess: String) async throws {
        guard let envelope = turn.envelope else {
            throw ToolFailureError("The approval continuation has no recorded origin. Nothing ran.",
                effects: .none, code: "approval_origin_unavailable")
        }
        try await runApprovalAdmission(sessionID: sessionID, envelope: envelope, prompt: prompt, turn: turn) { turn in
            try await runApprovalFollowUp(sessionID: sessionID, envelope: envelope, prompt: prompt,
                fileAccess: fileAccess, turn: turn)
        }
    }

    /// Every replayed call retains the card’s door, Trust, peer floor and bound steering.
    private func runApprovalFollowUp(sessionID: String, envelope: TurnEnvelope, prompt: String,
                                     fileAccess: String, turn: Turn) async throws {
        let door = ConversationSurfaceProfile(envelope.surface)
        let response: ChatResponse
        if door.id == "bot" {
            guard let bot = try BotDefinitionStore(dataRoot: dataRoot).definition(forSession: sessionID),
                  bot.deleted != true else {
                throw BotRunnerError.cannotRun("The approval's helper definition is unavailable. Repair its exact helper ownership before continuing.")
            }
            // Acquire the helper claim before turn admission so approval waiting cannot hold the session’s turn slot.
            let runner = BotRunner(dataRoot: dataRoot,
                session: engine.standingBotSession(fileAccess: fileAccess))
            let followUp = followUpRequest(message: prompt, sessionID: sessionID, fileAccess: fileAccess,
                surface: envelope.surface, envelope: envelope, replyRoute: envelope.replyRoute).turn(parent: turn)
            let entry = try await runner.ask(bot: bot.id, question: prompt, parent: followUp, scope: .init())
            response = StandingBotContinuity.response(BotTurnReply(reply: entry.actualReply,
                artifacts: entry.artifacts ?? [], status: entry.runtimeStatus, detail: entry.statusDetail,
                model: entry.model, approvalID: entry.approvalID), sessionID: sessionID, runID: entry.id.uuidString)
        } else {
            let profile: NativeAgentAppChatSurfaceProfile
            if door.isAgentBridge { profile = .bridge }
            else if door.isIOSRemote { profile = .ios }
            else if door.id == "chat" { profile = .mac }
            else if let supported = NativeAgentAppChatSurfaceProfile(rawValue: door.id) { profile = supported }
            else {
                throw NSError(domain: "ApprovalContinuation", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported approval continuation surface: \(door.id). Repair the card's origin before continuing."
                ])
            }
            let client = engine.chatClient(profile: profile,
                approvalFiler: profile == .telegram ? telegramApprovalFiler() : nil)
            response = try await followUpRequest(message: prompt, sessionID: sessionID, fileAccess: fileAccess,
                surface: envelope.surface, envelope: envelope, replyRoute: envelope.replyRoute).chat(on: client, parent: turn)
        }
        // Keep one claim over turn and delivery; failed or uncertain sends must never trigger another model turn.
        let saved = envelope.replyRoute
        let route = AgentBridgeCompletionRoute(surface: saved.surface, sessionId: sessionID,
            destinationId: saved.destinationId, threadId: saved.threadId, sourceKey: saved.sourceKey,
            replyTo: saved.replyTo, correlationId: saved.correlationId, requesterUserId: saved.requesterUserId)
        guard route.kind?.hasRedeliveryOwner == true else { return }
        _ = try await settleReply(response: response, route: route, envelope: envelope, turn: turn, settlement: .approvalClaim)
    }

    private func followUpRequest(message: String, sessionID: String?, fileAccess: String, surface: String,
        envelope: TurnEnvelope, replyRoute: TurnEnvelope.DeliveryRoute, pinnedRunID: String?? = nil) -> TurnRequest {
        TurnRequest(message: message, sessionID: sessionID, fileAccess: fileAccess,
            surface: surface, suppressUserAppend: true, envelope: envelope, verifiedSessionID: .some(sessionID),
            verifiedChatID: .some(envelope.verifiedChatId), verifiedUserID: .some(envelope.verifiedUserId),
            replyRoute: replyRoute, pinnedRunID: pinnedRunID)
    }

    /// A card's continuation is hidden: read by the agent's turn in progress, that turn carries on with it and nothing else runs.
    private func runAdmittedContinuation(turn: Turn, prompt: String, surface: String,
        operation: @escaping @Sendable (Turn) async throws -> Void) async throws {
        _ = try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: turn.session,
            arrival: TurnArrival(words: prompt, surface: surface, row: .hidden), runID: turn.run, turn: turn, operation: operation)
    }

    private func runApprovalAdmission(sessionID: String, envelope: TurnEnvelope, prompt: String, turn: Turn,
        operation: @escaping @Sendable (Turn) async throws -> Void) async throws {
        if ConversationSurfaceProfile(envelope.surface).id == "bot" {
            try await operation(turn)
            return
        }
        guard envelope.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "telegram" else {
            try await runAdmittedContinuation(turn: turn, prompt: prompt, surface: envelope.surface, operation: operation)
            return
        }
        let threadID = envelope.replyRoute.threadId.flatMap(Int.init)
        guard let rawChatID = envelope.verifiedChatId, let chatID = Int(rawChatID),
              envelope.replyRoute.destinationId == rawChatID,
              envelope.replyRoute.threadId == nil || threadID != nil else {
            throw NSError(domain: "ApprovalContinuationAdmission", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The saved Telegram destination is unavailable."])
        }
        try await TelegramTurns.shared.runApprovalContinuation(
            destination: TelegramDestination(chatId: chatID, threadId: threadID),
            text: prompt, operation: { try await runAdmittedContinuation(turn: turn, prompt: prompt, surface: envelope.surface, operation: operation) })
    }

    private enum ReplySettlement {
        case durable(deliveryID: String, requestDigest: String, notifyRequestedResult: Bool)
        case approvalClaim
    }

    private func settleReply(response: ChatResponse, route: AgentBridgeCompletionRoute, envelope: TurnEnvelope, turn: Turn,
                             settlement: ReplySettlement) async throws -> String {
        let requiresDestinationMatch: Bool
        switch settlement {
        case .durable: requiresDestinationMatch = true
        case .approvalClaim: requiresDestinationMatch = false
        }
        let sender = makeSender(false, nil) { config, chatID in
            (!requiresDestinationMatch || route.destinationId == envelope.verifiedChatId)
                && TelegramPollLoop.inboundAuthorizationDecision(
                    allowedChatIds: config.allowedChatIds, allowedUserIds: config.allowedUserIds,
                    chatId: chatID, fromUserId: envelope.verifiedUserId.flatMap(Int.init)
                ) == .allowed
        }
        switch settlement {
        case .durable(let deliveryID, let digest, let notifyRequestedResult):
            let lifecycle = CodexCompletionLifecycle(
                receiptURL: dataRoot.appendingPathComponent("chat/human-reply-delivery/receipts.jsonl"),
                ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
            _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            switch try await lifecycle.claim(deliveryId: deliveryID, requestDigest: digest, sessionId: response.sessionId, responseRunId: response.runId,
                route: route) {
            case .start:
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
            case .cached: break
            case .inProgress:
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
            case .settled(let delivery):
                return delivery?.status ?? "unknown"
            case .outcomeUnknown, .conflict: throw CodexCompletionLifecycle.LifecycleError.requestConflict
            }
            let delivery = await AgentBridgeCompletionRouter.deliver(
                turn: turn, deliveryId: deliveryID, requestDigest: digest, text: response.output,
                attachments: response.attachments ?? [], route: route, sender: sender, lifecycle: lifecycle,
                notifyRequestedResult: notifyRequestedResult)
            return delivery.status
        case .approvalClaim:
            let delivery = try await sender.deliverReply(response, deliveryId: response.runId, route: route,
                priorVerdict: nil, notifyRequestedResult: false)
            return delivery.status
        }
    }
}

public struct EngineAgentBridgeCompletionSender: AgentBridgeCompletionSending {
  let authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)?

  typealias DeliveryError = AgentBridgeCompletionRouter.DeliveryError

  private let engine: @Sendable () -> NativeAgentEngine
  private let router: @Sendable () -> AttentionRouter
  let dataRoot: URL
  /// Telegram replies, including images, must remain silent.
  let silentTelegram: Bool
  let requestedResultDeliveryID: String?

  public init(engine: @escaping @Sendable () -> NativeAgentEngine, router: @escaping @Sendable () -> AttentionRouter,
       dataRoot: URL = PersistenceCore.defaultDataRoot(),
       silentTelegram: Bool = false,
       requestedResultDeliveryID: String? = nil,
       authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)? = nil) {
    self.engine = engine
    self.router = router
    self.dataRoot = dataRoot
    self.silentTelegram = silentTelegram
    self.requestedResultDeliveryID = requestedResultDeliveryID
    self.authorizeTelegramReply = authorizeTelegramReply
  }

  public func refreshLocalChat(sessionId: String?) async {
    await MainActor.run {
      NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionId)
    }
  }

  public func deliverReply(_ response: ChatResponse, deliveryId: String, route: AgentBridgeCompletionRoute,
                    priorVerdict: String?, notifyRequestedResult: Bool) async throws -> AgentBridgeCompletionDelivery {
    if response.isSilentCompletion {
      return AgentBridgeCompletionDelivery(status: "completed", surface: route.surface, delivery: "silence",
        artifactCount: 0, attempts: 0, reason: nil)
    }
    return try await AgentBridgeCompletionRouter.deliverReply(deliveryId: deliveryId, route: route,
      notifyRequestedResult: notifyRequestedResult, recoverTelegram: {
      guard let raw = route.destinationId, let chatID = Int(raw), response.sessionId != nil,
            let config = try TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot), config.enabled,
            authorizeTelegramReply?(config, chatID) != false,
            route.threadId == nil || route.threadId.flatMap(Int.init) != nil,
            let loop = await BackgroundLoops.BackgroundLoopLifetimes.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop else {
        throw DeliveryError.invalidTelegramDestination
      }
      return try await loop.recoverReply(response, originRunId: response.runId,
        destination: TelegramDestination(chatId: chatID, threadId: route.threadId.flatMap(Int.init)),
        requesterUserId: route.requesterUserId.flatMap(Int.init), silent: silentTelegram, priorVerdict: priorVerdict)
    }, recoverSlack: {
      guard let loop = await BackgroundLoops.BackgroundLoopLifetimes.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop else {
        throw DeliveryError.missingSlackDestination
      }
      return try await loop.recoverReply(response, originRunId: response.runId, route: route)
    }, recoverIOS: {
      guard let sync = engine().deviceSync else {
        throw PersistenceCoreError.ioFailure("The originating runtime has no phone delivery owner.")
      }
      return try await sync.bridge.recoverReply(response, route: route, priorVerdict: priorVerdict)
    }, deliverRequestedResult: {
      guard try await router().deliverRequestedResult(
        deliveryID: requestedResultDeliveryID ?? deliveryId, sessionID: route.turnSessionId ?? response.sessionId,
        opening: route.turnSessionId == nil ? nil : route.sessionId, dataRoot: dataRoot
      ) else { throw DeliveryError.notificationNotAccepted }
    })
  }

  public func preflight(surface: String, route: AgentBridgeCompletionRoute,
                 artifacts: [AgentBridgeCompletionArtifact]) async throws {
    guard !artifacts.isEmpty else { throw DeliveryError.emptyCompletion }
    for artifact in artifacts {
      try AgentBridgeCompletionRouter.validateAttachmentExpectations(artifact.attachmentExpectations)
    }
    switch route.kind {
    case .telegram:
      guard let config = try TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot), config.enabled, !config.botToken.isEmpty,
            let raw = route.destinationId, let chatID = Int(raw), authorizeTelegramReply?(config, chatID) != false,
            route.threadId == nil || route.threadId.flatMap(Int.init) != nil else { throw DeliveryError.invalidTelegramDestination }
    case .slack: try SlackWebAPI.requireConfiguredToken(dataRoot: dataRoot)
    case .ios:
      guard let key = route.sourceKey, AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(key) else { throw DeliveryError.missingIOSSourceKey }
    default: break
    }
    if route.kind == .callerResult { _ = try await engine().agents.tasks.callerResultTarget(route) }
  }

  public func send(artifact: AgentBridgeCompletionArtifact, idempotencyKey: String,
            surface: String, route: AgentBridgeCompletionRoute) async -> AgentBridgeTransportResult {
    await AgentBridgeCompletionRouter.sendCallerResult(artifact: artifact, idempotencyKey: idempotencyKey,
      route: route, tasks: { engine().agents.tasks })
  }
}
